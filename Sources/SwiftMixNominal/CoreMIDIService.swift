import CoreMIDI
import Foundation

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
}

final class CoreMIDIService {
    private static let physicalMessageSpacing: TimeInterval = 0.002

    var onBytes: ((MIDIIngressEvent) -> Void)?
    var onTopologyChanged: (() -> Void)?

    private(set) var setupError: String?
    private(set) var dawSetupError: String?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var dawVirtualSource = MIDIEndpointRef()
    private var connectedSources: [Int: MIDIEndpointRef] = [:]
    private var destinations: [Int: MIDIEndpointRef] = [:]
    private var connectionGenerations: [Int: UInt] = [:]
    private let transmissionLock = NSLock()
    private var transmissionEnabled = false
    private var dawOutputEnabled = false

    init() {
        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(
            "SwiftMix Nominal Lock" as CFString,
            &newClient
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onTopologyChanged?()
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
    }

    func setDAWOutputEnabled(_ enabled: Bool) {
        transmissionLock.lock()
        dawOutputEnabled = enabled && transmissionEnabled && dawVirtualSource != 0
        transmissionLock.unlock()
    }

    func endpointSnapshot() -> MIDIEndpointSnapshot {
        let sources = (0..<MIDIGetNumberOfSources()).compactMap { index -> MIDIEndpointInfo? in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0, endpoint != dawVirtualSource else { return nil }
            return endpointInfo(endpoint, direction: .source)
        }

        let destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> MIDIEndpointInfo? in
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { return nil }
            return endpointInfo(endpoint, direction: .destination)
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

        if let previous = connectedSources.removeValue(forKey: bank), inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, previous)
        }
        destinations.removeValue(forKey: bank)

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

    /// Sends each MIDI message through a separate, briefly spaced `MIDISend`
    /// call. The legacy SwiftMix requires the HUI MSB and LSB as distinct
    /// three-byte ipMIDI UDP datagrams; the driver otherwise coalesces adjacent
    /// calls into one six-byte datagram that the surface ignores.
    @discardableResult
    func send(_ messages: [[UInt8]], toBank bank: Int) -> OSStatus? {
        // Hold the gate across the complete ordered sequence so that emergency
        // disable cannot interleave with the MSB/LSB pair.
        transmissionLock.lock()
        defer { transmissionLock.unlock() }

        let payloads = messages.filter { !$0.isEmpty }
        guard transmissionEnabled,
              outputPort != 0,
              let destination = destinations[bank],
              !payloads.isEmpty else {
            return nil
        }

        for (index, payload) in payloads.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: Self.physicalMessageSpacing)
            }
            let status = sendPhysicalPacket(payload, to: destination)
            guard status == noErr else { return status }
        }
        return noErr
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
                        receivedUptime: ProcessInfo.processInfo.systemUptime
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
