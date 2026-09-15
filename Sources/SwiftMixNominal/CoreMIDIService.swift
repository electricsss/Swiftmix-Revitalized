import CoreMIDI
import Foundation
import SwiftMixNativeUDP

struct MIDIEndpointInfo: Identifiable, Hashable {
    enum Direction: String {
        case source
        case destination
    }

    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String
    let direction: Direction

    var id: String {
        "\(direction.rawValue):\(uniqueID):\(endpoint)"
    }
}

struct MIDIEndpointSnapshot {
    let sources: [MIDIEndpointInfo]
    let destinations: [MIDIEndpointInfo]
}

struct MIDIBankConnection {
    let sourceConnected: Bool
    let destinationConnected: Bool
    let generation: UInt
}

struct MIDIIngressEvent {
    let bank: Int
    let generation: UInt
    let bytes: [UInt8]
    let receivedUptime: TimeInterval
    let isNativeEthernet: Bool
}

enum HUIBridgeDAW: Equatable {
    case logicPro
    case proTools

    var displayName: String {
        switch self {
        case .logicPro: return "Logic Pro"
        case .proTools: return "Pro Tools"
        }
    }
}

final class CoreMIDIService {
    var onBytes: ((MIDIIngressEvent) -> Void)?
    var onTopologyChanged: (() -> Void)?

    private(set) var setupError: String?
    private(set) var dawSetupError: String?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var dawVirtualSource = MIDIEndpointRef()
    private var huiBridgeVirtualSources: [Int: MIDIEndpointRef] = [:]
    private var huiBridgeVirtualDestinations: [Int: MIDIEndpointRef] = [:]
    private var activeHUIBridgeDAW: HUIBridgeDAW?
    private var connectedSources: [Int: MIDIEndpointRef] = [:]
    private var destinations: [Int: MIDIEndpointRef] = [:]
    private var nativeBanks = Set<Int>()
    private var nativeTransport: NativeUDPTransport?
    private var nativeInterfaceBSDName: String?
    private var connectionGenerations: [Int: UInt] = [:]
    private let transmissionLock = NSLock()
    private var transmissionEnabled = false
    private var dawOutputEnabled = false
    private var suppressTopologyNotificationsUntil = -Double.infinity

    init() {
        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(
            "SwiftMix Nominal Lock" as CFString,
            &newClient
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      ProcessInfo.processInfo.systemUptime >= self.suppressTopologyNotificationsUntil else { return }
                self.onTopologyChanged?()
            }
        }

        guard clientStatus == noErr else {
            setupError = "CoreMIDI client creation failed (OSStatus \(clientStatus))."
            return
        }
        client = newClient

        var newInputPort = MIDIPortRef()
        let inputStatus = MIDIInputPortCreateWithBlock(
            client,
            "SwiftMix HUI Input" as CFString,
            &newInputPort
        ) { [weak self] packetList, sourceConnectionReference in
            guard let sourceConnectionReference else {
                return
            }
            let token = UInt(bitPattern: Int(bitPattern: sourceConnectionReference))
            let bank = Int(token & 0xFF) - 1
            let generation = token >> 8
            self?.receive(packetList: packetList, bank: bank, generation: generation)
        }

        guard inputStatus == noErr else {
            setupError = "CoreMIDI input creation failed (OSStatus \(inputStatus))."
            return
        }
        inputPort = newInputPort

        var newOutputPort = MIDIPortRef()
        let outputStatus = MIDIOutputPortCreate(
            client,
            "SwiftMix HUI Output" as CFString,
            &newOutputPort
        )

        guard outputStatus == noErr else {
            setupError = "CoreMIDI output creation failed (OSStatus \(outputStatus))."
            return
        }
        outputPort = newOutputPort

