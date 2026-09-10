import CoreMIDI
import Darwin
import Foundation
import SwiftMixCore

private let multicastAddress = "225.0.0.37"
private let authorizationToken = "SWIFTMIX_32_FADER_SINE_APPROVED"
private let confirmationPhrase = "RUN SINE WAVE ON FADERS 1-32"
private let bankCount = 4
private let fadersPerBank = 8
private let totalFaders = bankCount * fadersPerBank

private enum SineError: Error, CustomStringConvertible {
    case usage(String)
    case safety(String)
    case system(String)

    var description: String {
        switch self {
        case let .usage(message), let .safety(message), let .system(message):
            return message
        }
    }
}

private struct Options {
    var showHelp = false
    var listEndpoints = false
    var execute = false
    var expectedInterface: String?
    var authorization: String?
    var duration: TimeInterval = 60
    var amplitude = 4_000
    var period: TimeInterval = 4
    var frameRate: Double = 30

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else {
                throw SineError.usage("Missing value after \(option).")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": options.showHelp = true
            case "--list": options.listEndpoints = true
            case "--execute": options.execute = true
            case "--expected-interface": options.expectedInterface = try value(after: argument)
            case "--authorization": options.authorization = try value(after: argument)
            case "--duration":
                guard let parsed = TimeInterval(try value(after: argument)), parsed > 0, parsed <= 300 else {
                    throw SineError.usage("--duration must be greater than 0 and no more than 300 seconds.")
                }
                options.duration = parsed
            case "--amplitude":
                guard let parsed = Int(try value(after: argument)), parsed > 0,
                      HUI.defaultNominalValue - parsed >= HUI.minimumFaderValue,
                      HUI.defaultNominalValue + parsed <= HUI.maximumFaderValue else {
                    throw SineError.usage("--amplitude must keep the wave within HUI raw range 0...16383 around nominal 12320 (maximum 4063).")
                }
                options.amplitude = parsed
            case "--period":
                guard let parsed = TimeInterval(try value(after: argument)), parsed >= 1, parsed <= 30 else {
                    throw SineError.usage("--period must be between 1 and 30 seconds.")
                }
                options.period = parsed
            case "--frame-rate":
                guard let parsed = Double(try value(after: argument)), parsed >= 10, parsed <= 60 else {
                    throw SineError.usage("--frame-rate must be between 10 and 60 Hz.")
                }
                options.frameRate = parsed
            default:
                throw SineError.usage("Unknown argument: \(argument)")
            }
            index += 1
        }
        return options
    }
}

private struct Endpoint {
    enum Direction: String { case source, destination }
    let ref: MIDIEndpointRef
    let uniqueID: MIDIUniqueID
    let name: String
    let direction: Direction
}

private final class Monitor {
    private let lock = NSLock()
    private var parsers = [0: MIDIMessageStreamParser(), 1: MIDIMessageStreamParser()]
    private var pingReplies = [0: 0, 1: 0]
    private var abortReason: String?

    func receive(bank: Int, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard var parser = parsers[bank] else { return }
        let messages = parser.consume(bytes)
        parsers[bank] = parser

        for message in messages {
            if message == HUI.pingReply {
                pingReplies[bank, default: 0] += 1
            }
            if message.bytes.count == 3,
               message.bytes[0] == 0xB0,
               message.bytes[1] == 0x0C || message.bytes[1] == 0x2C {
                abortReason = abortReason ?? "Detected host LED traffic returning on ipMIDI Port \(bank + 1). Disable ipMIDI loopback."
            }
        }
    }

    func abort() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return abortReason
    }

    func replyCounts() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<bankCount).map { pingReplies[$0, default: 0] }
    }
}

private final class StopFlag {
    private let lock = NSLock()
    private var stopped = false

