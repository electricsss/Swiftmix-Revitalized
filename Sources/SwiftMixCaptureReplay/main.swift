import CoreMIDI
import Darwin
import Foundation
import SwiftMixCore

private let approvedCaptureSHA256 = "5b7f906be297435fe62cbaa06b0cc1859e1f25d7785d4cbb2d28f38ee38ed3dc"
private let approvedFrameCount = 6_560
private let approvedHostPacketCount = 4_067
private let approvedHostPayloadBytes = 149_895
private let approvedDuration: TimeInterval = 166.600023
private let expectedHostAddress = "169.254.209.100"
private let expectedSurfaceAddress = "0.0.0.0"
private let multicastAddress = "225.0.0.37"
private let bankPort = 21_928
private let capturedHostSourcePort = 53_483
private let replayAuthorization = "SWIFTMIX_REPLAY_APPROVED_LOGIC_BANK1"
private let interactiveConfirmation = "REPLAY 4067 LOGIC PACKETS TO BANK 1"
private let tsharkPath = "/Applications/Wireshark.app/Contents/MacOS/tshark"

private enum ReplayError: Error, CustomStringConvertible {
    case usage(String)
    case safety(String)
    case system(String)
    case capture(String)

    var description: String {
        switch self {
        case let .usage(message),
             let .safety(message),
             let .system(message),
             let .capture(message):
            return message
        }
    }
}

private struct Options {
    var showHelp = false
    var listEndpoints = false
    var execute = false
    var capturePath: String?
    var sourceName: String?
    var destinationName: String?
    var expectedInterface: String?
    var authorization: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else {
                throw ReplayError.usage("Missing value after \(option).")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--list":
                options.listEndpoints = true
            case "--execute":
                options.execute = true
            case "--capture":
                options.capturePath = try value(after: argument)
            case "--source-name":
                options.sourceName = try value(after: argument)
            case "--destination-name":
                options.destinationName = try value(after: argument)
            case "--expected-interface":
                options.expectedInterface = try value(after: argument)
            case "--authorization":
                options.authorization = try value(after: argument)
            default:
                throw ReplayError.usage("Unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }
}

private struct CapturedHostPacket {
    let frameNumber: Int
    let relativeTime: TimeInterval
    let payload: [UInt8]
}

private struct CaptureProfile {
    let sha256: String
    let frameCount: Int
    let hostPackets: [CapturedHostPacket]
    let surfacePacketCount: Int
    let hostPayloadBytes: Int
    let duration: TimeInterval
    let faderChannels: Set<Int>
    let pingCount: Int
    let hostSourcePorts: Set<Int>
}

private struct MIDIEndpointDescription {
    enum Direction: String {
        case source
        case destination
    }

    let endpoint: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String
    let direction: Direction
}

private final class ReplayLogger {
    let path: String

    private let lock = NSLock()
    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    init() throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        path = "/tmp/swiftmix-logic-bank1-replay-\(timestamp).log"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw ReplayError.system("Could not create replay log at \(path).")
        }
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    func write(_ message: String, echo: Bool = true) {
        lock.lock()
        defer { lock.unlock() }

        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        if echo {
            print(message)
        }
    }

    func synchronize() {
        lock.lock()
        try? handle.synchronize()
        lock.unlock()
    }
}

private final class ReplayMonitor {
    private let lock = NSLock()
    private let logger: ReplayLogger
    private var streamParser = MIDIMessageStreamParser()
    private var abortMessage: String?
    private var receivedMessageCount = 0
    private var pingReplyCount = 0

    init(logger: ReplayLogger) {
        self.logger = logger
    }

    func receive(bytes: [UInt8]) {
        lock.lock()
        let messages = streamParser.consume(bytes)
        receivedMessageCount += messages.count

        for message in messages {
            logger.write("RX \(hex(message.bytes))", echo: false)

            if message == HUI.pingReply {
                pingReplyCount += 1
            }

            if message.bytes.count == 3,
               message.bytes[0] == 0xB0,
               message.bytes[1] == 0x0C || message.bytes[1] == 0x2C {
                setAbortLocked(
                    "Detected host-to-surface HUI LED traffic on the input. Disable ipMIDI loopback."
                )
            }
        }
        lock.unlock()
    }

