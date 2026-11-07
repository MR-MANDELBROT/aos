import Foundation
import Network
import ScreenClient

/// The direct path to the Mac's screen sharing, for Open Screen Sharing's high performance and its virtual display.
///
/// High performance sends the picture as video over UDP, to and from the address the screen sharing TCP connection
/// reached (libsharing, `internal/rfb/mediastream.go`). Through the SSH tunnel that would be 127.0.0.1, and SSH
/// carries TCP only; so it needs the Mac's own address: the one the SSH connection reached, if that is an address in
/// a network (the same Wi-Fi, or the tailnet with Tailscale on). Ports and protocols: iOS/NOTES.md.
enum DirectPath {
    /// Screen sharing on the Mac (TCP); the media ports the Mac announces in the session.
    static let screenSharingPort = 5900

    /// The Mac's address for a direct connection, from the SSH connection (`remote`: the IP it reached; `host`: the
    /// name or address aOS dialed). Nil for loopback (the test servers, a relay on this iPhone).
    static func host(remote: String?, sshHost: String) -> String? {
        let candidate = (remote?.isEmpty == false ? remote : nil) ?? sshHost
        guard !candidate.isEmpty, !isLoopback(candidate) else { return nil }
        return candidate
    }

    /// Open Screen Sharing's network quality for the path: the tailnet counts as the internet (one band, 4:2:0,
    /// Open Screen Sharing's tuning for Tailscale), everything else as the local network.
    static func network(for host: String) -> ScreenNetwork {
        isTailnet(host) ? .internet : .localNetwork
    }

    /// Tailscale's addresses: 100.64.0.0/10 (IPv4), fd7a:115c:a1e0::/48 (IPv6), MagicDNS names (*.ts.net).
    static func isTailnet(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") || host.hasSuffix(".ts.net.") { return true }
        if let v4 = IPv4Address(host) {
            let bytes = Array(v4.rawValue)
            return bytes[0] == 100 && (bytes[1] & 0xC0) == 64
        }
        if let v6 = IPv6Address(host.split(separator: "%").first.map(String.init) ?? host) {
            let bytes = Array(v6.rawValue)
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1
                && bytes[5] == 0xe0
        }
        return false
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
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .cancelled: once.run { continuation.resume(returning: false) }
                case .waiting: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000)
                                                               + Int(timeout.components.attoseconds / 1_000_000_000_000_000))) {
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
