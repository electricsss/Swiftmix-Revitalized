import Darwin
import Dispatch
import Foundation

/// Serial-queue UDP transport with receive authorization enabled by default and
/// transmission denied by default. Sends are immediate only; there is no timed
/// or queued transmit API.
public final class NativeUDPTransport: @unchecked Sendable {
    public typealias ReceiveHandler = @Sendable (NativeUDPReceiveEvent) -> Void

    private struct ManagedSocket {
        let receiveDescriptor: Int32
        let transmitDescriptor: Int32
        let bank: IPMIDIBank
        let localPort: UInt16
        let source: DispatchSourceRead
    }

    public let configuration: NativeUDPConfiguration
    public let receiveAuthorization: ReceiveAuthorization
    public let transmissionAuthorization: TransmissionAuthorization

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var sockets: [ManagedSocket] = []
    private var receiveHandler: ReceiveHandler?

    public init(
        configuration: NativeUDPConfiguration,
        receiveAuthorization: ReceiveAuthorization = .receiveOnly,
        transmissionAuthorization: TransmissionAuthorization = .denied
    ) {
        self.configuration = configuration
        self.receiveAuthorization = receiveAuthorization
        self.transmissionAuthorization = transmissionAuthorization
        self.queue = DispatchQueue(
            label: "NativeUDPTransport.\(configuration.interfaceBSDName)",
            qos: .userInitiated
        )
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        withQueue {
            stopLocked()
        }
    }

    public var isRunning: Bool {
        withQueue { !sockets.isEmpty }
    }

