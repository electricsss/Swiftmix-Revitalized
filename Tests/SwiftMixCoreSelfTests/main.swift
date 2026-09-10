import Darwin
import SwiftMixCore
import SwiftMixNativeUDP

var failures: [String] = []
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures.append(message)
    }
}

expect(HUI.pingRequest.bytes == [0x90, 0x00, 0x00], "Ping request bytes")
expect(HUI.pingReply.bytes == [0x90, 0x00, 0x7F], "Ping reply bytes")
expect(HUI.defaultNominalValue == 12_320, "SwiftMix nominal default")

let nativeWireProfile = ProvisionalIPMIDIWireProfile.unverifiedIPMIDIDefaults
expect(nativeWireProfile.multicastGroup.value.description == "225.0.0.37", "Native multicast group")
expect(nativeWireProfile.port(for: .bank1) == 21_928, "Native Bank 1 UDP port")
expect(nativeWireProfile.port(for: .bank2) == 21_929, "Native Bank 2 UDP port")
expect(nativeWireProfile.port(for: .bank3) == 21_930, "Native Bank 3 UDP port")
expect(nativeWireProfile.port(for: .bank4) == 21_931, "Native Bank 4 UDP port")
expect(nativeWireProfile.multicastTTL.value == 255, "Native host multicast TTL")
expect(!nativeWireProfile.localMulticastLoopback.value, "Native multicast loopback disabled")

let nominal = HUI.defaultNominalValue

do {
    let encoded = try HUI.faderPosition(fader: 3, value: nominal)
    expect(
        encoded == [
            MIDIMessage([0xB0, 0x03, 0x60]),
            MIDIMessage([0xB0, 0x23, 0x20])
        ],
        "Nominal fader encoding"
    )
} catch {
    failures.append("Nominal fader encoding unexpectedly threw: \(error)")
}

expect(HUI.bankInitialization.count == 16, "Bank initialization message count")
expect(
    HUI.bankInitialization.prefix(2) == [
        MIDIMessage([0xB0, 0x0C, 0x00]),
        MIDIMessage([0xB0, 0x2C, 0x07])
    ],
    "Bank initialization starts with Logic-compatible zone zero state"
)
expect(
    HUI.bankInitialization.suffix(2) == [
        MIDIMessage([0xB0, 0x0C, 0x07]),
        MIDIMessage([0xB0, 0x2C, 0x07])
    ],
    "Bank initialization ends with Logic-compatible zone seven state"
)

do {
    let snapshot = try HUI.bankSnapshot(values: Array(repeating: nominal, count: 8))
    expect(snapshot.count == 16, "Full bank snapshot message count")
    expect(
        snapshot.prefix(2) == [
            MIDIMessage([0xB0, 0x00, 0x60]),
            MIDIMessage([0xB0, 0x20, 0x20])
        ],
        "Full bank snapshot starts with Fader 1 nominal"
    )
    expect(
        snapshot.suffix(2) == [
            MIDIMessage([0xB0, 0x07, 0x60]),
            MIDIMessage([0xB0, 0x27, 0x20])
        ],
        "Full bank snapshot ends with Fader 8 nominal"
    )
} catch {
    failures.append("Valid full bank snapshot unexpectedly threw: \(error)")
}

do {
    _ = try HUI.bankSnapshot(values: Array(repeating: nominal, count: 7))
    failures.append("Short bank snapshot was accepted")
} catch HUIEncodingError.invalidBankSnapshotCount(7) {
    checks += 1
} catch {
    failures.append("Short bank snapshot returned the wrong error: \(error)")
}

do {
    _ = try HUI.faderPosition(fader: 8, value: 0)
    failures.append("Invalid fader number was accepted")
} catch HUIEncodingError.invalidFader(8) {
    checks += 1
} catch {
    failures.append("Invalid fader returned the wrong error: \(error)")
}

do {
    _ = try HUI.faderPosition(fader: 0, value: 16_384)
    failures.append("Out-of-range fader value was accepted")
} catch HUIEncodingError.invalidValue(16_384) {
    checks += 1
} catch {
    failures.append("Out-of-range value returned the wrong error: \(error)")
}

var huiParser = HUIFaderParser()
expect(huiParser.consume(MIDIMessage([0xB0, 0x03, 0x60])).isEmpty, "Fader MSB waits for LSB")
expect(
    huiParser.consume(MIDIMessage([0xB0, 0x23, 0x20]))
        == [.faderPosition(fader: 3, value: nominal)],
    "Fader pair decoding"
)
expect(
    huiParser.consume(MIDIMessage([0xB0, 0x23, 0x01])).isEmpty,
    "Consumed fader MSB is not reused by an orphaned LSB"
)
expect(huiParser.consume(HUI.pingReply) == [.pingReply], "Ping reply decoding")
expect(huiParser.consume(MIDIMessage([0xB0, 0x0F, 0x02])).isEmpty, "Touch selector waits for value")
expect(
    huiParser.consume(MIDIMessage([0xB0, 0x2F, 0x40]))
        == [.faderTouch(fader: 2, touched: true)],
    "Fader touch decoding"
)

