import CoreMIDI
import Darwin
import Foundation
import SwiftMixCore

private let authorizationToken = "SWIFTMIX_FADER1_BOUNDED_PROBE"
private let interactiveConfirmation = "MOVE FADER 1 BY 64"
private let multicastAddress = "225.0.0.37"
private let probeDelta = 64
private let physicalMessageSpacing: TimeInterval = 0.002

private enum ProbeError: Error, CustomStringConvertible {
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

private let observedLEDConfigurations = [
    "READ + TOUCH lit",
    "READ + LATCH lit"
]

private struct Options {
    var showHelp = false
    var listEndpoints = false
    var execute = false
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
                throw ProbeError.usage("Missing value after \(option).")
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
            case "--source-name":
                options.sourceName = try value(after: argument)
            case "--destination-name":
                options.destinationName = try value(after: argument)
            case "--expected-interface":
                options.expectedInterface = try value(after: argument)
            case "--authorization":
                options.authorization = try value(after: argument)
            default:
                throw ProbeError.usage("Unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }
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

private final class ProbeLogger {
    let path: String

    private let lock = NSLock()
    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    init() throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        path = "/tmp/swiftmix-fader1-probe-\(timestamp).log"
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw ProbeError.system("Could not create probe log at \(path).")
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
            try? handle.synchronize()
        }
        if echo {
            print(message)
        }
    }
}

private struct PositionReport {
    let fader: Int
    let value: Int
    let uptime: TimeInterval
}

private final class ProbeMonitor {
    private let lock = NSLock()
    private let logger: ProbeLogger
    private var streamParser = MIDIMessageStreamParser()
    private var huiParser = HUIFaderParser()
    private var latestFader1: PositionReport?
    private var positionReports: [PositionReport] = []
    private var safetyMonitoringStarted = false
    private var abortMessage: String?

    init(logger: ProbeLogger) {
        self.logger = logger
    }

    func startSafetyMonitoring() {
        lock.lock()
        safetyMonitoringStarted = true
        lock.unlock()
    }

    func receive(bytes: [UInt8]) {
        lock.lock()
        let messages = streamParser.consume(bytes)

        for message in messages {
            logger.write("RX \(hex(message.bytes))")

            if safetyMonitoringStarted,
               message == HUI.pingRequest {
                setAbortLocked("Detected local HUI ping echo. Disable ipMIDI loopback before probing.")
            }

            if safetyMonitoringStarted,
               message.bytes.count == 3,
               message.bytes[0] == 0xB0,
               message.bytes[1] == 0x0C || message.bytes[1] == 0x2C {
                setAbortLocked("Detected host-to-surface switch traffic on the input. Disable MIDI loopback.")
            }

            for event in huiParser.consume(message) {
                switch event {
                case .pingReply:
                    break
                case let .faderPosition(fader, value):
                    let report = PositionReport(
                        fader: fader,
                        value: value,
                        uptime: ProcessInfo.processInfo.systemUptime
                    )
                    positionReports.append(report)
                    if positionReports.count > 256 {
                        positionReports.removeFirst(positionReports.count - 256)
                    }

                    if fader == 0 {
                        latestFader1 = report
                    } else if safetyMonitoringStarted {
                        setAbortLocked(
                            "Bank 1 fader \(fader + 1) reported position \(value). No further probe commands are allowed."
                        )
                    }
                case let .faderTouch(fader, touched):
                    if safetyMonitoringStarted, fader != 0 {
                        setAbortLocked(
                            "Bank 1 fader \(fader + 1) reported touch=\(touched). No further probe commands are allowed."
                        )
                    }
                }
            }
        }

        lock.unlock()
    }

    func recordFailure(_ message: String) {
        lock.lock()
        setAbortLocked(message)
        lock.unlock()
    }

    func currentAbort() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return abortMessage
    }

