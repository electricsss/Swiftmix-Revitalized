import Darwin
import Foundation

public struct IPv4Address: Hashable, Sendable, CustomStringConvertible {
    let networkOrderValue: UInt32

    public init(_ text: String) throws {
        var address = in_addr()
        let result = text.withCString { pointer in
            inet_pton(AF_INET, pointer, &address)
        }
        guard result == 1 else {
            throw NativeUDPError.invalidIPv4Address(text)
        }
        self.networkOrderValue = address.s_addr
    }

    init(networkOrderValue: UInt32) {
        self.networkOrderValue = networkOrderValue
    }

    var inAddress: in_addr {
        in_addr(s_addr: networkOrderValue)
    }

    public var isMulticast: Bool {
        let hostOrder = UInt32(bigEndian: networkOrderValue)
        return (hostOrder & 0xF000_0000) == 0xE000_0000
    }

    public var description: String {
        var address = inAddress
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = buffer.withUnsafeMutableBufferPointer { output in
            withUnsafePointer(to: &address) { input in
                inet_ntop(AF_INET, input, output.baseAddress, socklen_t(INET_ADDRSTRLEN))
            }
        }
        guard converted != nil else {
            return "<invalid-ipv4>"
        }
        return String(cString: buffer)
    }
}

public enum IPMIDIBank: Int, CaseIterable, Hashable, Sendable, Codable, CustomStringConvertible {
    case bank1 = 1
    case bank2 = 2
    case bank3 = 3
    case bank4 = 4

    public init(number: Int) throws {
        guard let bank = Self(rawValue: number) else {
            throw NativeUDPError.invalidBank(number)
        }
        self = bank
    }

    public var description: String {
        "bank \(rawValue)"
    }
}

public enum ProvisionalPayloadPacking: String, Sendable, Codable {
    case unverifiedRawMIDIBytesPerDatagram
}

public enum AssumptionVerificationState: String, Sendable, Codable {
    case unverifiedAgainstTargetConsoleAndTrialDriver
}

public struct ProvisionalWireAssumption<Value: Sendable>: Sendable {
    public let identifier: String
    public let value: Value
    public let verificationState: AssumptionVerificationState
    public let evidence: String

    init(identifier: String, value: Value, evidence: String) {
        self.identifier = identifier
        self.value = value
        self.verificationState = .unverifiedAgainstTargetConsoleAndTrialDriver
        self.evidence = evidence
    }
}

/// Every field in this profile is provisional until checked against a packet
/// capture from the target console and trial ipMIDI driver.
public struct ProvisionalIPMIDIWireProfile: Sendable {
    public static let arduinoEvidenceURL = "https://raw.githubusercontent.com/djbottrill/IPMidi_example/master/IPMidi_Multicast_Example.ino"
    public static let sslEvidenceURL = "https://livehelp.solidstatelogic.com/Help/ipMIDI.html"
    public static let nerdsEvidenceURL = "https://www.nerds.de/en/ipmidi.html"

    public let multicastGroup: ProvisionalWireAssumption<IPv4Address>
    public let baseUDPPort: ProvisionalWireAssumption<UInt16>
    public let logicalBankCount: ProvisionalWireAssumption<Int>
    public let bankPortMapping: ProvisionalWireAssumption<String>
    public let payloadPacking: ProvisionalWireAssumption<ProvisionalPayloadPacking>
    public let multicastTTL: ProvisionalWireAssumption<UInt8>
    public let localMulticastLoopback: ProvisionalWireAssumption<Bool>

    public init(
        multicastGroup: IPv4Address,
        baseUDPPort: UInt16,
        logicalBankCount: Int = 4,
        payloadPacking: ProvisionalPayloadPacking = .unverifiedRawMIDIBytesPerDatagram,
        multicastTTL: UInt8 = 1,
        localMulticastLoopback: Bool = false
    ) throws {
        guard multicastGroup.isMulticast else {
            throw NativeUDPError.multicastAddressRequired(multicastGroup.description)
        }
        guard logicalBankCount == IPMIDIBank.allCases.count else {
            throw NativeUDPError.unsupportedLogicalBankCount(logicalBankCount)
        }
        guard Int(baseUDPPort) + logicalBankCount - 1 <= Int(UInt16.max) else {
            throw NativeUDPError.invalidBasePort(baseUDPPort, bankCount: logicalBankCount)
        }
        guard multicastTTL > 0 else {
            throw NativeUDPError.invalidMulticastTTL(multicastTTL)
        }

        self.multicastGroup = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_MULTICAST_GROUP",
            value: multicastGroup,
            evidence: Self.arduinoEvidenceURL + " and " + Self.sslEvidenceURL
        )
        self.baseUDPPort = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_BASE_UDP_PORT",
            value: baseUDPPort,
            evidence: Self.arduinoEvidenceURL
        )
        self.logicalBankCount = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_LOGICAL_BANK_COUNT",
            value: logicalBankCount,
            evidence: "Current four-bank console integration hypothesis"
        )
        self.bankPortMapping = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_BANK_TO_PORT_RULE",
            value: "bank N maps to base UDP port + (N - 1)",
            evidence: Self.arduinoEvidenceURL + " plus current four-bank hypothesis"
        )
        self.payloadPacking = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_PAYLOAD_PACKING",
            value: payloadPacking,
            evidence: Self.arduinoEvidenceURL
        )
        self.multicastTTL = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_SEND_TTL",
            value: multicastTTL,
            evidence: "Conservative link-local send default; capture verification required"
        )
        self.localMulticastLoopback = ProvisionalWireAssumption(
            identifier: "UNVERIFIED_LOCAL_MULTICAST_LOOPBACK",
            value: localMulticastLoopback,
            evidence: Self.sslEvidenceURL
        )
    }

    public static var unverifiedIPMIDIDefaults: ProvisionalIPMIDIWireProfile {
        // These literals are validated by construction and remain explicitly
        // marked unverified in each ProvisionalWireAssumption.
        try! ProvisionalIPMIDIWireProfile(
            multicastGroup: IPv4Address("225.0.0.37"),
            baseUDPPort: 21_928,
            logicalBankCount: 4,
            payloadPacking: .unverifiedRawMIDIBytesPerDatagram,
            multicastTTL: 1,
            localMulticastLoopback: false
        )
    }

    public func port(for bank: IPMIDIBank) -> UInt16 {
        UInt16(Int(baseUDPPort.value) + bank.rawValue - 1)
    }
}
