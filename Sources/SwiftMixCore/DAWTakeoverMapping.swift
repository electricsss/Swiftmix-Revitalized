import Foundation

public enum DAWBankSelection: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case bank1
    case bank2
    case bank3
    case bank4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All 4 Banks"
        case .bank1: return "Bank 1 · Faders 1–8"
        case .bank2: return "Bank 2 · Faders 9–16"
        case .bank3: return "Bank 3 · Faders 17–24"
        case .bank4: return "Bank 4 · Faders 25–32"
        }
    }

    public var bankIndices: [Int] {
        switch self {
        case .all: return Array(0..<4)
        case .bank1: return [0]
        case .bank2: return [1]
        case .bank3: return [2]
        case .bank4: return [3]
        }
    }
}

public enum DAWTakeoverProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case genericLinear
    case abletonLive
    case logicProHUI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .genericLinear: return "Generic Linear"
        case .abletonLive: return "Ableton Live"
        case .logicProHUI: return "Logic Pro (HUI Bridge)"
        }
    }

    public var detail: String {
        switch self {
        case .genericLinear:
            return "Linear raw 0…16383 to MIDI 0…127"
        case .abletonLive:
            return "Anchors SwiftMix 0 dB (raw 12320) to Ableton 0 dB (CC 108)"
        case .logicProHUI:
            return "Four bidirectional virtual HUI banks bridge Logic directly to native SwiftMix Ethernet"
        }
    }

    public func sevenBitValue(forRawValue value: Int) -> UInt8 {
        let raw = min(max(value, HUI.minimumFaderValue), HUI.maximumFaderValue)
        switch self {
        case .genericLinear, .logicProHUI:
            return UInt8((raw * 127 + HUI.maximumFaderValue / 2) / HUI.maximumFaderValue)
        case .abletonLive:
            let consoleNominal = HUI.defaultNominalValue
            let abletonNominal = 108
            if raw <= consoleNominal {
                return UInt8((raw * abletonNominal + consoleNominal / 2) / consoleNominal)
            }
            let upperRawRange = HUI.maximumFaderValue - consoleNominal
            let upperMIDIRange = 127 - abletonNominal
            let scaled = abletonNominal
                + ((raw - consoleNominal) * upperMIDIRange + upperRawRange / 2) / upperRawRange
            return UInt8(scaled)
        }
    }
}

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
    public let profile: DAWTakeoverProfile

    public init(
        faderCount: Int = 32,
        midiChannel: Int = 0,
        controllerBase: Int = 16,
        touchNoteBase: Int = 36,
        profile: DAWTakeoverProfile = .genericLinear
    ) {
        let safeFaderCount = min(max(faderCount, 1), 32)
        self.faderCount = safeFaderCount
        self.midiChannel = min(max(midiChannel, 0), 15)
        self.controllerBase = min(max(controllerBase, 0), 127 - safeFaderCount + 1)
        self.touchNoteBase = min(max(touchNoteBase, 0), 127 - safeFaderCount + 1)
        self.profile = profile
    }

    public func positionMessage(fader: Int, value: Int) throws -> MIDIMessage {
        guard (0..<faderCount).contains(fader) else {
            throw DAWMappingError.invalidFader(fader)
        }

        let sevenBitValue = profile.sevenBitValue(forRawValue: value)
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
