import AOSTailnet
import Darwin
import Foundation
import Testing
@testable import aOS

/// The pairing link's way on the go (`w`, `t`, `tn`), as aOS on the Mac writes it (AOSKit TailnetStatusTests).
struct TailnetLinkTests {
    static let base = "aos-pair://v1?n=Max%E2%80%99s%20MacBook%20Pro&h=Maxs-MacBook-Pro.local,192.168.1.20,100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net&p=50123&s=22&u=max&k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ&c=AAECAwQFBgcICQoLDA0ODw"

    @Test func parsesTheWayAndTheTailnetHosts() throws {
        let link = try PairingLink(Self.base + "&w=aos&t=100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net&tn=max%40example.com")
        #expect(link.way == .aosTailscale)
        #expect(link.tailnetHosts == ["100.90.1.3", "aos-maxs-macbook-pro.tail1234.ts.net"])
        #expect(link.tailnetName == "max@example.com")
        #expect(link.hosts == ["Maxs-MacBook-Pro.local", "192.168.1.20", "100.90.1.3", "aos-maxs-macbook-pro.tail1234.ts.net"])
        // What the iPhone writes for the demo and the tests reads back the same.
        #expect(try PairingLink(link.url.absoluteString) == link)
        #expect(link.url.absoluteString.contains("tn=max%40example.com"))
        #expect(try PairingLink(Self.base + "&w=app").way == .tailscaleApp)
        #expect(try PairingLink(Self.base + "&w=LAN").way == .localNetwork)
    }

    @Test func linksOfAnEarlierMacAndWhatIsntPlausible() throws {
        let old = try PairingLink(Self.base)
        #expect(old.way == nil)
        #expect(old.tailnetHosts == [])
        #expect(old.tailnetName == nil)
        #expect(!old.url.absoluteString.contains("&w="))
        let odd = try PairingLink(Self.base + "&w=vpn&t=100.90.1.3,evil/path,%20,100.90.1.3&tn=a%0Ab")
        #expect(odd.way == nil, "an unknown way counts as none")
        #expect(odd.tailnetHosts == ["100.90.1.3"], "no paths, no empty or repeated hosts")
        #expect(odd.tailnetName == nil, "no line breaks")
    }
}

/// The order the iPhone tries: the same network, the tailnet, Bonjour.
struct ConnectionPlanTests {
    func mac(hosts: [String], tailnet: [String]?, way: ReachWay?, last: String? = nil) -> PairedMac {
        var mac = PairedMac(name: "Max’s MacBook Pro", hosts: hosts, sshPort: 22, user: "max",
                            hostKey: Vectors.ed25519Key, hostKeyFingerprint: Vectors.ed25519Fingerprint,
                            companionPath: CompanionCommand.defaultPath, lastHost: last)
        mac.tailnetHosts = tailnet
        mac.way = way
        return mac
    }

