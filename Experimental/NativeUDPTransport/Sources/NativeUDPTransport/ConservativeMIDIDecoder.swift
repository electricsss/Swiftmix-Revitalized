import Foundation
import SwiftMixCore

public struct ConservativelyDecodedMIDIMessage: Equatable, Sendable, CustomStringConvertible {
    public enum Interpretation: String, Equatable, Sendable {
        case pingRequest = "ping-request"
        case pingReply = "ping-reply"
        case unclassifiedMIDI = "unclassified-midi"
    }

    public let bytes: [UInt8]
    public let interpretation: Interpretation

    public var description: String {
        let bytesText = CaptureEncoding.hex(bytes)
        return "\(bytesText) [\(interpretation.rawValue)]"
    }
}

public enum ConservativeHUIEvent: Equatable, Sendable, CustomStringConvertible {
    case pingReply
    case faderPosition(fader: Int, value: Int)
    case faderTouch(fader: Int, touched: Bool)

    public var description: String {
        switch self {
        case .pingReply:
            return "ping-reply"
        case let .faderPosition(fader, value):
            return "fader-position fader=\(fader) value=\(value)"
        case let .faderTouch(fader, touched):
            return "fader-touch fader=\(fader) touched=\(touched)"
        }
    }
}

public struct ConservativeMIDIDecodeResult: Equatable, Sendable {
    public let messages: [ConservativelyDecodedMIDIMessage]
    public let events: [ConservativeHUIEvent]

    public init(
        messages: [ConservativelyDecodedMIDIMessage],
        events: [ConservativeHUIEvent]
    ) {
        self.messages = messages
        self.events = events
    }
}

/// Feeds each bank through independent root SwiftMixCore parser state. Results
/// are diagnostic labels only; they do not assert that UDP payload packing has
/// been verified for the target console.
public struct ConservativeMIDIDecoder: Sendable {
    private var streamParsers: [IPMIDIBank: MIDIMessageStreamParser] = [:]
    private var huiParsers: [IPMIDIBank: HUIFaderParser] = [:]

    public init() {}

    public mutating func decode(
        payload: [UInt8],
        bank: IPMIDIBank
    ) -> ConservativeMIDIDecodeResult {
        var streamParser = streamParsers[bank] ?? MIDIMessageStreamParser()
        let parsedMessages = streamParser.consume(payload)
        streamParsers[bank] = streamParser

        var huiParser = huiParsers[bank] ?? HUIFaderParser()
        var messages: [ConservativelyDecodedMIDIMessage] = []
        var events: [ConservativeHUIEvent] = []

        for message in parsedMessages {
            let interpretation: ConservativelyDecodedMIDIMessage.Interpretation
            if message == HUI.pingRequest {
                interpretation = .pingRequest
            } else if message == HUI.pingReply {
                interpretation = .pingReply
            } else {
                interpretation = .unclassifiedMIDI
            }
            messages.append(
                ConservativelyDecodedMIDIMessage(
                    bytes: message.bytes,
                    interpretation: interpretation
                )
            )

            for event in huiParser.consume(message) {
                switch event {
                case .pingReply:
                    events.append(.pingReply)
                case let .faderPosition(fader, value):
                    events.append(.faderPosition(fader: fader, value: value))
                case let .faderTouch(fader, touched):
                    events.append(.faderTouch(fader: fader, touched: touched))
                }
            }
        }
        huiParsers[bank] = huiParser

        return ConservativeMIDIDecodeResult(messages: messages, events: events)
    }
}
