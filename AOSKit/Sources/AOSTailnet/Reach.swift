import Darwin
import Foundation

/// How the iPhone reaches the Mac away from the home network (the setup's choice, Settings > Connection on the Mac;
/// Docs/DESIGN.md, "Reaching the Mac on the go"). The phone always tries the same network first.
public enum ReachWay: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The person's own Tailscale app on the Mac and on the iPhone: aOS only reads the Mac's tailnet address and
    /// never changes the app's settings.
    case tailscaleApp = "app"
    /// aOS's own Tailscale node on the Mac (started by aOS's helper) and in aOS on the iPhone: no VPN, no extra app.
    case aosTailscale = "aos"
    /// Only on the same network (SSH to the Mac's local addresses, as before).
    case localNetwork = "lan"

    public var id: String { rawValue }
}

/// What aOS sees of the Tailscale app on this Mac.
public enum TailscaleAppState: Equatable, Sendable {
    /// Neither the app nor a `tailscale` command line tool is there.
    case notInstalled
    /// Installed, but not connected: not running, or its state (NeedsLogin, Stopped, ...).
    case notConnected(String?)
    /// Running and signed in.
    case connected(TailnetStatus)

    public var status: TailnetStatus? {
        if case .connected(let status) = self { return status }
        return nil
    }
}

public enum ReachAdvisor {
    /// The setup recommends the person's Tailscale app when it runs on this Mac and is connected, and otherwise
    /// aOS's own Tailscale. Only on the same network is never recommended (it's the fallback).
    public static func recommended(for app: TailscaleAppState) -> ReachWay {
        if case .connected = app { return .tailscaleApp }
        return .aosTailscale
    }
}

/// The tailnet part of the pairing link (Docs/COMPANION.md, "Pairing"): `w` the way, `t` the Mac's tailnet hosts,
/// `tn` the tailnet's name.
public struct PairingReach: Equatable, Sendable {
    public var way: ReachWay
    /// The Mac's tailnet addresses and name: its IPv4 address first (works without MagicDNS), then its MagicDNS name.
    public var tailnetHosts: [String]
    public var tailnetName: String?

    public init(way: ReachWay, tailnetHosts: [String] = [], tailnetName: String? = nil) {
        self.way = way
        self.tailnetHosts = tailnetHosts
        self.tailnetName = tailnetName
    }

    /// The reach for a way and the tailnet node that carries it (the Tailscale app's or aOS's own).
    public init(way: ReachWay, node: TailnetStatus?) {
        self.way = way
        guard way != .localNetwork, let node, node.isRunning, let device = node.device else {
            tailnetHosts = []
            tailnetName = nil
            return
        }
        var hosts: [String] = []
        if let v4 = device.ipv4 { hosts.append(v4) }
        if !device.dnsName.isEmpty { hosts.append(device.dnsName) }
        tailnetHosts = hosts
        tailnetName = node.tailnet
    }

    /// The hosts of the link (`h`): the local ones first, the tailnet hosts after them (once each). Phones that
    /// don't know `t` still try them, which works for them with the Tailscale app.
    public func linkHosts(local: [String]) -> [String] {
        var seen = Set<String>()
        return (local.filter { !tailnetHosts.contains($0) } + tailnetHosts).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// The names aOS's own nodes register with.
public enum TailnetNames {
    /// "aos-" and the device's name in lowercase letters and digits, everything else as one hyphen, at most 63
    /// characters ("Maxs-MacBook-Pro" -> "aos-maxs-macbook-pro", "Max’s iPhone" -> "aos-max-s-iphone").
    public static func hostname(device name: String, fallback: String) -> String {
        var label = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                label.unicodeScalars.append(scalar)
            } else if !label.isEmpty && !label.hasSuffix("-") {
                label += "-"
            }
        }
        while label.hasSuffix("-") { label.removeLast() }
        if label.isEmpty { label = fallback }
        var result = "aos-" + label
        if result.utf8.count > 63 { result = String(result.prefix(63)) }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}

/// Tailscale's address ranges.
public enum TailnetAddress {
    /// 100.64.0.0/10 (the shared address space Tailscale takes its IPv4 addresses from).
    public static func isTailnetIPv4(_ text: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return value & 0xFFC0_0000 == 0x6440_0000
    }

    /// fd7a:115c:a1e0::/48 (Tailscale's IPv6 range).
    public static func isTailnetIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        let bare = text.split(separator: "%").first.map(String.init) ?? text
        guard inet_pton(AF_INET6, bare, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return bytes.prefix(6) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    /// A tailnet address, or a MagicDNS name (under ts.net or the tailnet's own suffix).
    public static func isTailnetHost(_ host: String, suffix: String? = nil) -> Bool {
        let lower = host.lowercased()
        if isTailnetIPv4(lower) || isTailnetIPv6(lower) { return true }
        if lower.hasSuffix(".ts.net") { return true }
        if let suffix, !suffix.isEmpty, lower.hasSuffix("." + suffix.lowercased()) { return true }
        return false
    }
}

/// Whether a Tailscale VPN (the Tailscale app's) is active on this device: a utun interface with an address in
/// Tailscale's ranges.
public enum TailnetVPN {
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var address: String
        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public static func isActive(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { i in
            i.name.hasPrefix("utun") && (TailnetAddress.isTailnetIPv4(i.address) || TailnetAddress.isTailnetIPv6(i.address))
        }
    }

    public static var isActive: Bool { isActive(interfaces()) }

    /// The addresses of the interfaces that are up.
    public static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            result.append(Interface(name: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
        }
        return result
    }
}
