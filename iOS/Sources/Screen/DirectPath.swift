import AOSTailnet
import Foundation
import Network
import ScreenClient

/// The direct path to the Mac's screen sharing, for Open Screen Sharing's high performance and its virtual display.
///
/// High performance sends the picture as video over UDP, to and from the address the screen sharing TCP connection
/// reached (libsharing, `internal/rfb/mediastream.go`). Through the SSH tunnel that would be 127.0.0.1, and SSH
/// carries TCP only; so it needs the Mac's own address, reachable by this iPhone's own network stack: the address the
/// SSH connection reached in the same network, or the Mac's tailnet address with the Tailscale app's VPN on. aOS's own
/// Tailscale node in the app carries only the app's SSH connection (it hands over connected sockets), so it is no way
/// for libsharing's TCP and UDP. Ports and protocols: iOS/NOTES.md.
enum DirectPath {
    /// Screen sharing on the Mac (TCP); the media ports the Mac announces in the session.
    static let screenSharingPort = 5900

    /// Where to try the Mac directly, or why not.
    enum Candidate: Equatable, Sendable {
        case address(String)
        /// The SSH connection doesn't reach an address in a network (a relay on this iPhone, for example).
        case noAddress
        /// SSH goes through aOS's own Tailscale node and the Tailscale app's VPN is off.
        case tailnetWithoutVPN
    }

    /// The candidate for an SSH connection that went `route`, reached `remote` (its IP, if known); the Mac's tailnet
    /// hosts (IPv4 first) and whether the Tailscale app's VPN is on.
    static func candidate(route: SSHRoute, remote: String?, tailnetHosts: [String], systemVPN: Bool) -> Candidate {
        switch route {
        case .tailnet(let host):
            guard systemVPN else { return .tailnetWithoutVPN }
            return .address(tailnetHosts.first(where: TailnetAddress.isTailnetIPv4) ?? host)
        case .host(let host):
            if let remote, !remote.isEmpty, !isLoopback(remote) { return .address(remote) }
            return isLoopback(host) ? .noAddress : .address(host)
        case .bonjour:
            if let remote, !remote.isEmpty, !isLoopback(remote) { return .address(remote) }
            return .noAddress
        }
    }

    /// Open Screen Sharing's network quality for the path: the tailnet counts as the internet (one band, 4:2:0,
    /// Open Screen Sharing's tuning for Tailscale), everything else as the local network.
    static func network(for host: String) -> ScreenNetwork {
        TailnetAddress.isTailnetHost(host) ? .internet : .localNetwork
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" { return true }
        if let v4 = IPv4Address(host) { return v4.rawValue.first == 127 }
        if let v6 = IPv6Address(host) { return v6 == .loopback }
        return false
    }

    /// Whether the Mac answers on `host:port` within `timeout` (a TCP connection, closed again right away).
    static func reachable(host: String, port: Int, timeout: Duration = .milliseconds(1500)) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "dev.marquart.aos.directpath")
        let milliseconds = Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                // No route (another network, no VPN) or refused: no waiting for a path to come
                case .failed, .cancelled, .waiting: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                once.run { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        return result
    }
}

extension SSHConnection {
    /// The IP address the connection reached (read on its event loop).
    func remoteIP() async -> String? {
        try? await channel.eventLoop.submit { self.channel.remoteAddress?.ipAddress }.get()
    }
}
