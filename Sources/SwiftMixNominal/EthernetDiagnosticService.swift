import Darwin
import Dispatch
import Foundation

enum EthernetCoordinationPreference: String, CaseIterable, Identifiable {
    case standalone
    case preferredMaster
    case preferredStandby

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standalone: return "Standalone"
        case .preferredMaster: return "Preferred Master"
        case .preferredStandby: return "Preferred Standby"
        }
    }
}

struct EthernetDiagnosticPeer: Equatable, Identifiable {
    let id: UUID
    let hostName: String
    let appVersion: String
    let preference: EthernetCoordinationPreference
    let controlTransmissionEnabled: Bool
    let interface: String
    let lastSeen: Date
}

/// Sends diagnostics and performs peer discovery independently of the HUI control gate.
/// Paths are ordered so the same discovery protocol can support explicit primary/fallback
/// interfaces without relying on the system route table.
final class EthernetDiagnosticService: @unchecked Sendable {
    static let multicastAddress = "239.255.83.77"
    static let port: UInt16 = 45_837

    struct PathStatus: Equatable {
        let interfaces: [String]
        let lastError: String?

        var summary: String {
            if let lastError { return "Peer discovery unavailable: \(lastError)" }
            guard !interfaces.isEmpty else { return "Peer discovery waiting for an interface" }
            return "Peer discovery active on \(interfaces.joined(separator: " → ")) · \(EthernetDiagnosticService.multicastAddress):\(EthernetDiagnosticService.port)"
        }
    }

    private struct Packet: Codable {
        let protocolVersion: Int
        let kind: String
        let instanceID: UUID
        let sequence: UInt64
        let timestamp: String
        let appVersion: String
        let hostName: String
        let interface: String
        let pathPriority: Int
        let message: String?
        let controlTransmissionEnabled: Bool
        let coordinationPreference: String?
    }

    private struct Path {
        let bsdName: String
        let transmitDescriptor: Int32
        let receiveDescriptor: Int32
        let receiveSource: DispatchSourceRead
    }

    private struct ObservedPeer {
        var peer: EthernetDiagnosticPeer
        var lastSeenUptime: TimeInterval
    }

    var onStatusChange: (@Sendable (PathStatus) -> Void)?
    var onPeersChange: (@Sendable ([EthernetDiagnosticPeer]) -> Void)?

    private let queue = DispatchQueue(label: "SwiftMix.EthernetDiagnostics", qos: .utility)
    private let instanceID = UUID()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var paths: [Path] = []
    private var peers: [UUID: ObservedPeer] = [:]
    private var sequence: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var controlTransmissionEnabled = false
    private var preference = EthernetCoordinationPreference.standalone
    private static let peerExpiry: TimeInterval = 6

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit {
        heartbeatTimer?.cancel()
        for path in paths {
            path.receiveSource.cancel()
            Darwin.close(path.receiveDescriptor)
            Darwin.close(path.transmitDescriptor)
        }
    }

    func configure(interfaceBSDNames: [String]) {
        queue.async { [weak self] in
            self?.configureLocked(interfaceBSDNames: Self.unique(interfaceBSDNames))
        }
    }

