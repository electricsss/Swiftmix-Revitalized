import Darwin
import Dispatch
import Foundation
import SwiftMixCore
import SwiftMixNativeUDP

private let authorization = "SWIFTMIX_NATIVE_32_FADER_TEST_APPROVED"
private let confirmation = "RUN NATIVE ETHERNET TEST ON FADERS 1-32"
private let duration: TimeInterval = 60
private let amplitude = 4_000
private let period: TimeInterval = 4
private let frameRate = 30.0

private enum TestError: Error, CustomStringConvertible {
    case usage(String)
    case safety(String)
    var description: String {
        switch self { case let .usage(value), let .safety(value): return value }
    }
}

private final class TestState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var replies = Array(repeating: 0, count: 4)
    private var failure: String?

    func stop() { lock.withLock { stopRequested = true } }
    func shouldStop() -> Bool { lock.withLock { stopRequested } }
    func record(_ event: NativeUDPReceiveEvent) {
        lock.withLock {
            switch event {
            case let .failure(error): failure = "Native receive failure: \(error)"
            case let .packet(packet):
                var parser = MIDIMessageStreamParser()
                for message in parser.consume(packet.payload) where message == HUI.pingReply {
                    replies[packet.bank.rawValue - 1] += 1
                }
            }
        }
    }
    func snapshot() -> (replies: [Int], failure: String?) {
        lock.withLock { (replies, failure) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}

private func payload(_ messages: [MIDIMessage]) -> [UInt8] {
    messages.flatMap(\.bytes)
}

private func bankPayload(values: ArraySlice<Int>) throws -> [UInt8] {
    payload(try HUI.bankSnapshot(values: Array(values)))
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
    if text.contains("swiftmixnominal") { throw TestError.safety("Quit SwiftMixNominal before running this standalone test.") }
    if text.contains("logic pro") { throw TestError.safety("Quit Logic Pro before running this test.") }
    if text.contains("pro tools") || text.contains("protools") { throw TestError.safety("Quit Pro Tools before running this test.") }
}

private func usage() {
    print("""
    Native SwiftMix Ethernet 32-fader test — bypasses ipMIDI

    Dry run (opens no sockets and sends nothing):
      sh Scripts/test-native-ethernet-32.sh --interface en5

    Execute:
      sh Scripts/test-native-ethernet-32.sh --execute --interface en5 \\
        --authorization \(authorization)

    The live test runs a raw 8320...16320 sine wave for 60 seconds through native
    multicast UDP ports 21928–21931, then restores raw nominal 12320.
    """)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") { usage(); return }
    let execute = arguments.contains("--execute")

    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    guard let interface = option("--interface") else { throw TestError.usage("Provide --interface, for example --interface en5.") }

    if !execute {
        print("DRY RUN — no sockets opened and nothing sent.")
        print("Would bind native SwiftMix banks 1–4 directly to \(interface).")
        print("Receive ports: 21928–21931; transmit ports: macOS-assigned ephemeral ports.")
        print("Wave: raw 8320...16320, 4-second period, 30 Hz, 60 seconds; final nominal: 12320.")
        return
    }

    guard isatty(STDIN_FILENO) == 1 else { throw TestError.safety("An interactive terminal is required.") }
    guard option("--authorization") == authorization else { throw TestError.safety("Missing exact authorization token.") }
    try validateNoCompetingHosts()

    print("DESTRUCTIVE NATIVE ETHERNET TEST")
    print("This bypasses ipMIDI and drives all 32 faders through \(interface).")
    print("Disable the ipMIDI driver, isolate audio, and keep hands clear of every fader.")
    print("Type exactly '\(confirmation)' to continue:")
    guard readLine() == confirmation else { throw TestError.safety("Confirmation did not match. No sockets were opened.") }
    try validateNoCompetingHosts()

    let configuration = try NativeUDPConfiguration(interfaceBSDName: interface)
    let verification = try ProtocolVerification(
        captureIdentifier: "logic-automation-5b7f906be297435fe62cbaa06b0cc1859e1f25d7785d4cbb2d28f38ee38ed3dc",
        protocolRevision: "swiftmix-ipmidi-wire-r1"
    )
    let transport = NativeUDPTransport(
        configuration: configuration,
        receiveAuthorization: .receiveOnly,
        transmissionAuthorization: .verified(verification)
    )
    let state = TestState()
    try transport.start { state.record($0) }
    defer { transport.stop() }

    for bank in IPMIDIBank.allCases {
        print("Bank \(bank.rawValue): receive UDP \(configuration.wireProfile.port(for: bank)), transmit source UDP \(try transport.transmitSourcePort(on: bank))")
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { state.stop() }
    terminate.setEventHandler { state.stop() }
    interrupt.resume(); terminate.resume()

    let nominal = Array(repeating: HUI.defaultNominalValue, count: 32)
    let nominalPayloads = try (0..<4).map { bank in
        try bankPayload(values: nominal[(bank * 8)..<((bank + 1) * 8)])
    }
    var transmissionStarted = false
    defer {
        if transmissionStarted {
            for _ in 0..<2 {
                for bank in IPMIDIBank.allCases { try? transport.send(nominalPayloads[bank.rawValue - 1], on: bank) }
                Thread.sleep(forTimeInterval: 0.1)
            }
            print("Restored all 32 faders to nominal raw 12320.")
        }
    }

    for bank in IPMIDIBank.allCases {
        try transport.send(payload(HUI.bankInitialization), on: bank)
        try transport.send(HUI.pingRequest.bytes, on: bank)
        try transport.send(nominalPayloads[bank.rawValue - 1], on: bank)
    }
    transmissionStarted = true

    let start = ProcessInfo.processInfo.systemUptime
    var frame = 0
    var nextPing = start + 0.3
    var nextCheck = start + 5
    while true {
        if state.shouldStop() { print("Stop requested."); break }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - start
        if elapsed >= duration { break }
        if let failure = state.snapshot().failure { throw TestError.safety(failure) }

        let target = start + Double(frame) / frameRate
        if now < target { Thread.sleep(forTimeInterval: min(target - now, 0.005)); continue }
        let values = (0..<32).map { channel in
            let phase = 2 * Double.pi * Double(channel) / 32
            return HUI.defaultNominalValue + Int((Double(amplitude) * sin(2 * .pi * elapsed / period - phase)).rounded())
        }
        for bank in IPMIDIBank.allCases {
            let index = bank.rawValue - 1
            try transport.send(try bankPayload(values: values[(index * 8)..<((index + 1) * 8)]), on: bank)
        }
        frame += 1

        if now >= nextPing {
            for bank in IPMIDIBank.allCases { try transport.send(HUI.pingRequest.bytes, on: bank) }
            nextPing += 0.3
        }
        if now >= nextCheck {
            try validateNoCompetingHosts()
            let replies = state.snapshot().replies
            guard replies.allSatisfy({ $0 > 0 }) else { throw TestError.safety("Missing ping replies from one or more banks: \(replies).") }
            print(String(format: "Progress %.1f / 60.0 seconds; ping replies %@", elapsed, String(describing: replies)))
            nextCheck += 5
        }
    }
    print("Native test complete; ping replies: \(state.snapshot().replies).")
}

do {
    try run()
} catch {
    fputs("SwiftMixNativeSineWave: \(error)\n", stderr)
    exit(1)
}