var streamParser = MIDIMessageStreamParser()
expect(streamParser.consume([0xB0, 0x01]).isEmpty, "Split MIDI message waits for remaining data")
expect(
    streamParser.consume([0x60, 0x21, 0x20])
        == [MIDIMessage([0xB0, 0x01, 0x60]), MIDIMessage([0xB0, 0x21, 0x20])],
    "Packet split and running-status decoding"
)

let policy = NominalLockPolicy(nominalValue: nominal, tolerance: 32)
expect(!policy.shouldRestore(observedValue: nominal - 32), "Lower tolerance boundary")
expect(!policy.shouldRestore(observedValue: nominal + 32), "Upper tolerance boundary")
expect(policy.shouldRestore(observedValue: nominal - 33), "Below lower tolerance boundary")
expect(policy.shouldRestore(observedValue: nominal + 33), "Above upper tolerance boundary")
expect(policy.restoreValue(observedValue: 10_000, lockIsArmed: false) == nil, "Disabled lock does not restore")
expect(policy.restoreValue(observedValue: 10_000, lockIsArmed: true) == nominal, "Armed lock restores nominal")
expect(NominalLockPolicy(nominalValue: -1, tolerance: -10).nominalValue == 0, "Minimum value clamp")
expect(NominalLockPolicy(nominalValue: 20_000).nominalValue == 16_383, "Maximum value clamp")
expect(NominalLockPolicy(tolerance: -10).tolerance == 0, "Tolerance clamp")

var trustedNativeSequence = CommissioningSequence(
    channelCount: 1,
    nominalValue: nominal,
    nominalTolerance: 32,
    stageTimeout: 8
)
_ = trustedNativeSequence.start(at: 5)
expect(
    trustedNativeSequence.observe(
        channel: 0,
        value: HUI.maximumFaderValue,
        at: 5.1,
        trustedDirectTargetReport: true
    ) == .send(channel: 0, value: HUI.minimumFaderValue),
    "Trusted native settled-target report advances without an intermediate position"
)

var sequence = CommissioningSequence(
    channelCount: 2,
    nominalValue: nominal,
    nominalTolerance: 32,
    stageTimeout: 8
)
expect(
    sequence.start(at: 10) == .send(channel: 0, value: HUI.maximumFaderValue),
    "Commissioning starts channel 1 at maximum"
)
expect(
    sequence.observe(channel: 0, value: nominal, at: 10) == nil,
    "Report received with the command cannot count as stage travel"
)
expect(
    sequence.observe(channel: 0, value: HUI.maximumFaderValue, at: 10.01) == nil,
    "Immediate target report does not prove movement"
)
expect(
    sequence.observe(channel: 0, value: nominal, at: 10.1) == nil,
    "Commissioning records travel before target"
)
expect(
    sequence.observe(channel: 0, value: HUI.maximumFaderValue - 32, at: 10.5)
        == .send(channel: 0, value: HUI.minimumFaderValue),
    "Maximum report advances the same channel to minimum"
)
expect(sequence.observe(channel: 0, value: 16_000, at: 10.6) == nil, "Minimum stage travel")
expect(
    sequence.observe(channel: 0, value: 32, at: 11)
        == .send(channel: 0, value: nominal),
    "Minimum report advances the same channel to nominal"
)
expect(sequence.observe(channel: 0, value: 100, at: 11.1) == nil, "Nominal stage travel")
expect(
    sequence.observe(channel: 0, value: nominal, at: 11.5)
        == .send(channel: 1, value: HUI.maximumFaderValue),
    "Nominal report advances to the next channel"
)
expect(sequence.completedChannelCount == 1, "Completed channel count")
expect(sequence.observe(channel: 1, value: nominal, at: 11.6) == nil, "Channel 2 maximum travel")
expect(
    sequence.observe(channel: 1, value: HUI.maximumFaderValue, at: 12)
        == .send(channel: 1, value: HUI.minimumFaderValue),
    "Channel 2 maximum"
)
expect(sequence.observe(channel: 1, value: 10_000, at: 12.1) == nil, "Channel 2 minimum travel")
expect(
    sequence.observe(channel: 1, value: HUI.minimumFaderValue, at: 12.5)
        == .send(channel: 1, value: nominal),
    "Channel 2 minimum"
)
expect(sequence.observe(channel: 1, value: 1_000, at: 12.6) == nil, "Channel 2 nominal travel")
expect(
    sequence.observe(channel: 1, value: nominal, at: 13) == .enterVegas,
    "All nominal reports enter Vegas mode"
)
expect(sequence.phase == .vegas, "Vegas phase")
expect(sequence.completedChannelCount == 2, "All channels completed")

