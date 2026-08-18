import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// What kind of link an IP address is reachable over. Drives the icon and the
/// label shown next to each address, and the order they are listed in.
public enum NetworkInterfaceKind: String, Sendable, CaseIterable {
    case wifi
    case ethernet
    case tailscale
    case vpn
    case virtualNetwork
    case loopback
    case other

    /// Fallback label used when the system has no localized name for the interface.
    public var defaultLabel: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .tailscale: return "Tailscale"
        case .vpn: return "VPN"
        case .virtualNetwork: return "Virtual"
        case .loopback: return "Local"
        case .other: return "Network"
        }
    }

    /// SF Symbol shown beside the address.
    public var symbolName: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .vpn: return "lock.shield"
        case .virtualNetwork: return "square.stack.3d.up"
        case .loopback: return "house"
        case .other: return "network"
        }
    }

    /// Listing order — the addresses a developer shares most come first.
    public var sortRank: Int {
        switch self {
        case .wifi: return 0
        case .ethernet: return 1
        case .tailscale: return 2
        case .vpn: return 3
        case .other: return 4
        case .virtualNetwork: return 5
        case .loopback: return 6
        }
    }
}

/// One IP address the machine is reachable at, together with the link it belongs to.
public struct NetworkAddress: Identifiable, Equatable, Hashable, Sendable {
    /// BSD interface name — `en0`, `utun4`, …
    public let interface: String
    /// The IP address itself, e.g. `192.168.0.189`.
    public let ip: String
    public let kind: NetworkInterfaceKind
    /// Human label: the system's localized interface name ("Wi-Fi") when known,
    /// otherwise the kind's default ("Tailscale").
    public let label: String

    public var id: String { "\(interface)-\(ip)" }

    public init(interface: String, ip: String, kind: NetworkInterfaceKind, label: String) {
        self.interface = interface
        self.ip = ip
        self.kind = kind
        self.label = label
    }

    /// A URL for reaching a given port at this address.
    public func urlString(port: Int) -> String { "http://\(ip):\(port)" }
}

/// An address straight out of `getifaddrs`, before classification. Split out so
/// the (pure) classification rules can be unit tested without touching the system.
public struct RawInterfaceAddress: Equatable, Sendable {
    public let interface: String
    public let ip: String
    public let isLoopback: Bool

    public init(interface: String, ip: String, isLoopback: Bool = false) {
        self.interface = interface
        self.ip = ip
        self.isLoopback = isLoopback
    }
}

/// Turns raw interface/IP pairs into labelled ``NetworkAddress`` values.
///
/// Pure by design: every system-dependent input (the localized interface names
/// and hardware types macOS reports) is passed in, so the rules below are fully
/// testable.
public enum NetworkInterfaceClassifier {

    /// Hardware hint from SystemConfiguration, when macOS can supply one.
    public enum HardwareType: Sendable { case wifi, ethernet }

    /// Interfaces that never carry an address worth showing: AirDrop, Apple
    /// Wireless Direct, the internal management links, and the tunnel stubs.
    static let ignoredInterfaces: Set<String> = ["awdl0", "llw0", "gif0", "stf0"]
    static let ignoredPrefixes = ["anpi", "ap"]