    @Test func theSameNetworkFirstThenTheTailnetThenBonjour() {
        let paired = mac(hosts: ["Maxs-MacBook-Pro.local", "192.168.1.20", "100.90.1.3", "aos-mac.tail1234.ts.net"],
                         tailnet: ["100.90.1.3", "aos-mac.tail1234.ts.net"], way: .aosTailscale, last: "192.168.1.20")
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: true, systemVPN: true) == [
            .host("192.168.1.20"), .host("Maxs-MacBook-Pro.local"),
            .tailnet("100.90.1.3"), .tailnet("aos-mac.tail1234.ts.net"),
            .host("100.90.1.3"), .host("aos-mac.tail1234.ts.net"),
            .bonjour("Max’s MacBook Pro"),
        ])
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: false, systemVPN: false) == [
            .host("192.168.1.20"), .host("Maxs-MacBook-Pro.local"), .bonjour("Max’s MacBook Pro"),
        ])
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: false, systemVPN: true) == [
            .host("192.168.1.20"), .host("Maxs-MacBook-Pro.local"),
            .host("100.90.1.3"), .host("aos-mac.tail1234.ts.net"), .bonjour("Max’s MacBook Pro"),
        ])
    }

    @Test func aTailnetAddressThatWorkedLastStillComesAfterTheSameNetwork() {
        let paired = mac(hosts: ["mac.local", "100.90.1.3"], tailnet: ["100.90.1.3"], way: .tailscaleApp, last: "100.90.1.3")
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: false, systemVPN: true)
                == [.host("mac.local"), .host("100.90.1.3"), .bonjour("Max’s MacBook Pro")])
    }

    @Test func aMacPairedBeforeTheWayExistedUsesTheTailnetAddressesAmongItsHosts() {
        let paired = mac(hosts: ["mac.local", "10.0.0.5", "maxs-mbp.tail1234.ts.net", "100.101.102.103"], tailnet: nil, way: nil)
        #expect(ConnectionPlan.tailnetHosts(of: paired) == ["100.101.102.103", "maxs-mbp.tail1234.ts.net"])
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: true, systemVPN: false) == [
            .host("mac.local"), .host("10.0.0.5"), .tailnet("100.101.102.103"), .tailnet("maxs-mbp.tail1234.ts.net"),
            .bonjour("Max’s MacBook Pro"),
        ])
    }

    @Test func onlyTheSameNetwork() {
        let paired = mac(hosts: ["mac.local", "192.168.1.20"], tailnet: [], way: .localNetwork)
        #expect(ConnectionPlan.routes(for: paired, embeddedNode: true, systemVPN: true)
                == [.host("mac.local"), .host("192.168.1.20"), .bonjour("Max’s MacBook Pro")])
    }

    @Test func routesKnowWhetherTheyGoThroughATailnet() {
        #expect(SSHRoute.tailnet("aos-mac").isTailnet)
        #expect(SSHRoute.host("100.90.1.3").isTailnet)
        #expect(!SSHRoute.host("192.168.1.20").isTailnet)
        #expect(!SSHRoute.bonjour("Max’s MacBook Pro").isTailnet)
    }
}

struct EmbeddedTailnetTests {
    @Test func onlyTailscalesSignInPagesOpen() {
        #expect(EmbeddedTailnet.signInPage("https://login.tailscale.com/a/1a2b3c") != nil)
        #expect(EmbeddedTailnet.signInPage("https://tailscale.com/a/1") != nil)
        #expect(EmbeddedTailnet.signInPage("http://login.tailscale.com/a/1") == nil)
        #expect(EmbeddedTailnet.signInPage("https://login.tailscale.com.example.org/a/1") == nil)
        #expect(EmbeddedTailnet.signInPage("https://eviltailscale.com/a/1") == nil)
        #expect(EmbeddedTailnet.signInPage("aos-tailnet://done") == nil)
    }

    @Test func theNodeIsNamedAfterThisIPhone() {
        #expect(TailnetNames.hostname(device: "Max’s iPhone", fallback: "iphone") == "aos-max-s-iphone")
        #expect(TailnetNames.hostname(device: "iPhone", fallback: "iphone") == "aos-iphone")
        #expect(TailnetNames.hostname(device: "📱", fallback: "iphone") == "aos-iphone")
    }

    /// What Tailnetkit's StatusJSON returns (tsnet's status, as in the Go tests): this iPhone, the Mac's node.
    @Test func theNodesStatusParses() throws {
        let json = """
        {"BackendState":"Running","AuthURL":"","TailscaleIPs":["100.90.1.4"],
         "Self":{"ID":"n2","HostName":"aos-max-s-iphone","DNSName":"aos-max-s-iphone.tail1234.ts.net.","OS":"iOS",
                 "TailscaleIPs":["100.90.1.4","fd7a:115c:a1e0::4"],"Online":true,"UserID":1,"KeyExpiry":"2027-05-06T07:08:09Z"},
         "CurrentTailnet":{"Name":"max@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true},
         "Peer":{"nodekey:1":{"ID":"n1","HostName":"aos-maxs-macbook-pro","DNSName":"aos-maxs-macbook-pro.tail1234.ts.net.",
                 "OS":"macOS","TailscaleIPs":["100.90.1.3"],"Online":true,"LastSeen":"0001-01-01T00:00:00Z"}},
         "User":{"1":{"ID":1,"LoginName":"max@example.com","DisplayName":"Max"}}}
        """
        let status = try TailnetStatus(json: Data(json.utf8))
        #expect(status.isRunning)
        #expect(status.device?.dnsName == "aos-max-s-iphone.tail1234.ts.net")
        #expect(status.aosDevices.map(\.hostName) == ["aos-max-s-iphone", "aos-maxs-macbook-pro"])
        var paired = PairedMac(name: "Mac", hosts: ["mac.local"], sshPort: 22, user: "max", hostKey: "", hostKeyFingerprint: "",
                               companionPath: "/x/aos-companion")
        paired.tailnetHosts = ["100.90.1.3"]
        #expect(ConnectionPlan.macNode(of: paired, in: status)?.hostName == "aos-maxs-macbook-pro")
    }
}