    func currentAbort() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return abortMessage
    }

    func statistics() -> (messages: Int, pingReplies: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (receivedMessageCount, pingReplyCount)
    }

    private func setAbortLocked(_ message: String) {
        guard abortMessage == nil else { return }
        abortMessage = message
        logger.write("ABORT \(message)")
    }
}

private final class ReplayMIDITransport {
    private let logger: ReplayLogger
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    init(
        source: MIDIEndpointDescription,
        destination: MIDIEndpointDescription,
        monitor: ReplayMonitor,
        logger: ReplayLogger
    ) throws {
        self.logger = logger
        self.source = source.endpoint
        self.destination = destination.endpoint

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(
            "SwiftMix Approved Logic Capture Replay" as CFString,
            &newClient
        ) { _ in }
        guard clientStatus == noErr else {
            throw ReplayError.system("CoreMIDI client creation failed (OSStatus \(clientStatus)).")
        }
        client = newClient

        var newInputPort = MIDIPortRef()
        let inputStatus = MIDIInputPortCreateWithBlock(
            client,
            "SwiftMix Replay Monitor Input" as CFString,
            &newInputPort
        ) { [weak monitor] packetList, _ in
            guard let monitor,
                  let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
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
                    monitor.receive(bytes: bytes)
                }

                if packetIndex + 1 < Int(packetList.pointee.numPackets) {
                    packetPointer = MIDIPacketNext(packetPointer)
                }
            }
        }
        guard inputStatus == noErr else {
            throw ReplayError.system("CoreMIDI input creation failed (OSStatus \(inputStatus)).")
        }
        inputPort = newInputPort

        var newOutputPort = MIDIPortRef()
        let outputStatus = MIDIOutputPortCreate(
            client,
            "SwiftMix Replay Output" as CFString,
            &newOutputPort
        )
        guard outputStatus == noErr else {
            throw ReplayError.system("CoreMIDI output creation failed (OSStatus \(outputStatus)).")
        }
        outputPort = newOutputPort

        let connectStatus = MIDIPortConnectSource(inputPort, source.endpoint, nil)
        guard connectStatus == noErr else {
            throw ReplayError.system("Could not connect Bank 1 MIDI source (OSStatus \(connectStatus)).")
        }
    }

    deinit {
        if inputPort != 0, source != 0 {
            MIDIPortDisconnectSource(inputPort, source)
        }
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
        }
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func sendCapturedPacket(_ packet: CapturedHostPacket) throws {
        let captureTime = String(format: "%.6f", packet.relativeTime)
        logger.write(
            "TX frame=\(packet.frameNumber) captureTime=\(captureTime) bytes=\(packet.payload.count) payload=\(hex(packet.payload))",
            echo: false
        )

        let storageSize = max(MemoryLayout<MIDIPacketList>.size, 1_024)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }

        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let firstPacket = MIDIPacketListInit(packetList)
        _ = packet.payload.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(
                packetList,
                storageSize,
                firstPacket,
                0,
                buffer.count,
                buffer.baseAddress!
            )
        }

        let status = MIDISend(outputPort, destination, packetList)
        guard status == noErr else {
            throw ReplayError.system(
                "MIDISend failed for capture frame \(packet.frameNumber) (OSStatus \(status))."
            )
        }
    }
}