    func waitForStableFreshBaseline(
        after startedUptime: TimeInterval,
        timeout: TimeInterval,
        quietPeriod: TimeInterval
    ) throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        while ProcessInfo.processInfo.systemUptime < deadline {
            if let abort = currentAbort() {
                throw ProbeError.safety(abort)
            }

            lock.lock()
            let report = latestFader1
            lock.unlock()

            let now = ProcessInfo.processInfo.systemUptime
            if let report,
               report.uptime >= startedUptime,
               now - report.uptime >= quietPeriod {
                guard report.value % 32 == 0 else {
                    throw ProbeError.safety(
                        "Fresh Fader 1 value \(report.value) is not aligned to the SwiftMix 9-bit step size."
                    )
                }
                return report.value
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        throw ProbeError.safety(
            "Timed out waiting for a fresh, stable Fader 1 position. No probe commands were sent."
        )
    }

    func reports(since uptime: TimeInterval) -> [PositionReport] {
        lock.lock()
        defer { lock.unlock() }
        return positionReports.filter { $0.uptime >= uptime }
    }

    private func setAbortLocked(_ message: String) {
        guard abortMessage == nil else { return }
        abortMessage = message
        logger.write("ABORT \(message)")
    }
}

private final class ProbeMIDITransport {
    private let logger: ProbeLogger
    private let transmissionLock = NSLock()
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    init(
        source: MIDIEndpointDescription,
        destination: MIDIEndpointDescription,
        monitor: ProbeMonitor,
        logger: ProbeLogger
    ) throws {
        self.logger = logger
        self.source = source.endpoint
        self.destination = destination.endpoint

        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock(
            "SwiftMix Fader 1 Bounded Probe" as CFString,
            &newClient
        ) { _ in }
        guard clientStatus == noErr else {
            throw ProbeError.system("CoreMIDI client creation failed (OSStatus \(clientStatus)).")
        }
        client = newClient

        var newInputPort = MIDIPortRef()
        let inputStatus = MIDIInputPortCreateWithBlock(
            client,
            "SwiftMix Probe Input" as CFString,
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
            throw ProbeError.system("CoreMIDI input creation failed (OSStatus \(inputStatus)).")
        }
        inputPort = newInputPort

        var newOutputPort = MIDIPortRef()
        let outputStatus = MIDIOutputPortCreate(
            client,
            "SwiftMix Probe Output" as CFString,
            &newOutputPort
        )
        guard outputStatus == noErr else {
            throw ProbeError.system("CoreMIDI output creation failed (OSStatus \(outputStatus)).")
        }
        outputPort = newOutputPort

        let connectStatus = MIDIPortConnectSource(inputPort, source.endpoint, nil)
        guard connectStatus == noErr else {
            throw ProbeError.system("Could not connect Bank 1 MIDI source (OSStatus \(connectStatus)).")
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

    func send(_ messages: [MIDIMessage]) throws {
        transmissionLock.lock()
        defer { transmissionLock.unlock() }

        for (index, message) in messages.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: physicalMessageSpacing)
            }
            logger.write("TX \(hex(message.bytes))")
            let status = sendPhysicalPacket(message.bytes)
            guard status == noErr else {
                throw ProbeError.system("MIDISend failed with OSStatus \(status).")
            }
        }
    }

    private func sendPhysicalPacket(_ payload: [UInt8]) -> OSStatus {
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
}

private final class PingLoop {
    private let transport: ProbeMIDITransport
    private let monitor: ProbeMonitor
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SwiftMixProbe.Ping"))
    private var started = false

    init(transport: ProbeMIDITransport, monitor: ProbeMonitor) {
        self.transport = transport
        self.monitor = monitor
    }

    func start() {
        guard !started else { return }
        started = true
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [transport, monitor] in
            do {
                try transport.send([HUI.pingRequest])
            } catch {
                monitor.recordFailure("HUI ping failed: \(error)")
            }
        }
        timer.resume()
    }