/// SSH through a connected socket, the way aOS's tailnet node hands one over (Tailnetkit's DialFD: one end of a
/// socket pair whose other end carries the tailnet connection). Here the other end is spliced to the test SSH server.
@Suite(.serialized)
struct TailnetSSHTests {
    let key = DeviceKey.ephemeral()

    @Test func theCompanionThroughATailnetSocket() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let port = server.port
        let dialed = DialLog()
        let dial: TailnetDial = { host, dialPort, _ in
            dialed.add("\(host):\(dialPort)")
            return try SocketPairBridge.connect(toLocalPort: port)
        }
        let connection = try await SSHConnection.connect(
            routes: [.tailnet("100.90.1.3")], port: 22, login: SSHLogin(username: "max", key: key),
            hostKey: .fingerprint(server.hostKeyFingerprint), tailnet: dial)
        defer { Task { await connection.close() } }
        #expect(connection.route == .tailnet("100.90.1.3"))
        #expect(connection.host == "100.90.1.3")
        #expect(dialed.items == ["100.90.1.3:22"], "port 22 of the Mac's tailnet address")
        #expect(connection.hostKeyFingerprint == server.hostKeyFingerprint, "the pinned key, whichever way")

        let signer = CompanionSigner(phoneID: key.phoneID, key: CompanionKey.ephemeral())
        server.companion.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        let channel = try await connection.exec(CompanionCommand.serve(path: TestSSHServer.companionPath))
        let client = CompanionClient(transport: channel, signer: signer)
        await client.start()
        #expect(try await client.hello(app: "0.1.0", device: "Test").mac == "Max’s MacBook Pro")
        #expect(try await client.status().state == .open)
        await client.close()
    }

    @Test func aTailnetNodeCantPoseAsTheMac() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let port = server.port
        await #expect(throws: SSHConnectError.self) {
            _ = try await SSHConnection.connect(
                routes: [.tailnet("100.90.1.3")], port: 22, login: SSHLogin(username: "max", key: key),
                hostKey: .pinned(Vectors.ed25519Key), tailnet: { _, _, _ in try SocketPairBridge.connect(toLocalPort: port) })
        }
    }

    @Test func theSameNetworkWinsWhenBothAnswer() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let port = server.port
        let connection = try await SSHConnection.connect(
            routes: [.host("127.0.0.1"), .tailnet("100.90.1.3")], port: port, login: SSHLogin(username: "max", key: key),
            hostKey: .pinned(server.hostKeyLine), tailnet: { _, _, _ in
                try await Task.sleep(for: .seconds(2))
                return try SocketPairBridge.connect(toLocalPort: port)
            })
        #expect(connection.route == .host("127.0.0.1"))
        await connection.close()
    }

    @Test func withoutANodeTheTailnetRouteFails() async throws {
        await #expect(throws: SSHConnectError.self) {
            _ = try await SSHConnection.connect(routes: [.tailnet("100.90.1.3")], port: 22,
                                                login: SSHLogin(username: "max", key: key), hostKey: .askFirst)
        }
    }
}

private final class DialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ item: String) { lock.withLock { list.append(item) } }
    var items: [String] { lock.withLock { list } }
}

/// A socket pair, one end spliced to a TCP connection to 127.0.0.1:port by two threads.
enum SocketPairBridge {
    static func connect(toLocalPort port: Int) throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EMFILE) }
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(tcp); close(pair[0]); close(pair[1])
            throw POSIXError(.ECONNREFUSED)
        }
        var on: Int32 = 1
        for fd in [pair[0], pair[1], tcp] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let inner = pair[0]
        Thread.detachNewThread { pump(from: inner, to: tcp) }
        Thread.detachNewThread { pump(from: tcp, to: inner) }
        return pair[1]
    }

    private static func pump(from source: Int32, to target: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(source, &buffer, buffer.count)
            if n <= 0 { break }
            var offset = 0
            while offset < n {
                let written = buffer.withUnsafeBytes { write(target, $0.baseAddress! + offset, n - offset) }
                if written <= 0 { shutdown(target, SHUT_WR); return }
                offset += written
            }
        }
        shutdown(target, SHUT_WR)
    }
}