private func loadApprovedCapture(at path: String) throws -> CaptureProfile {
    guard FileManager.default.isReadableFile(atPath: path) else {
        throw ReplayError.capture("Capture is not readable: \(path)")
    }
    guard FileManager.default.isExecutableFile(atPath: tsharkPath) else {
        throw ReplayError.capture("Wireshark tshark is required at \(tsharkPath).")
    }

    let sha256 = try captureSHA256(path: path)
    guard sha256 == approvedCaptureSHA256 else {
        throw ReplayError.capture(
            "Capture SHA-256 \(sha256) is not the approved Logic automation capture \(approvedCaptureSHA256)."
        )
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: tsharkPath)
    process.arguments = [
        "-r", path,
        "-T", "fields",
        "-e", "frame.number",
        "-e", "frame.time_relative",
        "-e", "ip.src",
        "-e", "ip.dst",
        "-e", "ip.ttl",
        "-e", "udp.srcport",
        "-e", "udp.dstport",
        "-e", "udp.payload"
    ]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ReplayError.capture("tshark could not decode the capture: \(text)")
    }

    var hostPackets: [CapturedHostPacket] = []
    var surfacePacketCount = 0
    var hostPayloadBytes = 0
    var faderChannels = Set<Int>()
    var pingCount = 0
    var hostSourcePorts = Set<Int>()
    var decodedFrameCount = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 8,
              let frameNumber = Int(fields[0]),
              let relativeTime = TimeInterval(fields[1]),
              let ttl = Int(fields[4]),
              let sourcePort = Int(fields[5]),
              let destinationPort = Int(fields[6]) else {
            throw ReplayError.capture("Malformed tshark row: \(line)")
        }

        let sourceAddress = String(fields[2])
        let destinationAddress = String(fields[3])
        let payload = try decodeHex(String(fields[7]))
        guard !payload.isEmpty, isCompleteMIDIStream(payload) else {
            throw ReplayError.capture("Frame \(frameNumber) does not contain a complete MIDI stream.")
        }
        guard destinationAddress == multicastAddress, destinationPort == bankPort else {
            throw ReplayError.capture(
                "Frame \(frameNumber) targets unexpected destination \(destinationAddress):\(destinationPort)."
            )
        }

        decodedFrameCount += 1
        if sourceAddress == expectedHostAddress {
            guard ttl == 255 else {
                throw ReplayError.capture("Host frame \(frameNumber) has unexpected TTL \(ttl).")
            }
            hostSourcePorts.insert(sourcePort)
            hostPayloadBytes += payload.count
            hostPackets.append(
                CapturedHostPacket(
                    frameNumber: frameNumber,
                    relativeTime: relativeTime,
                    payload: payload
                )
            )

            var parser = MIDIMessageStreamParser()
            for message in parser.consume(payload) {
                if message == HUI.pingRequest {
                    pingCount += 1
                }
                if message.bytes.count == 3,
                   message.bytes[0] == 0xB0,
                   (0x00...0x07).contains(message.bytes[1]) {
                    faderChannels.insert(Int(message.bytes[1]))
                }
            }
        } else if sourceAddress == expectedSurfaceAddress {
            guard ttl == 60, sourcePort == bankPort else {
                throw ReplayError.capture(
                    "Surface frame \(frameNumber) has unexpected TTL/source port \(ttl)/\(sourcePort)."
                )
            }
            surfacePacketCount += 1
        } else {
            throw ReplayError.capture(
                "Frame \(frameNumber) has unexpected source address \(sourceAddress)."
            )
        }
    }

    guard decodedFrameCount == approvedFrameCount,
          hostPackets.count == approvedHostPacketCount,
          hostPayloadBytes == approvedHostPayloadBytes,
          hostSourcePorts == [capturedHostSourcePort],
          let first = hostPackets.first,
          let last = hostPackets.last else {
        throw ReplayError.capture(
            "Capture profile mismatch: frames=\(decodedFrameCount), hostPackets=\(hostPackets.count), hostBytes=\(hostPayloadBytes), hostPorts=\(hostSourcePorts.sorted())."
        )
    }

    let duration = last.relativeTime - first.relativeTime
    guard abs(duration - approvedDuration) < 0.000_001 else {
        throw ReplayError.capture("Capture duration \(duration) does not match approved duration \(approvedDuration).")
    }
    guard faderChannels == Set(0..<8) else {
        throw ReplayError.capture(
            "Capture does not contain all eight expected Bank 1 fader channels: \(faderChannels.sorted())."
        )
    }

    return CaptureProfile(
        sha256: sha256,
        frameCount: decodedFrameCount,
        hostPackets: hostPackets,
        surfacePacketCount: surfacePacketCount,
        hostPayloadBytes: hostPayloadBytes,
        duration: duration,
        faderChannels: faderChannels,
        pingCount: pingCount,
        hostSourcePorts: hostSourcePorts
    )
}