    func request() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func isRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class MIDITransport {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var sources: [MIDIEndpointRef] = []
    private let destinations: [MIDIEndpointRef]

    init(sources: [Endpoint], destinations: [Endpoint], monitor: Monitor) throws {
        self.destinations = destinations.map(\.ref)

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("SwiftMix 32 Fader Sine Wave" as CFString, &newClient) { _ in }
        guard clientStatus == noErr else {
            throw SineError.system("CoreMIDI client creation failed (OSStatus \(clientStatus)).")
        }
        client = newClient

        var newInputPort = MIDIPortRef()
        let inputStatus = MIDIInputPortCreateWithBlock(
            client,
            "SwiftMix Sine Monitor" as CFString,
            &newInputPort
        ) { packetList, sourceConnectionReference in
            guard let sourceConnectionReference,
                  let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet),
                  let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) else { return }
            let bank = Int(bitPattern: sourceConnectionReference) - 1
            guard (0..<bankCount).contains(bank) else { return }

            var packet = UnsafeMutableRawPointer(mutating: packetList)
                .advanced(by: packetOffset)
                .assumingMemoryBound(to: MIDIPacket.self)
            for index in 0..<Int(packetList.pointee.numPackets) {
                let length = Int(packet.pointee.length)
                let bytes = Array(UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(packet).advanced(by: dataOffset),
                    count: length
                ))
                if !bytes.isEmpty { monitor.receive(bank: bank, bytes: bytes) }
                if index + 1 < Int(packetList.pointee.numPackets) { packet = MIDIPacketNext(packet) }
            }
        }
        guard inputStatus == noErr else {
            throw SineError.system("CoreMIDI input creation failed (OSStatus \(inputStatus)).")
        }
        inputPort = newInputPort

        var newOutputPort = MIDIPortRef()
        let outputStatus = MIDIOutputPortCreate(client, "SwiftMix Sine Output" as CFString, &newOutputPort)
        guard outputStatus == noErr else {
            throw SineError.system("CoreMIDI output creation failed (OSStatus \(outputStatus)).")
        }
        outputPort = newOutputPort

        for (bank, source) in sources.enumerated() {
            let reference = UnsafeMutableRawPointer(bitPattern: bank + 1)
            let status = MIDIPortConnectSource(inputPort, source.ref, reference)
            guard status == noErr else {
                throw SineError.system("Could not connect ipMIDI Port \(bank + 1) source (OSStatus \(status)).")
            }
            self.sources.append(source.ref)
        }
    }

    deinit {
        for source in sources where inputPort != 0 { MIDIPortDisconnectSource(inputPort, source) }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func send(_ payload: [UInt8], bank: Int) throws {
        guard destinations.indices.contains(bank), !payload.isEmpty else {
            throw SineError.system("Invalid Bank \(bank + 1) MIDI transmission.")
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
            MIDIPacketListAdd(packetList, storageSize, firstPacket, 0, buffer.count, buffer.baseAddress!)
        }
        let status = MIDISend(outputPort, destinations[bank], packetList)
        guard status == noErr else {
            throw SineError.system("MIDISend failed for Bank \(bank + 1) (OSStatus \(status)).")
        }
    }
}

private func endpointSnapshot() -> (sources: [Endpoint], destinations: [Endpoint]) {
    func describe(_ ref: MIDIEndpointRef, direction: Endpoint.Direction) -> Endpoint {
        var uniqueID = MIDIUniqueID()
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uniqueID)
        var property: Unmanaged<CFString>?
        let displayStatus = MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &property)
        if displayStatus != noErr { MIDIObjectGetStringProperty(ref, kMIDIPropertyName, &property) }
        return Endpoint(ref: ref, uniqueID: uniqueID, name: property?.takeRetainedValue() as String? ?? "Unnamed MIDI endpoint", direction: direction)
    }

    return (
        (0..<MIDIGetNumberOfSources()).compactMap { index in
            let ref = MIDIGetSource(index)
            return ref == 0 ? nil : describe(ref, direction: .source)
        },
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let ref = MIDIGetDestination(index)
            return ref == 0 ? nil : describe(ref, direction: .destination)
        }
    )
}

private func resolve(port: Int, direction: Endpoint.Direction, candidates: [Endpoint]) throws -> Endpoint {
    let expectedName = "ipMIDI Port \(port)"
    let matches = candidates.filter { $0.name == expectedName }
    guard matches.count == 1, let match = matches.first else {
        throw SineError.safety("Expected exactly one \(direction.rawValue) named '\(expectedName)'; found \(matches.count). Run --list.")
    }
    return match
}

