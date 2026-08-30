import Darwin
import Foundation

public struct ResolvedIPv4Interface: Equatable, Sendable {
    public let bsdName: String
    public let index: UInt32
    public let address: IPv4Address
}

public enum IPv4InterfaceResolver {
    /// Resolves only `requiredBSDName`. It never consults routing state and never
    /// substitutes another interface or address.
    public static func resolve(requiredBSDName: String) throws -> ResolvedIPv4Interface {
        let index = if_nametoindex(requiredBSDName)
        guard index != 0 else {
            throw NativeUDPError.interfaceNotFound(requiredBSDName)
        }

        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0 else {
            throw NativeUDPError.systemCall("getifaddrs")
        }
        defer { freeifaddrs(firstAddress) }

        var foundExactInterface = false
        var isUp = false
        var supportsMulticast = false
        var addresses = Set<IPv4Address>()
        var cursor = firstAddress

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == requiredBSDName else {
                continue
            }

            foundExactInterface = true
            let flags = current.pointee.ifa_flags
            isUp = isUp || (flags & UInt32(IFF_UP)) != 0
            supportsMulticast = supportsMulticast || (flags & UInt32(IFF_MULTICAST)) != 0

            guard let socketAddress = current.pointee.ifa_addr,
                  Int32(socketAddress.pointee.sa_family) == AF_INET else {
                continue
            }

            let ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4Address(networkOrderValue: $0.pointee.sin_addr.s_addr)
            }
            if ipv4.description != "0.0.0.0" {
                addresses.insert(ipv4)
            }
        }

        guard foundExactInterface else {
            throw NativeUDPError.interfaceNotFound(requiredBSDName)
        }
        guard isUp else {
            throw NativeUDPError.interfaceIsDown(requiredBSDName)
        }
        guard supportsMulticast else {
            throw NativeUDPError.interfaceDoesNotSupportMulticast(requiredBSDName)
        }
        guard !addresses.isEmpty else {
            throw NativeUDPError.interfaceHasNoIPv4Address(requiredBSDName)
        }
        guard addresses.count == 1, let address = addresses.first else {
            throw NativeUDPError.interfaceHasMultipleIPv4Addresses(
                requiredBSDName,
                addresses.map(\.description).sorted()
            )
        }

        return ResolvedIPv4Interface(
            bsdName: requiredBSDName,
            index: index,
            address: address
        )
    }
}