var timeoutSequence = CommissioningSequence(
    channelCount: 32,
    nominalValue: nominal,
    nominalTolerance: 32,
    stageTimeout: 8
)
_ = timeoutSequence.start(at: 20)
expect(timeoutSequence.observe(channel: 0, value: nominal, at: 21) == nil, "Timeout stage travel")
expect(timeoutSequence.tick(at: 27.99) == nil, "Commissioning waits until timeout")
expect(
    timeoutSequence.observe(channel: 0, value: HUI.maximumFaderValue, at: 28.01) == nil,
    "Position received after the stage deadline cannot advance"
)
expect(
    timeoutSequence.tick(at: 28.02) == .failed(.timedOut(channel: 0, target: .maximum)),
    "Commissioning stage timeout"
)

let wave = VegasWave(channelCount: 4)
expect((8_190...8_193).contains(wave.value(channel: 0, elapsed: 0)), "Vegas midpoint")
expect(wave.value(channel: 1, elapsed: 0) == HUI.maximumFaderValue, "Vegas crest")
expect(wave.value(channel: 3, elapsed: 0) == HUI.minimumFaderValue, "Vegas trough")

expect(DAWBankSelection.all.bankIndices == [0, 1, 2, 3], "DAW all-bank selection")
expect(DAWBankSelection.bank1.bankIndices == [0], "DAW Bank 1 selection")
expect(DAWBankSelection.bank2.bankIndices == [1], "DAW Bank 2 selection")
expect(DAWBankSelection.bank3.bankIndices == [2], "DAW Bank 3 selection")
expect(DAWBankSelection.bank4.bankIndices == [3], "DAW Bank 4 selection")

expect(DAWTakeoverProfile.genericLinear.sevenBitValue(forRawValue: 0) == 0, "Generic DAW minimum")
expect(DAWTakeoverProfile.genericLinear.sevenBitValue(forRawValue: HUI.maximumFaderValue) == 127, "Generic DAW maximum")
expect(DAWTakeoverProfile.abletonLive.sevenBitValue(forRawValue: 0) == 0, "Ableton minimum")
expect(DAWTakeoverProfile.abletonLive.sevenBitValue(forRawValue: nominal) == 108, "Ableton 0 dB anchor")
expect(DAWTakeoverProfile.abletonLive.sevenBitValue(forRawValue: HUI.maximumFaderValue) == 127, "Ableton maximum")

let dawMapping = DAWTakeoverMapping()
do {
    let firstMinimum = try dawMapping.positionMessage(
        fader: 0,
        value: HUI.minimumFaderValue
    )
    let lastMaximum = try dawMapping.positionMessage(
        fader: 31,
        value: HUI.maximumFaderValue
    )
    let firstTouch = try dawMapping.touchMessage(fader: 0, touched: true)
    let lastRelease = try dawMapping.touchMessage(fader: 31, touched: false)

    expect(
        firstMinimum == MIDIMessage([0xB0, 0x10, 0x00]),
        "DAW mapping first fader minimum"
    )
    expect(
        lastMaximum == MIDIMessage([0xB0, 0x2F, 0x7F]),
        "DAW mapping last fader maximum"
    )
    expect(
        firstTouch == MIDIMessage([0x90, 0x24, 0x7F]),
        "DAW mapping touch on"
    )
    expect(
        lastRelease == MIDIMessage([0x90, 0x43, 0x00]),
        "DAW mapping touch off"
    )
} catch {
    failures.append("Valid DAW mapping unexpectedly threw: \(error)")
}

do {
    _ = try dawMapping.positionMessage(fader: 32, value: 0)
    failures.append("Invalid DAW fader number was accepted")
} catch DAWMappingError.invalidFader(32) {
    checks += 1
} catch {
    failures.append("Invalid DAW fader returned the wrong error: \(error)")
}

let abletonMapping = DAWTakeoverMapping(profile: .abletonLive)
do {
    let nominalMessage = try abletonMapping.positionMessage(fader: 0, value: nominal)
    expect(nominalMessage.bytes == [0xB0, 0x10, 108], "Ableton mapped nominal message")
} catch {
    failures.append("Ableton nominal mapping unexpectedly threw: \(error)")
}

let clampedDAWMapping = DAWTakeoverMapping(midiChannel: 20, controllerBase: 120)
expect(clampedDAWMapping.midiChannel == 15, "DAW MIDI channel clamp")
expect(clampedDAWMapping.controllerBase == 96, "DAW controller-base clamp")

if failures.isEmpty {
    print("SwiftMixCore self-tests passed (\(checks) checks).")
} else {
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    fputs("\(failures.count) failure(s) across \(checks) completed checks.\n", stderr)
    exit(1)
}