    /// Classify one address.
    public static func kind(
        interface: String,
        ip: String,
        isLoopback: Bool = false,
        hardware: HardwareType? = nil
    ) -> NetworkInterfaceKind {
        if isLoopback || interface == "lo0" { return .loopback }
        // Tailscale hands out addresses from the CGNAT range 100.64.0.0/10 on a
        // plain `utun` device, so the address — not the name — is what identifies it.
        if isTailscaleAddress(ip) || interface.hasPrefix("tailscale") { return .tailscale }
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") {
            return .vpn
        }
        if let hardware {
            return hardware == .wifi ? .wifi : .ethernet
        }
        for prefix in ["bridge", "vmenet", "docker", "vboxnet", "tap", "veth"] where interface.hasPrefix(prefix) {
            return .virtualNetwork
        }
        if interface.hasPrefix("en") { return .ethernet }
        return .other
    }

    /// `true` for an IPv4 address inside Tailscale's 100.64.0.0/10 range.
    public static func isTailscaleAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// Build the display list: drop the noise, label what's left, and sort it so
    /// the addresses you'd actually hand to a phone or a colleague come first.
    ///
    /// - Parameters:
    ///   - raw: addresses as reported by the system.
    ///   - displayNames: BSD name → localized name (`en0` → `Wi-Fi`), when known.
    ///   - hardwareTypes: BSD name → hardware kind, when known.
    ///   - includeLoopback: keep `127.0.0.1`. Off by default — the ports list
    ///     already offers `localhost`.
    public static func addresses(
        from raw: [RawInterfaceAddress],
        displayNames: [String: String] = [:],
        hardwareTypes: [String: HardwareType] = [:],
        includeLoopback: Bool = false
    ) -> [NetworkAddress] {
        var seen = Set<String>()
        var result: [NetworkAddress] = []

        for entry in raw {
            guard !isIgnored(entry.interface), !isIgnored(ip: entry.ip) else { continue }
            let kind = kind(
                interface: entry.interface,
                ip: entry.ip,
                isLoopback: entry.isLoopback,
                hardware: hardwareTypes[entry.interface]
            )
            guard includeLoopback || kind != .loopback else { continue }
            // The same address can appear on several aliases; show it once.
            guard seen.insert("\(entry.interface)-\(entry.ip)").inserted else { continue }

            result.append(
                NetworkAddress(
                    interface: entry.interface,
                    ip: entry.ip,
                    kind: kind,
                    // A localized name is only meaningful for real hardware; a
                    // `utun` device is named "utun4" by the system, which tells
                    // nobody anything — "Tailscale" does.
                    label: preferredLabel(kind: kind, systemName: displayNames[entry.interface])
                )
            )
        }

        return result.sorted {
            $0.kind.sortRank != $1.kind.sortRank
                ? $0.kind.sortRank < $1.kind.sortRank
                : $0.interface.localizedStandardCompare($1.interface) == .orderedAscending
        }
    }

    private static func preferredLabel(kind: NetworkInterfaceKind, systemName: String?) -> String {
        switch kind {
        case .wifi, .ethernet, .virtualNetwork, .other:
            if let systemName, !systemName.isEmpty { return systemName }
            return kind.defaultLabel
        case .tailscale, .vpn, .loopback:
            return kind.defaultLabel
        }
    }

    private static func isIgnored(_ interface: String) -> Bool {
        if ignoredInterfaces.contains(interface) { return true }
        return ignoredPrefixes.contains { prefix in
            guard interface.hasPrefix(prefix) else { return false }
            // Only `anpi0`/`ap1`-style names — never a real `en0`.
            return interface.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
    }

    /// Link-local addresses (IPv4 `169.254.x.x`, IPv6 `fe80::`) mean "no network
    /// here" — never reachable from another machine.
    private static func isIgnored(ip: String) -> Bool {
        ip.hasPrefix("169.254.") || ip.lowercased().hasPrefix("fe80:")
    }
}

/// Reads the machine's current IPv4 addresses from the system.
public struct NetworkInterfaceScanner: Sendable {
    public init() {}

    /// Every reachable IPv4 address, labelled and sorted.
    public func scan(includeLoopback: Bool = false) -> [NetworkAddress] {
        NetworkInterfaceClassifier.addresses(
            from: rawAddresses(),
            displayNames: systemDisplayNames(),
            hardwareTypes: systemHardwareTypes(),
            includeLoopback: includeLoopback
        )
    }

    /// Scan off the main thread. Convenient for SwiftUI view models.
    public func scanAsync(includeLoopback: Bool = false) async -> [NetworkAddress] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.scan(includeLoopback: includeLoopback))
            }
        }
    }

    // MARK: - System reads

    /// Walk `getifaddrs` for IPv4 addresses on interfaces that are up.
    func rawAddresses() -> [RawInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [RawInterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            result.append(
                RawInterfaceAddress(
                    interface: String(cString: pointer.pointee.ifa_name),
                    ip: String(cString: host),
                    isLoopback: flags & IFF_LOOPBACK == IFF_LOOPBACK
                )
            )
        }
        return result
    }

    /// `en0` → `Wi-Fi`, as macOS names it in Network settings.
    func systemDisplayNames() -> [String: String] {
        #if canImport(SystemConfiguration)
        var names: [String: String] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = name
        }
        return names
        #else
        return [:]
        #endif
    }

    /// Whether each interface is Wi-Fi or wired, straight from the system, so we
    /// don't have to guess that `en0` means Wi-Fi (on a Mac mini it doesn't).
    func systemHardwareTypes() -> [String: NetworkInterfaceClassifier.HardwareType] {
        #if canImport(SystemConfiguration)
        var types: [String: NetworkInterfaceClassifier.HardwareType] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            // These constants are `CFString`; bridge back for the comparison.
            switch type as CFString {
            case kSCNetworkInterfaceTypeIEEE80211:
                types[bsd] = .wifi
            case kSCNetworkInterfaceTypeEthernet:
                types[bsd] = .ethernet
            default:
                continue
            }
        }
        return types
        #else
        return [:]
        #endif
    }
}
