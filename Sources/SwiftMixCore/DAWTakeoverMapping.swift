import Foundation

public enum DAWMappingError: Error, Equatable, Sendable {
    case invalidFader(Int)
}

/// A conservative MIDI 1.0 mapping intended for DAW MIDI-learn workflows.
/// Thirty-two physical faders become thirty-two adjacent 7-bit CC controls;
/// touch state is emitted as Note On/Off-style velocity on adjacent notes.
public struct DAWTakeoverMapping: Equatable, Sendable {
    public let faderCount: Int
    public let midiChannel: Int
    public let controllerBase: Int
    public let touchNoteBase: Int

    public init(
        faderCount: Int = 32,
        midiChannel: Int = 0,
        controllerBase: Int = 16,
        touchNoteBase: Int = 36
    ) {
        let safeFaderCount = min(max(faderCount, 1), 32)
        self.faderCount = safeFaderCount
        self.midiChannel = min(max(midiChannel, 0), 15)
        self.controllerBase = min(max(controllerBase, 0), 127 - safeFaderCount + 1)
        self.touchNoteBase = min(max(touchNoteBase, 0), 127 - safeFaderCount + 1)
    }

    public func positionMessage(fader: Int, value: Int) throws -> MIDIMessage {
        guard (0..<faderCount).contains(fader) else {
            throw DAWMappingError.invalidFader(fader)
        }

        let clamped = min(max(value, HUI.minimumFaderValue), HUI.maximumFaderValue)
        let sevenBitValue = UInt8((clamped * 127 + HUI.maximumFaderValue / 2) / HUI.maximumFaderValue)
        return MIDIMessage([
            UInt8(0xB0 | midiChannel),
            UInt8(controllerBase + fader),
            sevenBitValue
        ])
    }

    public func touchMessage(fader: Int, touched: Bool) throws -> MIDIMessage {
        guard (0..<faderCount).contains(fader) else {
            throw DAWMappingError.invalidFader(fader)
        }

        return MIDIMessage([
            UInt8(0x90 | midiChannel),
            UInt8(touchNoteBase + fader),
            touched ? 0x7F : 0x00
        ])
    }
}
