import Foundation

/// Frames a raw MIDI 1.0 byte stream into complete channel/system messages.
/// Running status and real-time bytes are handled so packet boundaries do not
/// have to align with MIDI message boundaries.
public struct MIDIMessageStreamParser: Sendable {
    private var runningStatus: UInt8?
    private var pendingData: [UInt8] = []
    private var systemStatus: UInt8?
    private var inSysEx = false

    public init() {}

    public mutating func consume(_ bytes: [UInt8]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []

        for byte in bytes {
            if byte >= 0xF8 {
                messages.append(MIDIMessage([byte]))
                continue
            }

            if inSysEx {
                if byte == 0xF7 {
                    inSysEx = false
                }
                continue
            }

            if byte & 0x80 != 0 {
                pendingData.removeAll(keepingCapacity: true)

                if byte == 0xF0 {
                    runningStatus = nil
                    systemStatus = nil
                    inSysEx = true
                } else if byte >= 0xF0 {
                    runningStatus = nil
                    systemStatus = byte
                    if expectedDataBytes(for: byte) == 0 {
                        messages.append(MIDIMessage([byte]))
                        systemStatus = nil
                    }
                } else {
                    runningStatus = byte
                    systemStatus = nil
                }
                continue
            }

            guard let status = systemStatus ?? runningStatus else {
                continue
            }

            pendingData.append(byte)
            let expected = expectedDataBytes(for: status)
            if pendingData.count == expected {
                messages.append(MIDIMessage([status] + pendingData))
                pendingData.removeAll(keepingCapacity: true)
                if status >= 0xF0 {
                    systemStatus = nil
                }
            }
        }

        return messages
    }

    private func expectedDataBytes(for status: UInt8) -> Int {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF:
            return 2
        case 0xC0...0xDF:
            return 1
        case 0xF1, 0xF3:
            return 1
        case 0xF2:
            return 2
        default:
            return 0
        }
    }
}

public enum HUIEvent: Equatable, Sendable {
    case pingReply
    case faderPosition(fader: Int, value: Int)
    case faderTouch(fader: Int, touched: Bool)
}

/// Stateful decoder for the paired HUI control-change messages used by faders.
public struct HUIFaderParser: Sendable {
    private var highBytes = Array<UInt8?>(repeating: nil, count: 8)
    private var selectedSwitchFader: Int?

    public init() {}

    public mutating func consume(_ message: MIDIMessage) -> [HUIEvent] {
        if message == HUI.pingReply {
            return [.pingReply]
        }

        guard message.bytes.count == 3, message.bytes[0] == 0xB0 else {
            return []
        }

        let controller = message.bytes[1]
        let value = message.bytes[2]

        if controller <= 0x07 {
            highBytes[Int(controller)] = value
            return []
        }

        if (0x20...0x27).contains(controller) {
            let fader = Int(controller - 0x20)
            guard let high = highBytes[fader] else {
                return []
            }
            highBytes[fader] = nil
            return [.faderPosition(fader: fader, value: (Int(high) << 7) | Int(value))]
        }

        if controller == 0x0F, value <= 0x07 {
            selectedSwitchFader = Int(value)
            return []
        }

        if controller == 0x2F, let fader = selectedSwitchFader {
            switch value {
            case 0x40:
                return [.faderTouch(fader: fader, touched: true)]
            case 0x00:
                return [.faderTouch(fader: fader, touched: false)]
            default:
                return []
            }
        }

        return []
    }
}