private func validateRoute(expectedInterface: String) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/sbin/route")
    process.arguments = ["-n", "get", multicastAddress]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SineError.safety("No usable multicast route for \(multicastAddress): \(text)")
    }
    let routeInterface = text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("interface:") }?
        .split(separator: ":", maxSplits: 1).last?
        .trimmingCharacters(in: .whitespaces)
    guard routeInterface == expectedInterface else {
        throw SineError.safety("Multicast route uses '\(routeInterface ?? "unknown")', not '\(expectedInterface)'.")
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
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
    process.waitUntilExit()
    if text.contains("swiftmixnominal") { throw SineError.safety("Quit SwiftMixNominal before this test.") }
    if text.contains("logic pro") { throw SineError.safety("Quit Logic Pro before this test.") }
    if text.contains("pro tools") || text.contains("protools") { throw SineError.safety("Quit Pro Tools before this test.") }
}

private func initializationPayload() -> [UInt8] {
    (0..<fadersPerBank).flatMap { zone in
        [0xB0, 0x0C, UInt8(zone), 0xB0, 0x2C, 0x07]
    }
}

private func snapshotPayload(values: ArraySlice<Int>) throws -> [UInt8] {
    guard values.count == fadersPerBank else { throw SineError.system("A bank snapshot must contain eight values.") }
    return try values.enumerated().flatMap { localFader, value in
        try HUI.faderPosition(fader: localFader, value: value).flatMap(\.bytes)
    }
}

private func sendAll(_ payloads: [[UInt8]], transport: MIDITransport) throws {
    for bank in 0..<bankCount { try transport.send(payloads[bank], bank: bank) }
}

private func printUsage() {
    print("""
    SwiftMix 32-fader sine-wave test (ipMIDI Ports 1–4)

    Dry-run plan; sends nothing:
      sh Scripts/sine-wave-faders-1-32.sh

    List CoreMIDI endpoints; sends nothing:
      sh Scripts/sine-wave-faders-1-32.sh --list

    Execute the default 60-second wave (raw 8320...16320, 4-second period, 30 Hz):
      sh Scripts/sine-wave-faders-1-32.sh --execute \\
        --expected-interface en5 \\
        --authorization \(authorizationToken)

    Optional: --duration SECONDS --amplitude RAW --period SECONDS --frame-rate HZ

    The test sends complete Bank 1–4 snapshots through exact destinations
    'ipMIDI Port 1' through 'ipMIDI Port 4'. It restores all 32 faders to verified nominal
    raw \(HUI.defaultNominalValue) on normal completion, Ctrl-C, or detected safety stop.
    """)
}

