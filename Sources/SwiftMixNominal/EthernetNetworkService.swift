import Darwin
import Foundation
import SystemConfiguration

struct EthernetNetworkService: Identifiable, Hashable {
    let id: String
    let displayName: String
    let bsdName: String
    let isUp: Bool
    let isActive: Bool
    let ipv4Addresses: [String]
}

final class EthernetNetworkServiceMonitor {
    var onChange: (() -> Void)?

    private let preferences: SCPreferences?
    private var dynamicStore: SCDynamicStore?

    init() {
        preferences = SCPreferencesCreate(
            nil,
            "SwiftMix Nominal Lock Ethernet Services" as CFString,
            nil
        )
    }

    deinit {
        if let dynamicStore {
            SCDynamicStoreSetDispatchQueue(dynamicStore, nil)
        }
    }

    func startMonitoring() {
        guard dynamicStore == nil else { return }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "SwiftMix Nominal Lock Ethernet Monitor" as CFString,
            ethernetStoreCallback,
            &context
        ) else {
            return
        }

        let patterns = [
            "State:/Network/Interface/.*/Link",
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Service/.*/IPv4",
            "Setup:/Network/Service/.*"
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            return
        }
        dynamicStore = store
    }

    func services(synchronize: Bool = true) -> [EthernetNetworkService] {
        guard let preferences else { return [] }
        if synchronize {
            SCPreferencesSynchronize(preferences)
        }

        guard let configuredServices = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return []
        }

        let interfaceStates = Self.interfaceStates()
        let store = dynamicStore ?? SCDynamicStoreCreate(
            nil,
            "SwiftMix Nominal Lock Ethernet Snapshot" as CFString,
            nil,
            nil
        )

        return configuredServices.compactMap { service in
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let serviceInterface = SCNetworkServiceGetInterface(service),
                  let bsdName = Self.wiredEthernetBSDName(for: serviceInterface) else {
                return nil
            }

            let state = interfaceStates[bsdName] ?? InterfaceState()
            let linkActive = store.flatMap { Self.linkIsActive(bsdName: bsdName, store: $0) }
            let serviceEnabled = SCNetworkServiceGetEnabled(service)
            let isActive = serviceEnabled
                && state.isUp
                && state.isRunning
                && (linkActive ?? !state.ipv4Addresses.isEmpty)
            let displayName = (SCNetworkServiceGetName(service) as String?)
                ?? (SCNetworkInterfaceGetLocalizedDisplayName(serviceInterface) as String?)
                ?? bsdName

            return EthernetNetworkService(
                id: serviceID,
                displayName: displayName,
                bsdName: bsdName,
                isUp: state.isUp,
                isActive: isActive,
                ipv4Addresses: state.ipv4Addresses.sorted()
            )
        }
        .sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder == .orderedSame {
                return $0.id < $1.id
            }
            return nameOrder == .orderedAscending
        }
    }

    /// A focused live-link check for a previously enumerated BSD interface.
    /// This intentionally avoids `SCNetworkServiceCopyAll`; AppModel throttles
    /// it while traffic is active and uses full inventory refreshes for identity.
    func interfaceIsCurrentlyActive(bsdName: String) -> Bool {
        let state = Self.interfaceStates(matching: bsdName)[bsdName] ?? InterfaceState()
        let store = dynamicStore ?? SCDynamicStoreCreate(
            nil,
            "SwiftMix Nominal Lock Ethernet Link Check" as CFString,
            nil,
            nil
        )
        let linkActive = store.flatMap { Self.linkIsActive(bsdName: bsdName, store: $0) }
        return state.isUp
            && state.isRunning
            && (linkActive ?? !state.ipv4Addresses.isEmpty)
    }

    fileprivate func dynamicStoreChanged() {
        onChange?()
    }

    private struct InterfaceState {
        var isUp = false
        var isRunning = false
        var ipv4Addresses: Set<String> = []
    }

    private static func wiredEthernetBSDName(for interface: SCNetworkInterface) -> String? {
        var candidate: SCNetworkInterface? = interface
        while let current = candidate {
            if let interfaceType = SCNetworkInterfaceGetInterfaceType(current),
               interfaceType == kSCNetworkInterfaceTypeEthernet,
               let bsdName = SCNetworkInterfaceGetBSDName(current) as String? {
                return bsdName
            }
            candidate = SCNetworkInterfaceGetInterface(current)
        }
        return nil
    }

    private static func interfaceStates(
        matching requiredBSDName: String? = nil
    ) -> [String: InterfaceState] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return [:]
        }
        defer { freeifaddrs(firstAddress) }

        var states: [String: InterfaceState] = [:]
        var address = Optional(firstAddress)
        while let current = address {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if requiredBSDName == nil || name == requiredBSDName {
                var state = states[name] ?? InterfaceState()
                state.isUp = state.isUp || interface.ifa_flags & UInt32(IFF_UP) != 0
                state.isRunning = state.isRunning || interface.ifa_flags & UInt32(IFF_RUNNING) != 0

                if let socketAddress = interface.ifa_addr,
                   Int32(socketAddress.pointee.sa_family) == AF_INET,
                   let ipv4Address = numericHost(for: socketAddress) {
                    state.ipv4Addresses.insert(ipv4Address)
                }

                states[name] = state
            }
            address = interface.ifa_next
        }
        return states
    }

    private static func numericHost(for address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: host)
    }

    private static func linkIsActive(bsdName: String, store: SCDynamicStore) -> Bool? {
        let key = "State:/Network/Interface/\(bsdName)/Link" as CFString
        guard let state = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let active = state[kSCPropNetLinkActive as String] as? NSNumber else {
            return nil
        }
        return active.boolValue
    }
}

private func ethernetStoreCallback(
    _: SCDynamicStore,
    _: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<EthernetNetworkServiceMonitor>
        .fromOpaque(info)
        .takeUnretainedValue()
        .dynamicStoreChanged()
}
