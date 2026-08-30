import Foundation

public struct IPv4Endpoint: Equatable, Sendable {
    public let address: IPv4Address
    public let port: UInt16

    public init(address: IPv4Address, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public struct ReceivedUDPPacket: Equatable, Sendable {
    public let timestamp: Date
    public let bank: IPMIDIBank
    public let localDestinationPort: UInt16
    public let source: IPv4Endpoint
    public let payload: [UInt8]

    public init(
        timestamp: Date,
        bank: IPMIDIBank,
        localDestinationPort: UInt16,
        source: IPv4Endpoint,
        payload: [UInt8]
    ) {
        self.timestamp = timestamp
        self.bank = bank
        self.localDestinationPort = localDestinationPort
        self.source = source
        self.payload = payload
    }
}

public enum NativeUDPReceiveEvent: Equatable, Sendable {
    case packet(ReceivedUDPPacket)
    case failure(NativeUDPError)
}

private struct JSONLCaptureRecord: Encodable {
    let bank: Int
    let byteCount: Int
    let decodedMIDI: [String]
    let decodedHUI: [String]
    let localDestinationPort: UInt16
    let payloadHex: String
    let sourceAddress: String
    let sourcePort: UInt16
    let timestamp: String
}

public enum CaptureEncoding {
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    public static func jsonLine(
        packet: ReceivedUDPPacket,
        decoded: ConservativeMIDIDecodeResult
    ) throws -> String {
        let record = JSONLCaptureRecord(
            bank: packet.bank.rawValue,
            byteCount: packet.payload.count,
            decodedMIDI: decoded.messages.map(\.description),
            decodedHUI: decoded.events.map(\.description),
            localDestinationPort: packet.localDestinationPort,
            payloadHex: hex(packet.payload),
            sourceAddress: packet.source.address.description,
            sourcePort: packet.source.port,
            timestamp: timestamp(packet.timestamp)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
            throw NativeUDPError.captureEncodingFailed
        }
        return line
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