private func runTest(options: Options) throws {
    guard isatty(STDIN_FILENO) == 1 else { throw SineError.safety("Execution requires an interactive terminal.") }
    guard options.authorization == authorizationToken else {
        throw SineError.safety("Missing exact --authorization \(authorizationToken).")
    }
    guard let expectedInterface = options.expectedInterface else {
        throw SineError.usage("Execution requires --expected-interface.")
    }

    try validateNoCompetingHosts()
    try validateRoute(expectedInterface: expectedInterface)
    let endpoints = endpointSnapshot()
    let sources = try (1...bankCount).map { try resolve(port: $0, direction: .source, candidates: endpoints.sources) }
    let destinations = try (1...bankCount).map { try resolve(port: $0, direction: .destination, candidates: endpoints.destinations) }

    let lower = HUI.defaultNominalValue - options.amplitude
    let upper = HUI.defaultNominalValue + options.amplitude
    print("DESTRUCTIVE 32-FADER MOTOR TEST")
    print("Ports: ipMIDI 1 → faders 1–8; 2 → 9–16; 3 → 17–24; 4 → 25–32")
    print("Wave: raw \(lower)...\(upper), period \(options.period)s, \(options.frameRate) Hz, duration \(options.duration)s")
    print("All faders restore to nominal raw \(HUI.defaultNominalValue) when the controlled loop exits.")
    print("Confirm audio is isolated and nobody is touching faders 1–32.")
    print("\nType exactly '\(confirmationPhrase)' to continue:")
    guard readLine() == confirmationPhrase else { throw SineError.safety("Confirmation did not match. Nothing was sent.") }

    try validateNoCompetingHosts()
    try validateRoute(expectedInterface: expectedInterface)

    let monitor = Monitor()
    let transport = try MIDITransport(sources: sources, destinations: destinations, monitor: monitor)
    let stopFlag = StopFlag()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interruptSource.setEventHandler { stopFlag.request() }
    terminateSource.setEventHandler { stopFlag.request() }
    interruptSource.resume()
    terminateSource.resume()

    let nominalValues = Array(repeating: HUI.defaultNominalValue, count: totalFaders)
    let nominalPayloads = try (0..<bankCount).map { bank in
        try snapshotPayload(values: nominalValues[(bank * fadersPerBank)..<((bank + 1) * fadersPerBank)])
    }

    var didStartTransmission = false
    defer {
        if didStartTransmission {
            try? sendAll(nominalPayloads, transport: transport)
            Thread.sleep(forTimeInterval: 0.1)
            try? sendAll(nominalPayloads, transport: transport)
            print("Restored faders 1–32 to nominal raw \(HUI.defaultNominalValue).")
        }
    }

    for bank in 0..<bankCount {
        try transport.send(initializationPayload(), bank: bank)
        try transport.send(HUI.pingRequest.bytes, bank: bank)
        try transport.send(nominalPayloads[bank], bank: bank)
    }
    didStartTransmission = true
    Thread.sleep(forTimeInterval: 0.25)
    if let abort = monitor.abort() { throw SineError.safety(abort) }

    let start = ProcessInfo.processInfo.systemUptime
    let frameInterval = 1 / options.frameRate
    var frame = 0
    var nextPing = start + 0.3
    var lastSafetyCheck = start

    while true {
        if stopFlag.isRequested() { print("Stop requested; ending wave."); break }
        if let abort = monitor.abort() { throw SineError.safety(abort) }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - start
        if elapsed >= options.duration { break }

        let target = start + Double(frame) * frameInterval
        if now < target {
            Thread.sleep(forTimeInterval: min(target - now, 0.005))
            continue
        }

        let values = (0..<totalFaders).map { channel -> Int in
            let channelPhase = 2 * Double.pi * Double(channel) / Double(totalFaders)
            let timePhase = 2 * Double.pi * elapsed / options.period
            return HUI.defaultNominalValue + Int((Double(options.amplitude) * sin(timePhase - channelPhase)).rounded())
        }
        let payloads = try (0..<bankCount).map { bank in
            try snapshotPayload(values: values[(bank * fadersPerBank)..<((bank + 1) * fadersPerBank)])
        }
        try sendAll(payloads, transport: transport)
        frame += 1

        if now >= nextPing {
            for bank in 0..<bankCount { try transport.send(HUI.pingRequest.bytes, bank: bank) }
            nextPing += 0.3
        }
        if now - lastSafetyCheck >= 5 {
            try validateNoCompetingHosts()
            try validateRoute(expectedInterface: expectedInterface)
            let replies = monitor.replyCounts()
            guard replies.allSatisfy({ $0 > 0 }) else {
                throw SineError.safety("Missing HUI ping reply from one or more banks: \(replies).")
            }
            print(String(format: "Progress %.1f / %.1f seconds; ping replies %@", elapsed, options.duration, String(describing: replies)))
            lastSafetyCheck = now
        }
    }

    let replies = monitor.replyCounts()
    print("Sine-wave test complete; ping replies by bank: \(replies).")
}

private func run() throws {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    if options.showHelp { printUsage(); return }
    if options.listEndpoints {
        let endpoints = endpointSnapshot()
        print("CoreMIDI sources:")
        for endpoint in endpoints.sources.sorted(by: { $0.name < $1.name }) { print("  [\(endpoint.uniqueID)] \(endpoint.name)") }
        print("\nCoreMIDI destinations:")
        for endpoint in endpoints.destinations.sorted(by: { $0.name < $1.name }) { print("  [\(endpoint.uniqueID)] \(endpoint.name)") }
        return
    }
    if options.execute { try runTest(options: options); return }

    let lower = HUI.defaultNominalValue - options.amplitude
    let upper = HUI.defaultNominalValue + options.amplitude
    print("DRY RUN — no CoreMIDI client was opened and nothing was sent.")
    print("Would drive faders 1–32 through ipMIDI Ports 1–4.")
    print("Wave raw range: \(lower)...\(upper); period: \(options.period)s; frame rate: \(options.frameRate) Hz; duration: \(options.duration)s.")
    print("All faders would be restored to nominal raw \(HUI.defaultNominalValue).")
    print("Run with --help for the explicitly armed command.")
}

do {
    try run()
} catch {
    fputs("SwiftMixSineWave: \(error)\n", stderr)
    exit(1)
}