        var newDAWVirtualSource = MIDIEndpointRef()
        let dawSourceStatus = MIDISourceCreate(
            client,
            "SwiftMix DAW Takeover" as CFString,
            &newDAWVirtualSource
        )
        if dawSourceStatus == noErr {
            dawVirtualSource = newDAWVirtualSource
        } else {
            dawSetupError = "DAW virtual MIDI source creation failed (OSStatus \(dawSourceStatus))."
        }

    }

    deinit {
        nativeTransport?.stop()
        for endpoint in connectedSources.values where inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, endpoint)
        }
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if dawVirtualSource != 0 {
            MIDIEndpointDispose(dawVirtualSource)
        }
        for endpoint in huiBridgeVirtualSources.values { MIDIEndpointDispose(endpoint) }
        for endpoint in huiBridgeVirtualDestinations.values { MIDIEndpointDispose(endpoint) }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func setTransmissionEnabled(_ enabled: Bool) {
        transmissionLock.lock()
        transmissionEnabled = enabled
        if !enabled {
            dawOutputEnabled = false
        }
        transmissionLock.unlock()
        if !enabled {
            deactivateHUIBridge()
        }
    }

    func setDAWOutputEnabled(_ enabled: Bool) {
        transmissionLock.lock()
        dawOutputEnabled = enabled && transmissionEnabled
        transmissionLock.unlock()
        if !enabled {
            deactivateHUIBridge()
        }
    }

    func activateHUIBridge(banks: [Int], daw: HUIBridgeDAW) -> Bool {
        guard client != 0 else { return false }
        let requestedBanks = Set(banks.filter { (0..<4).contains($0) })
        guard !requestedBanks.isEmpty else { return false }
        if activeHUIBridgeDAW == daw,
           Set(huiBridgeVirtualSources.keys) == requestedBanks,
           Set(huiBridgeVirtualDestinations.keys) == requestedBanks {
            return true
        }
        deactivateHUIBridge()
        suppressTopologyNotificationsUntil = ProcessInfo.processInfo.systemUptime + 1

        for bank in requestedBanks.sorted() {
            var source = MIDIEndpointRef()
            let sourceStatus = MIDISourceCreate(
                client,
                "SwiftMix \(daw.displayName) HUI Bank \(bank + 1) Output" as CFString,
                &source
            )
            guard sourceStatus == noErr else {
                dawSetupError = "Could not create \(daw.displayName) HUI Bank \(bank + 1) output (OSStatus \(sourceStatus))."
                deactivateHUIBridge()
                return false
            }
            huiBridgeVirtualSources[bank] = source

            var destination = MIDIEndpointRef()
            let destinationStatus = MIDIDestinationCreateWithBlock(
                client,
                "SwiftMix \(daw.displayName) HUI Bank \(bank + 1) Input" as CFString,
                &destination
            ) { [weak self] packetList, _ in
                self?.receiveHUIBridge(packetList: packetList, bank: bank)
            }
            guard destinationStatus == noErr else {
                dawSetupError = "Could not create \(daw.displayName) HUI Bank \(bank + 1) input (OSStatus \(destinationStatus))."
                deactivateHUIBridge()
                return false
            }
            huiBridgeVirtualDestinations[bank] = destination
        }
        activeHUIBridgeDAW = daw
        dawSetupError = nil
        return true
    }

    func deactivateHUIBridge() {
        guard !huiBridgeVirtualSources.isEmpty || !huiBridgeVirtualDestinations.isEmpty else {
            activeHUIBridgeDAW = nil
            return
        }
        suppressTopologyNotificationsUntil = ProcessInfo.processInfo.systemUptime + 1
        for endpoint in huiBridgeVirtualSources.values { MIDIEndpointDispose(endpoint) }
        for endpoint in huiBridgeVirtualDestinations.values { MIDIEndpointDispose(endpoint) }
        huiBridgeVirtualSources.removeAll()
        huiBridgeVirtualDestinations.removeAll()
        activeHUIBridgeDAW = nil
    }

    func configureNativeEthernet(interfaceBSDName: String?) {
        guard interfaceBSDName != nativeInterfaceBSDName || nativeTransport == nil else { return }
        nativeTransport?.stop()
        nativeTransport = nil
        nativeInterfaceBSDName = interfaceBSDName
        nativeBanks.removeAll()
        guard let interfaceBSDName else { return }

        do {
            let configuration = try NativeUDPConfiguration(interfaceBSDName: interfaceBSDName)
            let verification = try ProtocolVerification(
                captureIdentifier: "logic-automation-5b7f906be297435fe62cbaa06b0cc1859e1f25d7785d4cbb2d28f38ee38ed3dc",
                protocolRevision: "swiftmix-ipmidi-wire-r1"
            )
            let transport = NativeUDPTransport(
                configuration: configuration,
                receiveAuthorization: .receiveOnly,
                transmissionAuthorization: .verified(verification)
            )
            try transport.start { [weak self] event in
                guard let self else { return }
                switch event {
                case let .packet(packet):
                    let bank = packet.bank.rawValue - 1
                    let generation = self.connectionGenerations[bank] ?? 0
                    self.onBytes?(
                        MIDIIngressEvent(
                            bank: bank,
                            generation: generation,
                            bytes: packet.payload,
                            receivedUptime: ProcessInfo.processInfo.systemUptime,
                            isNativeEthernet: true
                        )
                    )
                case let .failure(error):
                    self.setupError = "Native Ethernet MIDI failed: \(error)"
                    self.onTopologyChanged?()
                }
            }
            nativeTransport = transport
            setupError = nil
        } catch {
            setupError = "Could not open native SwiftMix Ethernet ports on \(interfaceBSDName): \(error)"
        }
    }

    func endpointSnapshot() -> MIDIEndpointSnapshot {
        var sources = (0..<MIDIGetNumberOfSources()).compactMap { index -> MIDIEndpointInfo? in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0, endpoint != dawVirtualSource else { return nil }
            return endpointInfo(endpoint, direction: .source)
        }

        var destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> MIDIEndpointInfo? in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            return endpointInfo(endpoint, direction: .destination)
        }

        for bank in 0..<4 {
            let name = "SwiftMix Ethernet Port \(bank + 1)"
            let uniqueID = MIDIUniqueID(-20_001 - bank)
            let source = MIDIEndpointInfo(endpoint: 0, uniqueID: uniqueID, name: name, direction: .source)
            let destination = MIDIEndpointInfo(endpoint: 0, uniqueID: uniqueID, name: name, direction: .destination)
            sources.append(source)
            destinations.append(destination)
        }

        return MIDIEndpointSnapshot(
            sources: sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            destinations: destinations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    func configure(
        bank: Int,
        source: MIDIEndpointInfo?,
        destination: MIDIEndpointInfo?
    ) -> MIDIBankConnection {
        let generation = (connectionGenerations[bank] ?? 0) + 1
        connectionGenerations[bank] = generation

        nativeBanks.remove(bank)
        if let previous = connectedSources.removeValue(forKey: bank), inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, previous)
        }
        destinations.removeValue(forKey: bank)

        let nativeSelected = source?.name == "SwiftMix Ethernet Port \(bank + 1)"
            && destination?.name == "SwiftMix Ethernet Port \(bank + 1)"
        if nativeSelected, nativeTransport?.isRunning == true {
            nativeBanks.insert(bank)
            return MIDIBankConnection(sourceConnected: true, destinationConnected: true, generation: generation)
        }

        var sourceConnected = false
        if let source, inputPort != 0 {
            let token = (generation << 8) | UInt(bank + 1)
            let reference = UnsafeMutableRawPointer(bitPattern: Int(token))
            let status = MIDIPortConnectSource(inputPort, source.endpoint, reference)
            if status == noErr {
                connectedSources[bank] = source.endpoint
                sourceConnected = true
            }
        }

        let destinationConnected = destination != nil && outputPort != 0
        if let destination, destinationConnected {
            destinations[bank] = destination.endpoint
        }

        return MIDIBankConnection(
            sourceConnected: sourceConnected,
            destinationConnected: destinationConnected,
            generation: generation
        )
    }

    @discardableResult
    func send(_ message: [UInt8], toBank bank: Int) -> OSStatus? {
        send([message], toBank: bank)
    }

    /// Sends an ordered MIDI message batch as one CoreMIDI packet. ipMIDI then
    /// emits one UDP MIDI payload, matching the multi-message bank snapshots in
    /// the successful Logic capture and 32-fader hardware test.
    @discardableResult
    func send(_ messages: [[UInt8]], toBank bank: Int) -> OSStatus? {
        transmissionLock.lock()
        defer { transmissionLock.unlock() }

        let payload = messages.flatMap { $0 }
        guard transmissionEnabled, !payload.isEmpty else { return nil }

        if nativeBanks.contains(bank), let nativeTransport,
           let nativeBank = try? IPMIDIBank(number: bank + 1) {
            do {
                try nativeTransport.send(payload, on: nativeBank)
                return noErr
            } catch {
                return OSStatus(EIO)
            }
        }

        guard outputPort != 0, let destination = destinations[bank] else { return nil }
        return sendPhysicalPacket(payload, to: destination)
    }

    /// Called only while `transmissionLock` is held.
    private func sendPhysicalPacket(
        _ payload: [UInt8],
        to destination: MIDIEndpointRef
    ) -> OSStatus {
        let storageSize = max(MemoryLayout<MIDIPacketList>.size, 1_024)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }

        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetList)
        _ = payload.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(
                packetList,
                storageSize,
                firstPacket,
                0,
                buffer.count,
                buffer.baseAddress!
            )
        }

        return MIDISend(outputPort, destination, packetList)
    }

    /// Publishes controller data through the app's virtual source so a DAW can
    /// select `SwiftMix DAW Takeover` as a MIDI input. This gate is separate
    /// from physical HUI output and is never enabled implicitly.
    @discardableResult
    func sendToDAW(_ messages: [[UInt8]]) -> OSStatus? {
        transmissionLock.lock()
        defer { transmissionLock.unlock() }

        let payload = messages.flatMap { $0 }
        guard transmissionEnabled,
              dawOutputEnabled,
              dawVirtualSource != 0,
              !payload.isEmpty else {
            return nil
        }

        let storageSize = max(MemoryLayout<MIDIPacketList>.size, 1_024)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }

        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetList)
        _ = payload.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(
                packetList,
                storageSize,
                firstPacket,
                0,
                buffer.count,
                buffer.baseAddress!
            )
        }

        return MIDIReceived(dawVirtualSource, packetList)
    }

    @discardableResult
    func sendHUIToBridge(_ bytes: [UInt8], bank: Int) -> OSStatus? {
        transmissionLock.lock()
        defer { transmissionLock.unlock() }
        guard transmissionEnabled,
              dawOutputEnabled,
              let source = huiBridgeVirtualSources[bank],
              !bytes.isEmpty else {
            return nil
        }
        return sendVirtualPacket(bytes, to: source)
    }

    private func receiveHUIBridge(
        packetList: UnsafePointer<MIDIPacketList>,
        bank: Int
    ) {
        transmissionLock.lock()
        let enabled = transmissionEnabled && dawOutputEnabled
        transmissionLock.unlock()
        guard enabled else { return }

        for bytes in packetPayloads(packetList) where !bytes.isEmpty {
            _ = send([bytes], toBank: bank)
        }
    }

    private func sendVirtualPacket(_ payload: [UInt8], to source: MIDIEndpointRef) -> OSStatus {
        let storageSize = max(MemoryLayout<MIDIPacketList>.size, 1_024)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }
        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetList)
        _ = payload.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(packetList, storageSize, firstPacket, 0, buffer.count, buffer.baseAddress!)
        }
        return MIDIReceived(source, packetList)
    }

    private func packetPayloads(_ packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
        guard let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
              let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return [] }
        var result: [[UInt8]] = []
        var packet = UnsafeMutableRawPointer(mutating: packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        for index in 0..<Int(packetList.pointee.numPackets) {
            let length = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset)
            result.append(Array(UnsafeRawBufferPointer(start: data, count: length)))
            if index + 1 < Int(packetList.pointee.numPackets) { packet = MIDIPacketNext(packet) }
        }
        return result
    }

    private func receive(
        packetList: UnsafePointer<MIDIPacketList>,
        bank: Int,
        generation: UInt
    ) {
        guard let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
              let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else {
            return
        }

        var packetPointer = UnsafeMutableRawPointer(mutating: packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)

        for packetIndex in 0..<Int(packetList.pointee.numPackets) {
            let length = Int(packetPointer.pointee.length)
            let dataPointer = UnsafeRawPointer(packetPointer).advanced(by: dataOffset)
            let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: length))
            if !bytes.isEmpty {
                onBytes?(
                    MIDIIngressEvent(
                        bank: bank,
                        generation: generation,
                        bytes: bytes,
                        receivedUptime: ProcessInfo.processInfo.systemUptime,
                        isNativeEthernet: false
                    )
                )
            }

            if packetIndex + 1 < Int(packetList.pointee.numPackets) {
                packetPointer = MIDIPacketNext(packetPointer)
            }
        }
    }

    private func endpointInfo(
        _ endpoint: MIDIEndpointRef,
        direction: MIDIEndpointInfo.Direction
    ) -> MIDIEndpointInfo {
        var uniqueID = MIDIUniqueID()
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

        let name = stringProperty(endpoint, key: kMIDIPropertyDisplayName)
            ?? stringProperty(endpoint, key: kMIDIPropertyName)
            ?? "Unnamed MIDI endpoint"

        return MIDIEndpointInfo(
            endpoint: endpoint,
            uniqueID: uniqueID,
            name: name,
            direction: direction
        )
    }

    private func stringProperty(_ object: MIDIObjectRef, key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr,
              let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }
}
