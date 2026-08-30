import Darwin
import Foundation
import NativeUDPTransport
import SwiftMixCore

private var failures: [String] = []
private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures.append(message)
    }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures.append(message)
    } catch {
        // Any throw satisfies callers that only test invalid construction.
    }
}

let profile = ProvisionalIPMIDIWireProfile.unverifiedIPMIDIDefaults
expect(profile.multicastGroup.value.description == "225.0.0.37", "Provisional multicast group")
expect(profile.baseUDPPort.value == 21_928, "Provisional base UDP port")
expect(profile.logicalBankCount.value == 4, "Provisional bank count")
expect(profile.multicastTTL.value == 1, "Conservative multicast TTL")
expect(!profile.localMulticastLoopback.value, "Conservative loopback default")
expect(
    profile.payloadPacking.value == .unverifiedRawMIDIBytesPerDatagram,
    "Provisional raw MIDI payload packing"
)
expect(
    IPMIDIBank.allCases.map { profile.port(for: $0) } == [21_928, 21_929, 21_930, 21_931],
    "Bank-to-port mapping"
)

for validBank in 1...4 {
    do {
        let bank = try IPMIDIBank(number: validBank)
        expect(bank.rawValue == validBank, "Bank \(validBank) bound")
    } catch {
        failures.append("Valid bank \(validBank) threw: \(error)")
    }
}
expectThrows("Bank 0 was accepted") { _ = try IPMIDIBank(number: 0) }
expectThrows("Bank 5 was accepted") { _ = try IPMIDIBank(number: 5) }

expectThrows("Non-multicast group was accepted") {
    _ = try ProvisionalIPMIDIWireProfile(
        multicastGroup: IPv4Address("192.0.2.1"),
        baseUDPPort: 21_928
    )
}
expectThrows("Overflowing base port was accepted") {
    _ = try ProvisionalIPMIDIWireProfile(
        multicastGroup: IPv4Address("225.0.0.37"),
        baseUDPPort: 65_534
    )
}
expectThrows("Zero multicast TTL was accepted") {
    _ = try ProvisionalIPMIDIWireProfile(
        multicastGroup: IPv4Address("225.0.0.37"),
        baseUDPPort: 21_928,
        multicastTTL: 0
    )
}
expectThrows("Invalid IPv4 text was accepted") { _ = try IPv4Address("not-an-address") }
expectThrows("Empty interface was accepted") {
    _ = try NativeUDPConfiguration(interfaceBSDName: "")
}
expectThrows("No-bank configuration was accepted") {
    _ = try NativeUDPConfiguration(interfaceBSDName: "en7", banks: [])
}
expectThrows("Duplicate-bank configuration was accepted") {
    _ = try NativeUDPConfiguration(
        interfaceBSDName: "en7",
        banks: [.bank1, .bank1]
    )
}
expectThrows("Zero packet bound was accepted") {
    _ = try NativeUDPConfiguration(interfaceBSDName: "en7", maximumPacketSize: 0)
}
expectThrows("Oversized packet bound was accepted") {
    _ = try NativeUDPConfiguration(interfaceBSDName: "en7", maximumPacketSize: 65_508)
}

checks += 1
do {
    _ = try TransmissionPolicy.requireVerified(.denied)
    failures.append("Denied transmission policy was accepted")
} catch NativeUDPError.transmissionNotAuthorized {
    // Expected. This test never constructs or opens a socket.
} catch {
    failures.append("Denied transmission policy returned wrong error: \(error)")
}
expectThrows("Empty capture identifier was accepted") {
    _ = try ProtocolVerification(captureIdentifier: " ", protocolRevision: "r1")
}
expectThrows("Empty protocol revision was accepted") {
    _ = try ProtocolVerification(captureIdentifier: "capture-001", protocolRevision: "")
}
do {
    let verification = try ProtocolVerification(
        captureIdentifier: "capture-001",
        protocolRevision: "trial-driver-observation-r1"
    )
    let accepted = try TransmissionPolicy.requireVerified(.verified(verification))
    expect(accepted == verification, "Explicit verified transmission authorization")
} catch {
    failures.append("Valid transmission authorization threw: \(error)")
}

expect(CaptureEncoding.hex([0x00, 0x0F, 0x10, 0xFF]) == "00 0F 10 FF", "Raw payload hex")
let packet = ReceivedUDPPacket(
    timestamp: Date(timeIntervalSince1970: 0),
    bank: .bank1,
    localDestinationPort: 21_928,
    source: IPv4Endpoint(address: try IPv4Address("192.0.2.10"), port: 5_000),
    payload: [0x00, 0x0F, 0x10, 0xFF]
)
do {
    let line = try CaptureEncoding.jsonLine(
        packet: packet,
        decoded: ConservativeMIDIDecodeResult(messages: [], events: [])
    )
    let expected = "{\"bank\":1,\"byteCount\":4,\"decodedHUI\":[],\"decodedMIDI\":[],\"localDestinationPort\":21928,\"payloadHex\":\"00 0F 10 FF\",\"sourceAddress\":\"192.0.2.10\",\"sourcePort\":5000,\"timestamp\":\"1970-01-01T00:00:00.000Z\"}"
    expect(line == expected, "Deterministic JSONL capture encoding")
    expect(!line.contains("\n"), "JSONL encoder returns exactly one line without terminator")
} catch {
    failures.append("JSONL capture encoding threw: \(error)")
}

var decoder = ConservativeMIDIDecoder()
let pingResult = decoder.decode(
    payload: HUI.pingRequest.bytes + HUI.pingReply.bytes,
    bank: .bank1
)
expect(
    pingResult.messages.map(\.interpretation) == [.pingRequest, .pingReply],
    "Ping request/reply conservative decoding"
)
expect(pingResult.events == [.pingReply], "HUI ping reply event decoding")

do {
    let faderMessages = try HUI.faderPosition(fader: 3, value: HUI.defaultNominalValue)
    let faderResult = decoder.decode(
        payload: faderMessages.flatMap(\.bytes),
        bank: .bank1
    )
    expect(
        faderResult.events == [.faderPosition(fader: 3, value: HUI.defaultNominalValue)],
        "HUI fader MSB/LSB pair decoding"
    )
} catch {
    failures.append("Root SwiftMixCore fader encoding threw: \(error)")
}

var splitDecoder = ConservativeMIDIDecoder()
let splitFirst = splitDecoder.decode(payload: [0xB0, 0x03, 0x60], bank: .bank2)
let splitSecond = splitDecoder.decode(payload: [0x23, 0x20], bank: .bank2)
expect(splitFirst.events.isEmpty, "Split fader pair waits for LSB")
expect(
    splitSecond.events == [.faderPosition(fader: 3, value: HUI.defaultNominalValue)],
    "Running-status fader LSB across datagrams"
)

if failures.isEmpty {
    print("Native UDP transport self-tests passed (\(checks) checks; no sockets opened).")
} else {
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    fputs("\(failures.count) failure(s) across \(checks) checks.\n", stderr)
    exit(1)
}
