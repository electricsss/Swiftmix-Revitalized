import Darwin
import Foundation

public enum ReceiveAuthorization: Equatable, Sendable {
    case disabled
    case receiveOnly
}

public struct ProtocolVerification: Equatable, Sendable {
    public let captureIdentifier: String
    public let protocolRevision: String

    public init(captureIdentifier: String, protocolRevision: String) throws {
        guard !captureIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeUDPError.invalidVerificationIdentifier(field: "capture identifier")
        }
        guard !protocolRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeUDPError.invalidVerificationIdentifier(field: "protocol revision")
        }
        self.captureIdentifier = captureIdentifier
        self.protocolRevision = protocolRevision
    }
}

public enum TransmissionAuthorization: Equatable, Sendable {
    case denied
    case verified(ProtocolVerification)
}

public enum TransmissionPolicy {
    @discardableResult
    public static func requireVerified(
        _ authorization: TransmissionAuthorization
    ) throws -> ProtocolVerification {
        guard case let .verified(verification) = authorization else {
            throw NativeUDPError.transmissionNotAuthorized
        }
        return verification
    }
}

public struct NativeUDPConfiguration: Sendable {
    public static let maximumUDPPayloadSize = 65_507

    public let interfaceBSDName: String
    public let banks: [IPMIDIBank]
    public let maximumPacketSize: Int
    public let wireProfile: ProvisionalIPMIDIWireProfile

    public init(
        interfaceBSDName: String,
        banks: [IPMIDIBank] = IPMIDIBank.allCases,
        maximumPacketSize: Int = NativeUDPConfiguration.maximumUDPPayloadSize,
        wireProfile: ProvisionalIPMIDIWireProfile = .unverifiedIPMIDIDefaults
    ) throws {
        let nameLength = interfaceBSDName.utf8.count
        guard !interfaceBSDName.isEmpty,
              !interfaceBSDName.utf8.contains(0),
              nameLength < Int(IFNAMSIZ) else {
            throw NativeUDPError.invalidBSDInterfaceName(interfaceBSDName)
        }
        guard !banks.isEmpty else {
            throw NativeUDPError.noBanksSelected
        }

        var seen = Set<IPMIDIBank>()
        for bank in banks {
            guard seen.insert(bank).inserted else {
                throw NativeUDPError.duplicateBank(bank.rawValue)
            }
        }
        guard (1...Self.maximumUDPPayloadSize).contains(maximumPacketSize) else {
            throw NativeUDPError.invalidMaximumPacketSize(maximumPacketSize)
        }

        self.interfaceBSDName = interfaceBSDName
        self.banks = banks.sorted { $0.rawValue < $1.rawValue }
        self.maximumPacketSize = maximumPacketSize
        self.wireProfile = wireProfile
    }
}