private func captureSHA256(path: String) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", path]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0,
          let hash = text.split(whereSeparator: \.isWhitespace).first else {
        throw ReplayError.capture("Could not calculate capture SHA-256: \(text)")
    }
    return String(hash).lowercased()
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func decodeHex(_ string: String) throws -> [UInt8] {
    let characters = Array(string.utf8)
    guard !characters.isEmpty, characters.count.isMultiple(of: 2) else {
        throw ReplayError.capture("Invalid hexadecimal UDP payload.")
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(characters.count / 2)
    var index = 0
    while index < characters.count {
        guard let high = hexNibble(characters[index]),
              let low = hexNibble(characters[index + 1]) else {
            throw ReplayError.capture("Invalid hexadecimal UDP payload.")
        }
        bytes.append((high << 4) | low)
        index += 2
    }
    return bytes
}

private func hexNibble(_ character: UInt8) -> UInt8? {
    switch character {
    case 48...57:
        return character - 48
    case 65...70:
        return character - 55
    case 97...102:
        return character - 87
    default:
        return nil
    }
}

private func isCompleteMIDIStream(_ bytes: [UInt8]) -> Bool {
    var index = 0
    var runningStatus: UInt8?

    while index < bytes.count {
        let byte = bytes[index]
        if byte >= 0xF8 {
            index += 1
            continue
        }

        if byte & 0x80 != 0 {
            if byte == 0xF0 {
                guard let end = bytes[(index + 1)...].firstIndex(of: 0xF7) else { return false }
                index = end + 1
                runningStatus = nil
                continue
            }
            guard byte < 0xF0 else { return false }
            runningStatus = byte
            index += 1
        }

        guard let status = runningStatus else { return false }
        let high = status & 0xF0
        let dataLength = (high == 0xC0 || high == 0xD0) ? 1 : 2
        guard index + dataLength <= bytes.count else { return false }
        for dataByte in bytes[index..<(index + dataLength)] where dataByte & 0x80 != 0 {
            _ = dataByte
            return false
        }
        index += dataLength
    }

    return true
}

private func endpointSnapshot() -> (sources: [MIDIEndpointDescription], destinations: [MIDIEndpointDescription]) {
    let sources = (0..<MIDIGetNumberOfSources()).compactMap { index -> MIDIEndpointDescription? in
        let endpoint = MIDIGetSource(index)
        guard endpoint != 0 else { return nil }
        return endpointDescription(endpoint, direction: .source)
    }
    let destinations = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> MIDIEndpointDescription? in
        let endpoint = MIDIGetDestination(index)
        guard endpoint != 0 else { return nil }
        return endpointDescription(endpoint, direction: .destination)
    }
    return (
        sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
        destinations.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    )
}

private func endpointDescription(
    _ endpoint: MIDIEndpointRef,
    direction: MIDIEndpointDescription.Direction
) -> MIDIEndpointDescription {
    var uniqueID = MIDIUniqueID()
    MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

    let name = midiStringProperty(endpoint, key: kMIDIPropertyDisplayName)
        ?? midiStringProperty(endpoint, key: kMIDIPropertyName)
        ?? "Unnamed MIDI endpoint"

    return MIDIEndpointDescription(
        endpoint: endpoint,
        uniqueID: uniqueID,
        name: name,
        direction: direction
    )
}

private func midiStringProperty(_ object: MIDIObjectRef, key: CFString) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, key, &value) == noErr,
          let value else {
        return nil
    }
    return value.takeRetainedValue() as String
}

private func resolveBank1Endpoint(
    named name: String,
    direction: MIDIEndpointDescription.Direction,
    candidates: [MIDIEndpointDescription]
) throws -> MIDIEndpointDescription {
    let matches = candidates.filter { $0.name == name }
    guard matches.count == 1, let endpoint = matches.first else {
        if matches.isEmpty {
            throw ReplayError.safety("No \(direction.rawValue) endpoint is named exactly '\(name)'. Run --list.")
        }
        throw ReplayError.safety("More than one \(direction.rawValue) endpoint is named '\(name)'.")
    }
    guard isBank1IPMIDIName(endpoint.name) else {
        throw ReplayError.safety(
            "Refusing endpoint '\(endpoint.name)'. Replay requires ipMIDI Port 1 exactly."
        )
    }
    return endpoint
}

private func isBank1IPMIDIName(_ name: String) -> Bool {
    guard name.localizedCaseInsensitiveContains("ipmidi") else { return false }
    let numbers = name.components(separatedBy: CharacterSet.decimalDigits.inverted)
        .filter { !$0.isEmpty }
    return numbers.contains("1")
}