    /// Idempotent. A second call while running retains the original handler.
    public func start(receiveHandler: @escaping ReceiveHandler) throws {
        try withQueue {
            guard sockets.isEmpty else { return }
            guard receiveAuthorization == .receiveOnly else {
                throw NativeUDPError.receptionNotAuthorized
            }

            let interface = try IPv4InterfaceResolver.resolve(
                requiredBSDName: configuration.interfaceBSDName
            )
            var opened: [(receive: Int32, transmit: Int32, bank: IPMIDIBank, port: UInt16)] = []

            do {
                for bank in configuration.banks {
                    let port = configuration.wireProfile.port(for: bank)
                    let receive = try openReceiveSocket(
                        bank: bank,
                        port: port,
                        interface: interface
                    )
                    do {
                        let transmit = try openTransmitSocket(bank: bank, interface: interface)
                        opened.append((receive, transmit, bank, port))
                    } catch {
                        Darwin.close(receive)
                        throw error
                    }
                }
            } catch {
                for item in opened {
                    Darwin.close(item.receive)
                    Darwin.close(item.transmit)
                }
                throw error
            }

            self.receiveHandler = receiveHandler
            self.sockets = opened.map { item in
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: item.receive,
                    queue: queue
                )
                source.setEventHandler { [weak self] in
                    self?.drainSocket(
                        descriptor: item.receive,
                        bank: item.bank,
                        localPort: item.port
                    )
                }
                return ManagedSocket(
                    receiveDescriptor: item.receive,
                    transmitDescriptor: item.transmit,
                    bank: item.bank,
                    localPort: item.port,
                    source: source
                )
            }
            for socket in sockets {
                socket.source.resume()
            }
        }
    }

    /// Idempotent and safe to call from the receive callback.
    public func stop() {
        withQueue {
            stopLocked()
        }
    }

    /// Returns the macOS-assigned ephemeral source port for a running bank's
    /// host-to-surface socket.
    public func transmitSourcePort(on bank: IPMIDIBank) throws -> UInt16 {
        try withQueue {
            guard let socket = sockets.first(where: { $0.bank == bank }) else {
                throw NativeUDPError.bankSocketNotRunning(bank.rawValue)
            }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socket.transmitDescriptor, $0, &length)
                }
            }
            guard result == 0 else {
                throw NativeUDPError.systemCall("getsockname(tx bank \(bank.rawValue))")
            }
            return UInt16(bigEndian: address.sin_port)
        }
    }

    /// Sends one datagram immediately on the already-bound bank socket. This
    /// always rejects `.denied`; there is no delayed, queued, or scheduled send.
    public func send(_ payload: [UInt8], on bank: IPMIDIBank) throws {
        _ = try TransmissionPolicy.requireVerified(transmissionAuthorization)
        try withQueue {
            guard !sockets.isEmpty else {
                throw NativeUDPError.transportNotRunning
            }
            guard !payload.isEmpty else {
                throw NativeUDPError.emptyPayload
            }
            guard payload.count <= configuration.maximumPacketSize else {
                throw NativeUDPError.payloadTooLarge(
                    actual: payload.count,
                    maximum: configuration.maximumPacketSize
                )
            }
            guard let socket = sockets.first(where: { $0.bank == bank }) else {
                throw NativeUDPError.bankSocketNotRunning(bank.rawValue)
            }

            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = configuration.wireProfile.port(for: bank).bigEndian
            destination.sin_addr = configuration.wireProfile.multicastGroup.value.inAddress

            let sent = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(
                            socket.transmitDescriptor,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            guard sent >= 0 else {
                throw NativeUDPError.systemCall("sendto(bank \(bank.rawValue))")
            }
            guard sent == payload.count else {
                throw NativeUDPError.systemCallFailed(
                    operation: "sendto(bank \(bank.rawValue))",
                    code: EIO,
                    message: "short UDP send: \(sent) of \(payload.count) bytes"
                )
            }
        }
    }

    private func openReceiveSocket(
        bank: IPMIDIBank,
        port: UInt16,
        interface: ResolvedIPv4Interface
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw NativeUDPError.systemCall("socket(bank \(bank.rawValue))")
        }

        do {
            var enabled: Int32 = 1
            try setOption(
                descriptor,
                level: SOL_SOCKET,
                name: SO_REUSEADDR,
                value: &enabled,
                operation: "setsockopt(SO_REUSEADDR, bank \(bank.rawValue))"
            )
            try setOption(
                descriptor,
                level: SOL_SOCKET,
                name: SO_REUSEPORT,
                value: &enabled,
                operation: "setsockopt(SO_REUSEPORT, bank \(bank.rawValue))"
            )

            var interfaceIndex = interface.index
            try setOption(
                descriptor,
                level: IPPROTO_IP,
                name: IP_BOUND_IF,
                value: &interfaceIndex,
                operation: "setsockopt(IP_BOUND_IF, bank \(bank.rawValue))"
            )

            var multicastInterface = interface.address.inAddress
            try setOption(
                descriptor,
                level: IPPROTO_IP,
                name: IP_MULTICAST_IF,
                value: &multicastInterface,
                operation: "setsockopt(IP_MULTICAST_IF, bank \(bank.rawValue))"
            )

            var loopback: UInt8 = configuration.wireProfile.localMulticastLoopback.value ? 1 : 0
            try setOption(
                descriptor,
                level: IPPROTO_IP,
                name: IP_MULTICAST_LOOP,
                value: &loopback,
                operation: "setsockopt(IP_MULTICAST_LOOP, bank \(bank.rawValue))"
            )

            var localAddress = sockaddr_in()
            localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            localAddress.sin_family = sa_family_t(AF_INET)
            localAddress.sin_port = port.bigEndian
            localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw NativeUDPError.systemCall("bind(UDP \(port), bank \(bank.rawValue))")
            }

            var membership = ip_mreq()
            membership.imr_multiaddr = configuration.wireProfile.multicastGroup.value.inAddress
            membership.imr_interface = interface.address.inAddress
            try setOption(
                descriptor,
                level: IPPROTO_IP,
                name: IP_ADD_MEMBERSHIP,
                value: &membership,
                operation: "setsockopt(IP_ADD_MEMBERSHIP, bank \(bank.rawValue))"
            )

            let currentFlags = fcntl(descriptor, F_GETFL, 0)
            guard currentFlags >= 0 else {
                throw NativeUDPError.systemCall("fcntl(F_GETFL, bank \(bank.rawValue))")
            }
            guard fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                throw NativeUDPError.systemCall("fcntl(F_SETFL, bank \(bank.rawValue))")
            }

            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Opens a dedicated host-to-surface socket. Binding port zero deliberately
    /// asks macOS for an ephemeral source port, matching the observed Logic and
    /// ipMIDI traffic rather than incorrectly reusing the bank receive port.
    private func openTransmitSocket(
        bank: IPMIDIBank,
        interface: ResolvedIPv4Interface
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw NativeUDPError.systemCall("socket(tx bank \(bank.rawValue))") }
        do {
            var interfaceIndex = interface.index
            try setOption(descriptor, level: IPPROTO_IP, name: IP_BOUND_IF, value: &interfaceIndex, operation: "setsockopt(IP_BOUND_IF, tx bank \(bank.rawValue))")
            var multicastInterface = interface.address.inAddress
            try setOption(descriptor, level: IPPROTO_IP, name: IP_MULTICAST_IF, value: &multicastInterface, operation: "setsockopt(IP_MULTICAST_IF, tx bank \(bank.rawValue))")
            var ttl = configuration.wireProfile.multicastTTL.value
            try setOption(descriptor, level: IPPROTO_IP, name: IP_MULTICAST_TTL, value: &ttl, operation: "setsockopt(IP_MULTICAST_TTL, tx bank \(bank.rawValue))")
            var loopback: UInt8 = configuration.wireProfile.localMulticastLoopback.value ? 1 : 0
            try setOption(descriptor, level: IPPROTO_IP, name: IP_MULTICAST_LOOP, value: &loopback, operation: "setsockopt(IP_MULTICAST_LOOP, tx bank \(bank.rawValue))")

            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = 0
            local.sin_addr = interface.address.inAddress
            let result = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw NativeUDPError.systemCall("bind(ephemeral tx bank \(bank.rawValue))") }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func setOption<Value>(
        _ descriptor: Int32,
        level: Int32,
        name: Int32,
        value: inout Value,
        operation: String
    ) throws {
        let result = withUnsafePointer(to: &value) { pointer in
            Darwin.setsockopt(
                descriptor,
                level,
                name,
                pointer,
                socklen_t(MemoryLayout<Value>.size)
            )
        }
        guard result == 0 else {
            throw NativeUDPError.systemCall(operation)
        }
    }

    private func drainSocket(descriptor: Int32, bank: IPMIDIBank, localPort: UInt16) {
        var buffer = [UInt8](
            repeating: 0,
            count: configuration.maximumPacketSize + 1
        )

        while true {
            var sourceAddress = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sourceAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(
                            descriptor,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            $0,
                            &sourceLength
                        )
                    }
                }
            }

            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                let error = NativeUDPError.systemCall("recvfrom(bank \(bank.rawValue))")
                receiveHandler?(.failure(error))
                stopLocked()
                return
            }

            let timestamp = Date()
            if received > configuration.maximumPacketSize {
                receiveHandler?(
                    .failure(
                        .receivedPacketTooLarge(
                            bank: bank.rawValue,
                            maximum: configuration.maximumPacketSize
                        )
                    )
                )
                continue
            }
            guard Int32(sourceAddress.sin_family) == AF_INET else {
                receiveHandler?(
                    .failure(.unexpectedSourceAddressFamily(Int32(sourceAddress.sin_family)))
                )
                continue
            }

            let packet = ReceivedUDPPacket(
                timestamp: timestamp,
                bank: bank,
                localDestinationPort: localPort,
                source: IPv4Endpoint(
                    address: IPv4Address(
                        networkOrderValue: sourceAddress.sin_addr.s_addr
                    ),
                    port: UInt16(bigEndian: sourceAddress.sin_port)
                ),
                payload: Array(buffer.prefix(received))
            )
            receiveHandler?(.packet(packet))
        }
    }

    private func stopLocked() {
        receiveHandler = nil
        let activeSockets = sockets
        sockets.removeAll(keepingCapacity: false)
        for socket in activeSockets {
            socket.source.setEventHandler {}
            socket.source.cancel()
            Darwin.close(socket.receiveDescriptor)
            Darwin.close(socket.transmitDescriptor)
        }
    }

    private func withQueue<Result>(_ body: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}