    func setCoordinationPreference(_ preference: EthernetCoordinationPreference) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preference = preference
            self.sendLocked(kind: "role", message: nil)
        }
    }

    func setControlTransmissionEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.controlTransmissionEnabled = enabled
            self.sendLocked(kind: "state", message: nil)
        }
    }

    func reportIssue(_ message: String) {
        queue.async { [weak self] in self?.sendLocked(kind: "issue", message: message) }
    }

    func reportSnapshot(_ message: String) {
        queue.async { [weak self] in self?.sendLocked(kind: "snapshot", message: message) }
    }

    private func configureLocked(interfaceBSDNames: [String]) {
        for path in paths {
            path.receiveSource.cancel()
            Darwin.close(path.receiveDescriptor)
            Darwin.close(path.transmitDescriptor)
        }
        paths.removeAll()
        peers.removeAll()
        publishPeersLocked()

        var failures: [String] = []
        for bsdName in interfaceBSDNames {
            do {
                paths.append(try openPath(bsdName: bsdName))
            } catch {
                failures.append("\(bsdName): \(error.localizedDescription)")
            }
        }

        if paths.isEmpty {
            stopHeartbeatLocked()
        } else {
            startHeartbeatLocked()
            for path in paths { path.receiveSource.resume() }
            sendLocked(kind: "online", message: nil)
        }

        onStatusChange?(PathStatus(
            interfaces: paths.map(\.bsdName),
            lastError: paths.isEmpty && !failures.isEmpty ? failures.joined(separator: "; ") : nil
        ))
    }

    private func startHeartbeatLocked() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.heartbeatLocked()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeatLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func heartbeatLocked() {
        let cutoff = ProcessInfo.processInfo.systemUptime - Self.peerExpiry
        let previousCount = peers.count
        peers = peers.filter { $0.value.lastSeenUptime >= cutoff }
        if peers.count != previousCount { publishPeersLocked() }
        sendLocked(kind: "heartbeat", message: nil)
    }

    private func sendLocked(kind: String, message: String?) {
        guard !paths.isEmpty else { return }
        sequence &+= 1
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let version = Self.appVersion

        for (priority, path) in paths.enumerated() {
            let packet = Packet(
                protocolVersion: 2,
                kind: kind,
                instanceID: instanceID,
                sequence: sequence,
                timestamp: timestamp,
                appVersion: version,
                hostName: Host.current().localizedName ?? "unknown",
                interface: path.bsdName,
                pathPriority: priority,
                message: message,
                controlTransmissionEnabled: controlTransmissionEnabled,
                coordinationPreference: preference.rawValue
            )
            guard let payload = try? encoder.encode(packet) else { continue }
            Self.send(payload: payload, descriptor: path.transmitDescriptor)
        }
    }

    private func receiveLocked(descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            if count == 0 { return }
            guard let packet = try? decoder.decode(Packet.self, from: Data(buffer.prefix(count))),
                  packet.instanceID != instanceID else { continue }
            let peerPreference = packet.coordinationPreference
                .flatMap(EthernetCoordinationPreference.init(rawValue:)) ?? .standalone
            peers[packet.instanceID] = ObservedPeer(
                peer: EthernetDiagnosticPeer(
                    id: packet.instanceID,
                    hostName: packet.hostName,
                    appVersion: packet.appVersion,
                    preference: peerPreference,
                    controlTransmissionEnabled: packet.controlTransmissionEnabled,
                    interface: packet.interface,
                    lastSeen: Date()
                ),
                lastSeenUptime: ProcessInfo.processInfo.systemUptime
            )
            publishPeersLocked()
        }
    }

    private func publishPeersLocked() {
        onPeersChange?(peers.values.map(\.peer).sorted {
            if $0.hostName == $1.hostName { return $0.id.uuidString < $1.id.uuidString }
            return $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending
        })
    }

    private func openPath(bsdName: String) throws -> Path {
        let interfaceIndex = if_nametoindex(bsdName)
        guard interfaceIndex != 0 else { throw POSIXError(.ENODEV) }
        guard let address = Self.ipv4Address(for: bsdName) else { throw POSIXError(.EADDRNOTAVAIL) }

        let transmit = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard transmit >= 0 else { throw Self.currentPOSIXError() }
        do {
            var boundIndex = interfaceIndex
            try Self.setOption(transmit, level: IPPROTO_IP, name: IP_BOUND_IF, value: &boundIndex)
            var multicastInterface = address
            try Self.setOption(transmit, level: IPPROTO_IP, name: IP_MULTICAST_IF, value: &multicastInterface)
            var ttl: UInt8 = 1
            try Self.setOption(transmit, level: IPPROTO_IP, name: IP_MULTICAST_TTL, value: &ttl)
            var loopback: UInt8 = 0
            try Self.setOption(transmit, level: IPPROTO_IP, name: IP_MULTICAST_LOOP, value: &loopback)

            let receive = try Self.openReceiveSocket(
                bsdName: bsdName,
                interfaceIndex: interfaceIndex,
                interfaceAddress: address
            )
            let source = DispatchSource.makeReadSource(fileDescriptor: receive, queue: queue)
            source.setEventHandler { [weak self] in self?.receiveLocked(descriptor: receive) }
            return Path(
                bsdName: bsdName,
                transmitDescriptor: transmit,
                receiveDescriptor: receive,
                receiveSource: source
            )
        } catch {
            Darwin.close(transmit)
            throw error
        }
    }

    private static func openReceiveSocket(
        bsdName: String,
        interfaceIndex: UInt32,
        interfaceAddress: in_addr
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            var enabled: Int32 = 1
            try setOption(descriptor, level: SOL_SOCKET, name: SO_REUSEADDR, value: &enabled)
            try setOption(descriptor, level: SOL_SOCKET, name: SO_REUSEPORT, value: &enabled)
            var boundIndex = interfaceIndex
            try setOption(descriptor, level: IPPROTO_IP, name: IP_BOUND_IF, value: &boundIndex)

            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = port.bigEndian
            local.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bindResult = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw currentPOSIXError() }

            var membership = ip_mreq()
            _ = multicastAddress.withCString { inet_pton(AF_INET, $0, &membership.imr_multiaddr) }
            membership.imr_interface = interfaceAddress
            try setOption(descriptor, level: IPPROTO_IP, name: IP_ADD_MEMBERSHIP, value: &membership)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func send(payload: Data, descriptor: Int32) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        _ = multicastAddress.withCString { inet_pton(AF_INET, $0, &destination.sin_addr) }
        payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static func ipv4Address(for bsdName: String) -> in_addr? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let item = current.pointee
            if String(cString: item.ifa_name) == bsdName,
               item.ifa_flags & UInt32(IFF_UP) != 0,
               let socketAddress = item.ifa_addr,
               Int32(socketAddress.pointee.sa_family) == AF_INET {
                return socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            cursor = item.ifa_next
        }
        return nil
    }

    private static func setOption<T>(_ descriptor: Int32, level: Int32, name: Int32, value: inout T) throws {
        let result = withUnsafePointer(to: &value) {
            Darwin.setsockopt(descriptor, level, name, $0, socklen_t(MemoryLayout<T>.size))
        }
        guard result == 0 else { throw currentPOSIXError() }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
