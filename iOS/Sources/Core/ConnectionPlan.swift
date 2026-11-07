import AOSTailnet
import Foundation

/// Where one SSH attempt to the Mac goes.
enum SSHRoute: Hashable, Sendable {
    /// A name or address over Network.framework: the Mac's local addresses, or its tailnet addresses through the
    /// Tailscale app's VPN on this iPhone.
    case host(String)
    /// A tailnet address or MagicDNS name, through aOS's own Tailscale node in this app.
    case tailnet(String)
    /// The Mac's SSH server found over Bonjour (`_ssh._tcp`), by the Mac's name.
    case bonjour(String)

    var host: String {
        switch self {
        case .host(let host), .tailnet(let host), .bonjour(let host): host
        }
    }

    /// Through a tailnet (aOS's node, or the Tailscale app's VPN).
    var isTailnet: Bool {
        switch self {
        case .tailnet: true
        case .host(let host): TailnetAddress.isTailnetHost(host)
        case .bonjour: false
        }
    }
}

/// The order the iPhone tries the Mac in (Docs/COMPANION.md, "Connecting"): the same network first (the address that
/// worked last time first among them), then the tailnet (aOS's own node in this app, then the Tailscale app's VPN),
/// then Bonjour. The attempts start one after the other, a moment apart, and the first complete SSH login wins.
enum ConnectionPlan {
    static func routes(for mac: PairedMac, embeddedNode: Bool, systemVPN: Bool) -> [SSHRoute] {
        let tailnet = tailnetHosts(of: mac)
        var local = mac.hosts.filter { host in
            !TailnetAddress.isTailnetHost(host) && !tailnet.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
        }
        if let last = mac.lastHost, let index = local.firstIndex(of: last), index > 0 {
            local.remove(at: index)
            local.insert(last, at: 0)
        }
        var routes = local.map(SSHRoute.host)
        if embeddedNode { routes += tailnet.map(SSHRoute.tailnet) }
        if systemVPN { routes += tailnet.map(SSHRoute.host) }
        routes.append(.bonjour(mac.name))
        return routes
    }

    /// The Mac's node among a tailnet's devices (by its tailnet addresses and names).
    static func macNode(of mac: PairedMac, in status: TailnetStatus) -> TailnetDevice? {
        let hosts = Set(tailnetHosts(of: mac).map { $0.lowercased() })
        return status.peers.first { peer in
            peer.addresses.contains { hosts.contains($0.lowercased()) } || hosts.contains(peer.dnsName.lowercased())
        }
    }

    /// The Mac's tailnet hosts: from the pairing code, or for a Mac paired before it said so, the tailnet addresses
    /// and names among its hosts (IPv4 first).
    static func tailnetHosts(of mac: PairedMac) -> [String] {
        if let hosts = mac.tailnetHosts, !hosts.isEmpty { return hosts }
        let found = mac.hosts.filter { TailnetAddress.isTailnetHost($0) }
        return found.filter(TailnetAddress.isTailnetIPv4) + found.filter { !TailnetAddress.isTailnetIPv4($0) }
    }
}