private func validateRoute(expectedInterface: String) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/sbin/route")
    process.arguments = ["-n", "get", multicastAddress]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ReplayError.safety("No usable multicast route for \(multicastAddress): \(text)")
    }

    let routeInterface = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("interface:") }?
        .split(separator: ":", maxSplits: 1)
        .last?
        .trimmingCharacters(in: .whitespaces)

    guard routeInterface == expectedInterface else {
        throw ReplayError.safety(
            "Multicast route uses '\(routeInterface ?? "unknown")', not required interface '\(expectedInterface)'."
        )
    }
}

private func validateNoCompetingHosts() throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ax", "-o", "comm="]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).lowercased()

    if text.contains("swiftmixnominal") {
        throw ReplayError.safety("Quit the SwiftMixNominal menu-bar app before replay.")
    }
    if text.contains("pro tools") || text.contains("protools") {
        throw ReplayError.safety("Quit Pro Tools before replay.")
    }
    if text.contains("logic pro") {
        throw ReplayError.safety("Quit Logic Pro before replay.")
    }
}

private func printProfile(_ profile: CaptureProfile) {
    print("Approved Logic Bank 1 capture:")
    print("  SHA-256:              \(profile.sha256)")
    print("  Total captured frames: \(profile.frameCount)")
    print("  Host packets replayed: \(profile.hostPackets.count)")
    print("  Surface packets omitted: \(profile.surfacePacketCount)")
    print("  Host MIDI bytes:       \(profile.hostPayloadBytes)")
    print(String(format: "  Replay duration:       %.6f seconds", profile.duration))
    print("  Captured source port:  \(profile.hostSourcePorts.sorted()) (informational only)")
    print("  Destination:           \(multicastAddress):\(bankPort) via ipMIDI Port 1")
    print("  HUI pings replayed:    \(profile.pingCount)")
    print("  Faders addressed:      \(profile.faderChannels.sorted().map { $0 + 1 })")
}

private func printUsage() {
    print("""
    SwiftMix approved Logic Bank 1 capture replay

    Inspect the capture; opens no CoreMIDI client and sends nothing:
      sh Scripts/replay-logic-bank1.sh \\
        --capture "/Users/electric/Logic automation log.pcapng"

    List CoreMIDI endpoints; sends nothing:
      sh Scripts/replay-logic-bank1.sh --list

    Replay the approved capture through ipMIDI Port 1:
      sh Scripts/replay-logic-bank1.sh --execute \\
        --capture "/Users/electric/Logic automation log.pcapng" \\
        --source-name "ipMIDI Port 1" \\
        --destination-name "ipMIDI Port 1" \\
        --expected-interface en5 \\
        --authorization \(replayAuthorization)

    The approved capture lasts 166.600023 seconds and addresses all eight Bank 1 faders.
    Surface-to-host packets are monitored but never retransmitted. The original UDP source
    port 53483 is ephemeral; ipMIDI chooses the replay source port automatically.
    """)
}