    func stop() {
        guard started else { return }
        timer.cancel()
        started = false
    }
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

private func resolveEndpoint(
    named name: String,
    direction: MIDIEndpointDescription.Direction,
    candidates: [MIDIEndpointDescription]
) throws -> MIDIEndpointDescription {
    let matches = candidates.filter { $0.name == name }
    guard matches.count == 1, let endpoint = matches.first else {
        if matches.isEmpty {
            throw ProbeError.safety("No \(direction.rawValue) endpoint is named exactly '\(name)'. Run --list.")
        }
        throw ProbeError.safety("More than one \(direction.rawValue) endpoint is named '\(name)'.")
    }
    guard isBank1IPMIDIName(endpoint.name) else {
        throw ProbeError.safety(
            "Refusing endpoint '\(endpoint.name)'. The bounded probe requires an ipMIDI endpoint explicitly numbered 1."
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
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        throw ProbeError.safety("No usable multicast route for \(multicastAddress): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    let routeInterface = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("interface:") }?
        .split(separator: ":", maxSplits: 1)
        .last?
        .trimmingCharacters(in: .whitespaces)

    guard routeInterface == expectedInterface else {
        throw ProbeError.safety(
            "Multicast route uses '\(routeInterface ?? "unknown")', not required interface '\(expectedInterface)'."
        )
    }
}

private func validateNoCompetingHostProcesses() throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ax", "-o", "comm="]
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self).lowercased()

    if text.contains("swiftmixnominal") {
        throw ProbeError.safety("Quit the SwiftMixNominal menu-bar app before running the probe.")
    }
    if text.contains("pro tools") || text.contains("protools") {
        throw ProbeError.safety("Quit Pro Tools before running the probe.")
    }
    if text.contains("logic pro") {
        throw ProbeError.safety("Quit Logic Pro before running the probe.")
    }
}


private func targetValue(for baseline: Int) -> Int {
    if baseline <= HUI.maximumFaderValue - probeDelta {
        return baseline + probeDelta
    }
    return baseline - probeDelta
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func printUsage() {
    print("""
    SwiftMix Fader 1 bounded HUI probe

    Dry run (default; opens no MIDI ports and sends nothing):
      sh Scripts/probe-fader1.sh

    List CoreMIDI endpoints (sends nothing):
      sh Scripts/probe-fader1.sh --list

    Execute the bounded physical probe:
      sh Scripts/probe-fader1.sh --execute \\
        --source-name "EXACT BANK 1 SOURCE NAME" \\
        --destination-name "EXACT BANK 1 DESTINATION NAME" \\
        --expected-interface en5 \\
        --authorization \(authorizationToken)

    Execution requires:
      - Pro Tools, Logic Pro, and SwiftMixNominal quit
      - ipMIDI loopback disabled
      - audio paths physically isolated or muted
      - the multicast route bound to the expected Ethernet interface
      - a fresh Fader 1 position report before any probe command
      - interactive confirmation in a terminal

    The tool never transmits guessed automation-mode or LED commands. It asks you to select
    each observed LED configuration locally, then sends only a 64-unit Fader 1 target and its
    live baseline restore. It never connects Banks 2-4.
    """)
}

private func printDryRunPlan() throws {
    let sampleBaseline = HUI.defaultNominalValue
    let sampleTarget = targetValue(for: sampleBaseline)

    print("DRY RUN — no CoreMIDI client or ports were opened; nothing was sent.")
    print("A live execution first requires a fresh, stable Fader 1 report.")
    print("Sample baseline \(sampleBaseline); bounded target \(sampleTarget); delta \(abs(sampleTarget - sampleBaseline)).")

    for configuration in observedLEDConfigurations {
        print("\nOperator selects: \(configuration)")
        for message in try HUI.faderPosition(fader: 0, value: sampleTarget) {
            print("  TX \(hex(message.bytes))")
        }
        for message in try HUI.faderPosition(fader: 0, value: sampleBaseline) {
            print("  RESTORE \(hex(message.bytes))")
        }
    }
}

private func runPhysicalProbe(options: Options) throws {
    guard isatty(STDIN_FILENO) == 1 else {
        throw ProbeError.safety("Execution requires an interactive terminal; piped/noninteractive execution is refused.")
    }
    guard options.authorization == authorizationToken else {
        throw ProbeError.safety("Missing exact --authorization \(authorizationToken).")
    }
    guard let sourceName = options.sourceName,
          let destinationName = options.destinationName,
          let expectedInterface = options.expectedInterface else {
        throw ProbeError.usage(
            "Execution requires --source-name, --destination-name, and --expected-interface."
        )
    }

    try validateNoCompetingHostProcesses()
    try validateRoute(expectedInterface: expectedInterface)

    let snapshot = endpointSnapshot()
    let source = try resolveEndpoint(named: sourceName, direction: .source, candidates: snapshot.sources)
    let destination = try resolveEndpoint(
        named: destinationName,
        direction: .destination,
        candidates: snapshot.destinations
    )

    print("BOUND PHYSICAL TEST")
    print("Source:      \(source.name) [\(source.uniqueID)]")
    print("Destination: \(destination.name) [\(destination.uniqueID)]")
    print("Route:       \(multicastAddress) via \(expectedInterface)")
    print("Maximum movement: \(probeDelta) raw units on Fader 1 only")
    print("Log directory: /tmp")
    print("\nType exactly '\(interactiveConfirmation)' to arm transmission:")

    guard readLine() == interactiveConfirmation else {
        throw ProbeError.safety("Authorization phrase did not match. Nothing was sent.")
    }

    let logger = try ProbeLogger()
    logger.write("Probe log: \(logger.path)")
    logger.write("Source \(source.name) [\(source.uniqueID)]")
    logger.write("Destination \(destination.name) [\(destination.uniqueID)]")
    logger.write("Route \(multicastAddress) via \(expectedInterface)")

    let monitor = ProbeMonitor(logger: logger)
    let transport = try ProbeMIDITransport(
        source: source,
        destination: destination,
        monitor: monitor,
        logger: logger
    )
    monitor.startSafetyMonitoring()

    let pingLoop = PingLoop(transport: transport, monitor: monitor)
    pingLoop.start()
    defer { pingLoop.stop() }

    Thread.sleep(forTimeInterval: 0.3)
    if let abort = monitor.currentAbort() {
        throw ProbeError.safety(abort)
    }

    let baselineStart = ProcessInfo.processInfo.systemUptime
    logger.write(
        "Set Fader 1 to the position that must be restored, then touch/nudge only Fader 1 and release it. Waiting up to 20 seconds."
    )
    let baseline = try monitor.waitForStableFreshBaseline(
        after: baselineStart,
        timeout: 20,
        quietPeriod: 0.5
    )
    let target = targetValue(for: baseline)
    logger.write("Captured baseline \(baseline); bounded target \(target).")

    var baselineNeedsRestore = false
    defer {
        if baselineNeedsRestore {
            if monitor.currentAbort() != nil {
                logger.write("Emergency abort is active; skipped automatic restore to honor the no-further-transmission interlock.")
            } else {
                do {
                    try validateRoute(expectedInterface: expectedInterface)
                    logger.write("Exit cleanup: restoring Fader 1 baseline \(baseline).")
                    try transport.send(try HUI.faderPosition(fader: 0, value: baseline))
                } catch {
                    logger.write("Exit cleanup restore failed or was unsafe: \(error)")
                }
            }
        }
    }

    var successfulConfiguration: String?

    for configuration in observedLEDConfigurations {
        if let abort = monitor.currentAbort() {
            throw ProbeError.safety(abort)
        }

        print("\nUse the physical MODE button until Fader 1 shows: \(configuration)")
        print("Keep your hand off the fader cap, then type READY (or ABORT):")
        let readiness = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard readiness == "READY" else {
            logger.write("Operator aborted before testing \(configuration).")
            return
        }

        if let abort = monitor.currentAbort() {
            throw ProbeError.safety(abort)
        }
        try validateRoute(expectedInterface: expectedInterface)

        let attemptStart = ProcessInfo.processInfo.systemUptime
        logger.write("Configuration '\(configuration)': sending bounded Fader 1 target \(target).")
        baselineNeedsRestore = true
        try transport.send(try HUI.faderPosition(fader: 0, value: target))
        Thread.sleep(forTimeInterval: 1.0)

        if let abort = monitor.currentAbort() {
            throw ProbeError.safety(abort)
        }

        let reports = monitor.reports(since: attemptStart).filter { $0.fader == 0 }
        if reports.isEmpty {
            logger.write("No incoming Fader 1 position report followed the target.")
        } else {
            logger.write("Incoming Fader 1 reports: \(reports.map(\.value).map(String.init).joined(separator: ", "))")
        }

        try validateRoute(expectedInterface: expectedInterface)
        logger.write("Restoring Fader 1 baseline \(baseline) before waiting for operator input.")
        try transport.send(try HUI.faderPosition(fader: 0, value: baseline))
        Thread.sleep(forTimeInterval: 0.5)
        baselineNeedsRestore = false

        if let abort = monitor.currentAbort() {
            throw ProbeError.safety(abort)
        }

        print("Did Fader 1 visibly move with \(configuration)? [y]es / [n]o / [a]bort")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "a"

        switch answer {
        case "y", "yes":
            successfulConfiguration = configuration
        case "n", "no", "":
            break
        default:
            logger.write("Operator aborted after \(configuration).")
            return
        }

        if successfulConfiguration != nil {
            break
        }
    }

    if let abort = monitor.currentAbort() {
        throw ProbeError.safety(abort)
    }

    if let successfulConfiguration {
        logger.write("RESULT: Fader 1 visibly moved with \(successfulConfiguration).")
    } else {
        logger.write("RESULT: No observed LED configuration produced visible Fader 1 movement.")
    }
    logger.write("Probe complete. Full log: \(logger.path)")
}

private func run() throws {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))

    if options.showHelp {
        printUsage()
        return
    }

    if options.listEndpoints {
        let snapshot = endpointSnapshot()
        print("CoreMIDI sources:")
        for endpoint in snapshot.sources {
            print("  [\(endpoint.uniqueID)] \(endpoint.name)")
        }
        print("\nCoreMIDI destinations:")
        for endpoint in snapshot.destinations {
            print("  [\(endpoint.uniqueID)] \(endpoint.name)")
        }
        return
    }

    if options.execute {
        try runPhysicalProbe(options: options)
    } else {
        try printDryRunPlan()
        print("\nRun with --help for the explicitly armed execution syntax.")
    }
}

do {
    try run()
} catch {
    fputs("SwiftMixFaderProbe: \(error)\n", stderr)
    exit(1)
}
