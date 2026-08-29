import Darwin
import SwiftMixCore

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

do {
    let encoded = try HUI.faderPosition(fader: 3, value: 13_168)
    expect(
        encoded == [
            MIDIMessage([0xB0, 0x03, 0x66]),
            MIDIMessage([0xB0, 0x23, 0x70])
        ],
        "Nominal fader encoding"
    )
} catch {
    failures.append("Nominal fader encoding unexpectedly threw: \(error)")
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
expect(huiParser.consume(MIDIMessage([0xB0, 0x03, 0x66])).isEmpty, "Fader MSB waits for LSB")
expect(
    huiParser.consume(MIDIMessage([0xB0, 0x23, 0x70]))
        == [.faderPosition(fader: 3, value: 13_168)],
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
    streamParser.consume([0x66, 0x21, 0x70])
        == [MIDIMessage([0xB0, 0x01, 0x66]), MIDIMessage([0xB0, 0x21, 0x70])],
    "Packet split and running-status decoding"
)

let policy = NominalLockPolicy(nominalValue: 13_168, tolerance: 32)
expect(!policy.shouldRestore(observedValue: 13_136), "Lower tolerance boundary")
expect(!policy.shouldRestore(observedValue: 13_200), "Upper tolerance boundary")
expect(policy.shouldRestore(observedValue: 13_135), "Below lower tolerance boundary")
expect(policy.shouldRestore(observedValue: 13_201), "Above upper tolerance boundary")
expect(policy.restoreValue(observedValue: 10_000, lockIsArmed: false) == nil, "Disabled lock does not restore")
expect(policy.restoreValue(observedValue: 10_000, lockIsArmed: true) == 13_168, "Armed lock restores nominal")
expect(NominalLockPolicy(nominalValue: -1, tolerance: -10).nominalValue == 0, "Minimum value clamp")
expect(NominalLockPolicy(nominalValue: 20_000).nominalValue == 16_383, "Maximum value clamp")
expect(NominalLockPolicy(tolerance: -10).tolerance == 0, "Tolerance clamp")

var sequence = CommissioningSequence(
    channelCount: 2,
    nominalValue: 13_168,
    nominalTolerance: 32,
    stageTimeout: 8
)
expect(
    sequence.start(at: 10) == .send(channel: 0, value: HUI.maximumFaderValue),
    "Commissioning starts channel 1 at maximum"
)
expect(
    sequence.observe(channel: 0, value: 13_168, at: 10) == nil,
    "Report received with the command cannot count as stage travel"
)
expect(
    sequence.observe(channel: 0, value: HUI.maximumFaderValue, at: 10.01) == nil,
    "Immediate target report does not prove movement"
)
expect(
    sequence.observe(channel: 0, value: 13_168, at: 10.1) == nil,
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
        == .send(channel: 0, value: 13_168),
    "Minimum report advances the same channel to nominal"
)
expect(sequence.observe(channel: 0, value: 100, at: 11.1) == nil, "Nominal stage travel")
expect(
    sequence.observe(channel: 0, value: 13_168, at: 11.5)
        == .send(channel: 1, value: HUI.maximumFaderValue),
    "Nominal report advances to the next channel"
)
expect(sequence.completedChannelCount == 1, "Completed channel count")
expect(sequence.observe(channel: 1, value: 13_168, at: 11.6) == nil, "Channel 2 maximum travel")
expect(
    sequence.observe(channel: 1, value: HUI.maximumFaderValue, at: 12)
        == .send(channel: 1, value: HUI.minimumFaderValue),
    "Channel 2 maximum"
)
expect(sequence.observe(channel: 1, value: 10_000, at: 12.1) == nil, "Channel 2 minimum travel")
expect(
    sequence.observe(channel: 1, value: HUI.minimumFaderValue, at: 12.5)
        == .send(channel: 1, value: 13_168),
    "Channel 2 minimum"
)
expect(sequence.observe(channel: 1, value: 1_000, at: 12.6) == nil, "Channel 2 nominal travel")
expect(
    sequence.observe(channel: 1, value: 13_168, at: 13) == .enterVegas,
    "All nominal reports enter Vegas mode"
)
expect(sequence.phase == .vegas, "Vegas phase")
expect(sequence.completedChannelCount == 2, "All channels completed")

var timeoutSequence = CommissioningSequence(
    channelCount: 32,
    nominalValue: 13_168,
    nominalTolerance: 32,
    stageTimeout: 8
)
_ = timeoutSequence.start(at: 20)
expect(timeoutSequence.observe(channel: 0, value: 13_168, at: 21) == nil, "Timeout stage travel")
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