private func runReplay(options: Options, profile: CaptureProfile) throws {
    guard isatty(STDIN_FILENO) == 1 else {
        throw ReplayError.safety("Replay requires an interactive terminal; noninteractive execution is refused.")
    }
    guard options.authorization == replayAuthorization else {
        throw ReplayError.safety("Missing exact --authorization \(replayAuthorization).")
    }
    guard let sourceName = options.sourceName,
          let destinationName = options.destinationName,
          let expectedInterface = options.expectedInterface else {
        throw ReplayError.usage(
            "Replay requires --source-name, --destination-name, and --expected-interface."
        )
    }

    try validateNoCompetingHosts()
    try validateRoute(expectedInterface: expectedInterface)

    let endpoints = endpointSnapshot()
    let source = try resolveBank1Endpoint(
        named: sourceName,
        direction: .source,
        candidates: endpoints.sources
    )
    let destination = try resolveBank1Endpoint(
        named: destinationName,
        direction: .destination,
        candidates: endpoints.destinations
    )

    printProfile(profile)
    print("\nDESTRUCTIVE BANK 1 REPLAY")
    print("This will reproduce Logic's captured automation on all eight Bank 1 faders.")
    print("It also replays captured HUI LED updates and keepalive pings.")
    print("The faders will finish at the final positions stored in the capture; no extra restore is added.")
    print("Confirm that audio paths are physically isolated and nobody is touching Bank 1.")
    print("\nType exactly '\(interactiveConfirmation)' to arm replay:")

    guard readLine() == interactiveConfirmation else {
        throw ReplayError.safety("Confirmation did not match. No MIDI was sent.")
    }

    try validateNoCompetingHosts()
    try validateRoute(expectedInterface: expectedInterface)

    let logger = try ReplayLogger()
    logger.write("Replay log: \(logger.path)")
    logger.write("Capture SHA-256: \(profile.sha256)")
    logger.write("Source endpoint: \(source.name) [\(source.uniqueID)]")
    logger.write("Destination endpoint: \(destination.name) [\(destination.uniqueID)]")
    logger.write("Route: \(multicastAddress):\(bankPort) via \(expectedInterface)")
    logger.write("Captured host source port \(capturedHostSourcePort) is ephemeral and will not be forced.")

    let monitor = ReplayMonitor(logger: logger)
    let transport = try ReplayMIDITransport(
        source: source,
        destination: destination,
        monitor: monitor,
        logger: logger
    )

    Thread.sleep(forTimeInterval: 0.25)
    if let abort = monitor.currentAbort() {
        throw ReplayError.safety(abort)
    }

    guard let firstPacket = profile.hostPackets.first else {
        throw ReplayError.capture("Approved capture unexpectedly contains no host packets.")
    }

    let replayStart = ProcessInfo.processInfo.systemUptime
    var nextProgressSecond = 10

    do {
        for (index, packet) in profile.hostPackets.enumerated() {
            let targetUptime = replayStart + packet.relativeTime - firstPacket.relativeTime
            while true {
                if let abort = monitor.currentAbort() {
                    throw ReplayError.safety(abort)
                }
                let remaining = targetUptime - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(remaining, 0.01))
            }

            try transport.sendCapturedPacket(packet)

            let elapsed = ProcessInfo.processInfo.systemUptime - replayStart
            if Int(elapsed) >= nextProgressSecond {
                try validateNoCompetingHosts()
                try validateRoute(expectedInterface: expectedInterface)
                logger.write(
                    String(
                        format: "Progress: %.1f / %.1f seconds, %d / %d packets",
                        elapsed,
                        profile.duration,
                        index + 1,
                        profile.hostPackets.count
                    )
                )
                nextProgressSecond += 10
            }
        }

        Thread.sleep(forTimeInterval: 0.5)
        if let abort = monitor.currentAbort() {
            throw ReplayError.safety(abort)
        }
    } catch {
        logger.write("REPLAY STOPPED: \(error)")
        logger.synchronize()
        throw error
    }

    let stats = monitor.statistics()
    logger.write(
        "REPLAY COMPLETE: sent \(profile.hostPackets.count) captured host packets; received \(stats.messages) MIDI messages including \(stats.pingReplies) ping replies."
    )
    logger.write("Full log: \(logger.path)")
    logger.synchronize()
}

private func run() throws {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))

    if options.showHelp {
        printUsage()
        return
    }

    if options.listEndpoints {
        let endpoints = endpointSnapshot()
        print("CoreMIDI sources:")
        for endpoint in endpoints.sources {
            print("  [\(endpoint.uniqueID)] \(endpoint.name)")
        }
        print("\nCoreMIDI destinations:")
        for endpoint in endpoints.destinations {
            print("  [\(endpoint.uniqueID)] \(endpoint.name)")
        }
        return
    }

    guard let capturePath = options.capturePath else {
        throw ReplayError.usage("Provide --capture PATH, or use --help.")
    }
    let profile = try loadApprovedCapture(at: capturePath)

    if options.execute {
        try runReplay(options: options, profile: profile)
    } else {
        print("DRY RUN — capture verified; no CoreMIDI client or ports were opened and nothing was sent.\n")
        printProfile(profile)
        print("\nRun with --help for the explicitly armed replay syntax.")
    }
}

do {
    try run()
} catch {
    fputs("SwiftMixCaptureReplay: \(error)\n", stderr)
    exit(1)
}
