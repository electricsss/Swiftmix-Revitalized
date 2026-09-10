import Darwin
import Foundation

public enum NativeUDPError: Error, Equatable, Sendable {
    case invalidIPv4Address(String)
    case multicastAddressRequired(String)
    case invalidBasePort(UInt16, bankCount: Int)
    case unsupportedLogicalBankCount(Int)
    case invalidMulticastTTL(UInt8)
    case invalidBSDInterfaceName(String)
    case interfaceNotFound(String)
    case interfaceIsDown(String)
    case interfaceDoesNotSupportMulticast(String)
    case interfaceHasNoIPv4Address(String)
    case interfaceHasMultipleIPv4Addresses(String, [String])
    case invalidBank(Int)
    case noBanksSelected
    case duplicateBank(Int)
    case invalidMaximumPacketSize(Int)
    case invalidVerificationIdentifier(field: String)
    case receptionNotAuthorized
    case transmissionNotAuthorized
    case transportNotRunning
    case bankSocketNotRunning(Int)
    case emptyPayload
    case payloadTooLarge(actual: Int, maximum: Int)
    case receivedPacketTooLarge(bank: Int, maximum: Int)
    case unexpectedSourceAddressFamily(Int32)
    case systemCallFailed(operation: String, code: Int32, message: String)
    case captureEncodingFailed
}

extension NativeUDPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidIPv4Address(value):
            return "Invalid IPv4 address: \(value)"
        case let .multicastAddressRequired(value):
            return "IPv4 multicast address required, got: \(value)"
        case let .invalidBasePort(port, bankCount):
            return "Base UDP port \(port) cannot represent \(bankCount) banks"
        case let .unsupportedLogicalBankCount(count):
            return "Exactly four provisional logical banks are supported, got \(count)"
        case let .invalidMulticastTTL(ttl):
            return "Multicast TTL must be at least 1, got \(ttl)"
        case let .invalidBSDInterfaceName(name):
            return "Invalid BSD interface name: \(name)"
        case let .interfaceNotFound(name):
            return "Required BSD interface was not found: \(name)"
        case let .interfaceIsDown(name):
            return "Required BSD interface is down: \(name)"
        case let .interfaceDoesNotSupportMulticast(name):
            return "Required BSD interface does not report multicast capability: \(name)"
        case let .interfaceHasNoIPv4Address(name):
            return "Required BSD interface has no IPv4 address: \(name)"
        case let .interfaceHasMultipleIPv4Addresses(name, addresses):
            return "Required BSD interface \(name) has multiple IPv4 addresses; refusing to guess: \(addresses.joined(separator: ", "))"
        case let .invalidBank(number):
            return "Logical bank must be in 1...4, got \(number)"
        case .noBanksSelected:
            return "At least one logical bank must be selected"
        case let .duplicateBank(number):
            return "Logical bank \(number) was selected more than once"
        case let .invalidMaximumPacketSize(size):
            return "Maximum packet size must be in 1...65507, got \(size)"
        case let .invalidVerificationIdentifier(field):
            return "Transmission verification requires a non-empty \(field)"
        case .receptionNotAuthorized:
            return "Reception is disabled by receive authorization policy"
        case .transmissionNotAuthorized:
            return "UDP transmission is not authorized; provide an explicit verified capture/protocol revision authorization"
        case .transportNotRunning:
            return "UDP transport is not running"
        case let .bankSocketNotRunning(bank):
            return "No running UDP socket exists for logical bank \(bank)"
        case .emptyPayload:
            return "A UDP MIDI payload cannot be empty"
        case let .payloadTooLarge(actual, maximum):
            return "UDP payload is \(actual) bytes; configured maximum is \(maximum)"
        case let .receivedPacketTooLarge(bank, maximum):
            return "Dropped oversized datagram on logical bank \(bank); configured maximum is \(maximum) bytes"
        case let .unexpectedSourceAddressFamily(family):
            return "Received datagram from unexpected address family \(family)"
        case let .systemCallFailed(operation, code, message):
            return "\(operation) failed with errno \(code): \(message)"
        case .captureEncodingFailed:
            return "Could not encode a JSONL capture record"
        }
    }

    static func systemCall(_ operation: String, code: Int32 = errno) -> NativeUDPError {
        .systemCallFailed(
            operation: operation,
            code: code,
            message: String(cString: strerror(code))
        )
    }
}
