import Foundation

public struct MIDIMessage: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }
}

public enum HUIEncodingError: Error, Equatable {
    case invalidFader(Int)
    case invalidValue(Int)
    case invalidBankSnapshotCount(Int)
}

public enum HUI {
    public static let minimumFaderValue = 0
    public static let maximumFaderValue = 16_383

    /// Observed at the printed 0 dB mark on one fader in each SwiftMix bank.
    public static let defaultNominalValue = 12_320

    /// HUI host-to-surface keepalive. Send this regularly to every bank.
    public static let pingRequest = MIDIMessage([0x90, 0x00, 0x00])

    /// Expected surface-to-host response to `pingRequest`.
    public static let pingReply = MIDIMessage([0x90, 0x00, 0x7F])

    /// Logic-compatible channel-strip state observed at the start of the
    /// successful SwiftMix automation capture. Send once when a bank connects.
    public static let bankInitialization: [MIDIMessage] = (0..<8).flatMap { zone in
        [
            MIDIMessage([0xB0, 0x0C, UInt8(zone)]),
            MIDIMessage([0xB0, 0x2C, 0x07])
        ]
    }

    /// Encodes one bank-local fader position as the HUI MSB and LSB CC pair.
    public static func faderPosition(fader: Int, value: Int) throws -> [MIDIMessage] {
        guard (0...7).contains(fader) else {
            throw HUIEncodingError.invalidFader(fader)
        }
        guard (minimumFaderValue...maximumFaderValue).contains(value) else {
            throw HUIEncodingError.invalidValue(value)
        }

        let high = UInt8((value >> 7) & 0x7F)
        let low = UInt8(value & 0x7F)
        let localFader = UInt8(fader)

        return [
            MIDIMessage([0xB0, localFader, high]),
            MIDIMessage([0xB0, 0x20 | localFader, low])
        ]
    }

    /// Encodes all eight faders in one bank as the complete ordered HUI stream
    /// used by Logic and accepted by the SwiftMix surface.
    public static func bankSnapshot(values: [Int]) throws -> [MIDIMessage] {
        guard values.count == 8 else {
            throw HUIEncodingError.invalidBankSnapshotCount(values.count)
        }
        return try values.enumerated().flatMap { fader, value in
            try faderPosition(fader: fader, value: value)
        }
    }
}
