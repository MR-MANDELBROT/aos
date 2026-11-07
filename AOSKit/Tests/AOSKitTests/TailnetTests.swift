import Foundation
@testable import AOSKit
@testable import AOSTailnet
import XCTest

/// What `tailscale status --json` prints on a Mac with the Tailscale app (the keys of macOS's standalone app, Tailscale
/// 1.9x/1.10x; the values made up): this Mac, an iPhone with the Tailscale app, and aOS's own nodes.
let tailscaleAppStatus = """
{
  "Version": "1.104.5-t1234abcd-g5678ef",
  "TUN": true,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::6d01:a0c7"],
  "Self": {
    "ID": "nSelf1CNTRL", "PublicKey": "nodekey:aaaa", "HostName": "Maxs-MacBook-Pro",
    "DNSName": "maxs-macbook-pro.tail1234.ts.net.", "OS": "macOS", "UserID": 12345,
    "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::6d01:a0c7"], "AllowedIPs": ["100.101.102.103/32"],
    "Addrs": ["192.168.1.20:41641"], "CurAddr": "", "Relay": "fra", "PeerRelay": "", "RxBytes": 0, "TxBytes": 0,
    "Created": "2026-04-19T10:11:12.123456789Z", "LastWrite": "0001-01-01T00:00:00Z",
    "LastSeen": "0001-01-01T00:00:00Z", "LastHandshake": "0001-01-01T00:00:00Z", "Online": true,
    "ExitNode": false, "ExitNodeOption": false, "Active": false, "PeerAPIURL": ["http://100.101.102.103:56789"],
    "TaildropTarget": 0, "NoFileSharingReason": "", "Capabilities": ["https://tailscale.com/cap/file-sharing"],
    "CapMap": {"https://tailscale.com/cap/file-sharing": null}, "InNetworkMap": true, "InMagicSock": false,
    "InEngine": false, "KeyExpiry": "2027-04-17T10:11:12Z"
  },
  "Health": [],
  "MagicDNSSuffix": "tail1234.ts.net",
  "CurrentTailnet": {"Name": "max@example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
  "CertDomains": ["maxs-macbook-pro.tail1234.ts.net"],
  "ExtraRecords": null,
  "Peer": {
    "nodekey:bbbb": {
      "ID": "nPhone1CNTRL", "PublicKey": "nodekey:bbbb", "HostName": "iPhone", "DNSName": "maxs-iphone.tail1234.ts.net.",
      "OS": "iOS", "UserID": 12345, "TailscaleIPs": ["100.80.1.2", "fd7a:115c:a1e0::2"], "Online": false,
      "LastSeen": "2026-11-06T21:04:05.5Z", "KeyExpiry": "2027-01-02T03:04:05Z", "Active": false
    },
    "nodekey:cccc": {
      "ID": "nAosMac1CNTRL", "PublicKey": "nodekey:cccc", "HostName": "aos-maxs-macbook-pro",
      "DNSName": "aos-maxs-macbook-pro.tail1234.ts.net.", "OS": "macOS", "UserID": 12345,
      "TailscaleIPs": ["fd7a:115c:a1e0::3", "100.90.1.3"], "Online": true, "LastSeen": "0001-01-01T00:00:00Z"
    },
    "nodekey:dddd": {
      "ID": "nAosPhone1CNTRL", "PublicKey": "nodekey:dddd", "HostName": "aos-maxs-iphone",
      "DNSName": "aos-maxs-iphone.tail1234.ts.net.", "OS": "iOS", "UserID": 12345,
      "TailscaleIPs": ["100.90.1.4"], "Online": false, "LastSeen": "2026-11-07T08:00:00.123Z",
      "KeyExpiry": "2026-11-01T00:00:00Z", "Expired": true
    }
  },
  "User": {
    "12345": {"ID": 12345, "LoginName": "max@example.com", "DisplayName": "Max", "ProfilePicURL": ""}
  },
  "ClientVersion": null
}
"""

final class TailnetStatusTests: XCTestCase {
    func testParsesTheTailscaleAppsStatus() throws {
        let status = try TailnetStatus(json: Data(tailscaleAppStatus.utf8))
        XCTAssertTrue(status.isRunning)
        XCTAssertNil(status.authURL, "an empty sign-in URL is none")
        XCTAssertEqual(status.tailnet, "max@example.com")
        XCTAssertEqual(status.magicDNSSuffix, "tail1234.ts.net")
        XCTAssertEqual(status.user, "max@example.com")
        let me = try XCTUnwrap(status.device)
        XCTAssertEqual(me.hostName, "Maxs-MacBook-Pro")
        XCTAssertEqual(me.dnsName, "maxs-macbook-pro.tail1234.ts.net", "without the final dot")
        XCTAssertEqual(me.ipv4, "100.101.102.103")
        XCTAssertEqual(me.os, "macOS")
        XCTAssertNil(me.lastSeen, "Go's zero time is no date")
        XCTAssertEqual(me.keyExpiry, ISO8601DateFormatter().date(from: "2027-04-17T10:11:12Z"))
        XCTAssertFalse(me.isAOS)

        XCTAssertEqual(status.peers.map(\.hostName), ["aos-maxs-iphone", "aos-maxs-macbook-pro", "iPhone"])
        let phone = try XCTUnwrap(status.peer(named: "iphone"))
        XCTAssertFalse(phone.online)
        XCTAssertEqual(phone.lastSeen?.timeIntervalSince1970 ?? 0,
                       ISO8601DateFormatter().date(from: "2026-11-06T21:04:05Z")!.timeIntervalSince1970 + 0.5, accuracy: 0.01)
        let aosMac = try XCTUnwrap(status.peer(named: "aos-maxs-macbook-pro"))
        XCTAssertEqual(aosMac.addresses, ["100.90.1.3", "fd7a:115c:a1e0::3"], "IPv4 first")
        XCTAssertNil(aosMac.keyExpiry, "key expiry off")
        XCTAssertEqual(status.aosDevices.map(\.hostName), ["aos-maxs-iphone", "aos-maxs-macbook-pro"])
        XCTAssertTrue(try XCTUnwrap(status.peer(named: "aos-maxs-iphone")).expired)
    }

    func testNeedsLoginWithASignInURL() throws {
        let json = #"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/1a2b3c","Self":null,"Peer":null,"Health":["not logged in"]}"#
        let status = try TailnetStatus(json: Data(json.utf8))
        XCTAssertTrue(status.needsLogin)
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.authURL, "https://login.tailscale.com/a/1a2b3c")
        XCTAssertNil(status.device)
        XCTAssertEqual(status.peers, [])
        XCTAssertEqual(status.health, ["not logged in"])
    }

    func testRefusesWhatIsntAStatus() {
        XCTAssertThrowsError(try TailnetStatus(json: Data("failed to connect to local Tailscale service".utf8)))
        XCTAssertThrowsError(try TailnetStatus(json: Data(#"{"Version":"1.0"}"#.utf8)))
    }

    func testGoTimesWithNineFractionDigits() {
        let date = TailnetDevice.date("2026-11-07T08:00:00.123456789Z")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0,
                       ISO8601DateFormatter().date(from: "2026-11-07T08:00:00Z")!.timeIntervalSince1970 + 0.123, accuracy: 0.001)
        XCTAssertNil(TailnetDevice.date("0001-01-01T00:00:00Z"))
        XCTAssertNotNil(TailnetDevice.date("2026-11-07T08:00:00+01:00"))
    }

    // MARK: The Tailscale app

    func testTheAppsStateFromItsOutput() {
        let running = TailscaleApp.state(stdout: Data(tailscaleAppStatus.utf8), exitStatus: 0, timedOut: false)
        XCTAssertEqual(running.status?.device?.dnsName, "maxs-macbook-pro.tail1234.ts.net")
        // An update notice before the JSON.
        let noticed = TailscaleApp.state(stdout: Data(("Update available: 1.106.0\n" + tailscaleAppStatus).utf8),
                                         exitStatus: 0, timedOut: false)
        XCTAssertNotNil(noticed.status)
        // Not running: no JSON, an error.
        XCTAssertEqual(TailscaleApp.state(stdout: Data("failed to connect to local Tailscale service; is Tailscale running?\n".utf8),
                                          exitStatus: 1, timedOut: false), .notConnected(nil))
        // Running, not signed in.
        XCTAssertEqual(TailscaleApp.state(stdout: Data(#"{"BackendState":"NeedsLogin","AuthURL":""}"#.utf8),
                                          exitStatus: 0, timedOut: false), .notConnected("NeedsLogin"))
        XCTAssertEqual(TailscaleApp.state(stdout: Data(#"{"BackendState":"Stopped"}"#.utf8), exitStatus: 0, timedOut: false),
                       .notConnected("Stopped"))
        XCTAssertEqual(TailscaleApp.state(stdout: Data(tailscaleAppStatus.utf8), exitStatus: 0, timedOut: true), .notConnected(nil))
    }

    func testTheCommandLineToolsInOrder() {
        XCTAssertEqual(TailscaleApp.commandLineTool { _ in true }, "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertEqual(TailscaleApp.commandLineTool { $0 == "/opt/homebrew/bin/tailscale" }, "/opt/homebrew/bin/tailscale")
        XCTAssertNil(TailscaleApp.commandLineTool { _ in false })
    }

    // MARK: The setup's recommendation

    func testRecommendation() throws {
        let connected = TailscaleAppState.connected(try TailnetStatus(json: Data(tailscaleAppStatus.utf8)))
        XCTAssertEqual(ReachAdvisor.recommended(for: connected), .tailscaleApp)
        XCTAssertEqual(ReachAdvisor.recommended(for: .notInstalled), .aosTailscale)
        XCTAssertEqual(ReachAdvisor.recommended(for: .notConnected(nil)), .aosTailscale, "installed but not running")
        XCTAssertEqual(ReachAdvisor.recommended(for: .notConnected("NeedsLogin")), .aosTailscale)
        XCTAssertEqual(Set(ReachWay.allCases), [.tailscaleApp, .aosTailscale, .localNetwork], "always all three")
    }

    // MARK: The pairing link

    func testReachFromANode() throws {
        let node = try TailnetStatus(json: Data(tailscaleAppStatus.utf8))
        let reach = PairingReach(way: .tailscaleApp, node: node)
        XCTAssertEqual(reach.tailnetHosts, ["100.101.102.103", "maxs-macbook-pro.tail1234.ts.net"])
        XCTAssertEqual(reach.tailnetName, "max@example.com")
        // The local hosts first, the tailnet hosts after them, once (the app's address is a utun address too).
        XCTAssertEqual(reach.linkHosts(local: ["Maxs-MacBook-Pro.local", "192.168.1.20", "100.101.102.103"]),
                       ["Maxs-MacBook-Pro.local", "192.168.1.20", "100.101.102.103", "maxs-macbook-pro.tail1234.ts.net"])
        // Only on the same network: no tailnet hosts, the local ones as they are.
        let local = PairingReach(way: .localNetwork, node: node)
        XCTAssertEqual(local.tailnetHosts, [])
        XCTAssertNil(local.tailnetName)
        XCTAssertEqual(local.linkHosts(local: ["mac.local", "10.0.0.5"]), ["mac.local", "10.0.0.5"])
        // A node that isn't running has nothing to offer.
        let waiting = try TailnetStatus(json: Data(#"{"BackendState":"NeedsLogin"}"#.utf8))
        XCTAssertEqual(PairingReach(way: .aosTailscale, node: waiting).tailnetHosts, [])
    }

    @MainActor
    func testPairingLinkCarriesTheWayAndTheTailnetHosts() throws {
        let reach = PairingReach(way: .aosTailscale, tailnetHosts: ["100.90.1.3", "aos-maxs-macbook-pro.tail1234.ts.net"],
                                 tailnetName: "max@example.com")
        let session = PairingSession(code: Data(0..<16), keys: AuthorizedKeys(url: URL(fileURLWithPath: "/dev/null")),
                                     phones: MemoryPhoneKeys(), companion: "/Applications/aOS.app/Contents/MacOS/aos-companion",
                                     hosts: ["mac.local", "192.168.1.20"], reach: reach)
        let link = try XCTUnwrap(URLComponents(string: session.makeURL(port: 50123, fingerprint: "SHA256:abc+/=")))
        var items: [String: String] = [:]
        for item in link.queryItems ?? [] { items[item.name] = item.value }
        XCTAssertEqual(items["h"], "mac.local,192.168.1.20,100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net")
        XCTAssertEqual(items["t"], "100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net")
        XCTAssertEqual(items["w"], "aos")
        XCTAssertEqual(items["tn"], "max@example.com")
        XCTAssertTrue(link.percentEncodedQuery?.contains("tn=max%40example.com") == true, "strictly encoded")
        // Without a way: the link as before.
        let plain = PairingSession(code: Data(0..<16), keys: AuthorizedKeys(url: URL(fileURLWithPath: "/dev/null")),
                                   phones: MemoryPhoneKeys(), companion: "/x/aos-companion", hosts: ["mac.local"])
        let old = try XCTUnwrap(URLComponents(string: plain.makeURL(port: 1, fingerprint: "SHA256:abc")))
        XCTAssertEqual(old.queryItems?.map(\.name), ["n", "h", "p", "s", "u", "k", "c"])
    }

    // MARK: Addresses

    func testTailscalesAddressRanges() {
        for yes in ["100.64.0.0", "100.101.102.103", "100.127.255.255"] { XCTAssertTrue(TailnetAddress.isTailnetIPv4(yes), yes) }
        for no in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "192.168.1.20", "fd7a:115c:a1e0::1", "mac.local", ""] {
            XCTAssertFalse(TailnetAddress.isTailnetIPv4(no), no)
        }
        XCTAssertTrue(TailnetAddress.isTailnetIPv6("fd7a:115c:a1e0::6d01:a0c7"))
        XCTAssertTrue(TailnetAddress.isTailnetIPv6("fd7a:115c:a1e0:ab12:4843:cd96:6240:1"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv6("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv6("fe80::1%utun3"))
        XCTAssertTrue(TailnetAddress.isTailnetHost("aos-mac.tail1234.ts.net"))
        XCTAssertTrue(TailnetAddress.isTailnetHost("aos-mac.example.org", suffix: "example.org"))
        XCTAssertFalse(TailnetAddress.isTailnetHost("Maxs-MacBook-Pro.local"))
    }

    func testTailscaleVPNIsAUtunWithATailnetAddress() {
        typealias I = TailnetVPN.Interface
        XCTAssertTrue(TailnetVPN.isActive([I(name: "en0", address: "192.168.1.5"), I(name: "utun4", address: "100.80.1.2")]))
        XCTAssertTrue(TailnetVPN.isActive([I(name: "utun2", address: "fd7a:115c:a1e0::2")]))
        XCTAssertFalse(TailnetVPN.isActive([I(name: "utun0", address: "fe80::1"), I(name: "utun1", address: "10.8.0.2")]))
        XCTAssertFalse(TailnetVPN.isActive([I(name: "en0", address: "100.80.1.2")]), "only on a tunnel")
    }
}

/// The helper's request checks and its custody of the node, with a stand-in for aos-tailnet (Fixtures).
final class TailnetHostTests: XCTestCase {
    var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("tailnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    var fake: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("fake-aos-tailnet") }

    func makeHost(verify: @escaping @Sendable (String) -> String? = { _ in nil }) -> TailnetHost {
        let fake = self.fake
        return TailnetHost(layout: .init(base: base), account: { nil }, source: { fake }, verify: verify,
                           restartDelays: [0.2])
    }

    func testRequestChecks() {
        XCTAssertNil(TailnetRequest(op: .start, hostname: "aos-maxs-macbook-pro").problem)
        XCTAssertEqual(TailnetRequest(op: .start).problem, "no host name")
        for bad in ["maxs-macbook-pro", "aos-Maxs", "aos-max s", "aos-", "aos-mac.local", "aos-mac;rm", "aos-mäc",
                    "aos-" + String(repeating: "a", count: 60)] {
            XCTAssertEqual(TailnetRequest(op: .start, hostname: bad).problem, "invalid host name", bad)
        }
        XCTAssertEqual(TailnetRequest(op: .status, hostname: "aos-x").problem, "unexpected host name")
        XCTAssertNil(TailnetRequest(op: .logout).problem)
        XCTAssertNil(TailnetRequest.decode(Data(#"{"op":"forward"}"#.utf8)), "only the known operations")
        XCTAssertEqual(TailnetRequest.decode(TailnetRequest(op: .start, hostname: "aos-a").data), TailnetRequest(op: .start, hostname: "aos-a"))
    }

    func testHostnameForTheMac() {
        XCTAssertEqual(TailnetRequest.hostname(forMac: "Maxs-MacBook-Pro"), "aos-maxs-macbook-pro")
        XCTAssertEqual(TailnetRequest.hostname(forMac: "Max’s MacBook Pro (2)"), "aos-max-s-macbook-pro-2")
        XCTAssertEqual(TailnetRequest.hostname(forMac: "Mäc"), "aos-m-c")
        XCTAssertEqual(TailnetRequest.hostname(forMac: "!!!"), "aos-mac")
        let long = TailnetRequest.hostname(forMac: String(repeating: "abc-", count: 30))
        XCTAssertLessThanOrEqual(long.utf8.count, 63)
        XCTAssertTrue(TailnetRequest.isValidHostname(long))
        for name in ["Maxs-MacBook-Pro", "Max’s MacBook Pro (2)", "Mäc", "!!!"] {
            XCTAssertTrue(TailnetRequest.isValidHostname(TailnetRequest.hostname(forMac: name)), name)
        }
    }

    func testStartSignInStopAndResume() async throws {
        let host = makeHost()
        var reply = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        XCTAssertTrue(reply.ok, reply.message ?? "")
        XCTAssertEqual(reply.enabled, true)
        XCTAssertEqual(reply.running, true)
        XCTAssertEqual(reply.status?.backendState, "NeedsLogin")
        XCTAssertEqual(reply.status?.authURL, "https://login.tailscale.com/a/test")
        XCTAssertTrue(host.isOn, "the helper stays while the node is on")

        // The state folder is the node's own, and the copy that runs is the checked one.
        let state = TailnetHost.Layout(base: base).state
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: TailnetHost.Layout(base: base).executable.path))
        let starts = try String(contentsOf: state.appendingPathComponent("starts"), encoding: .utf8)
        XCTAssertTrue(starts.hasPrefix("aos-test-mac "), starts)
        XCTAssertTrue(starts.contains(state.path), "HOME is the state folder")

        reply = await host.handle(TailnetRequest(op: .login))
        XCTAssertEqual(reply.status?.backendState, "Running")
        XCTAssertEqual(reply.status?.device?.dnsName, "aos-test-mac.tail-aos.ts.net")

        reply = await host.handle(TailnetRequest(op: .stop))
        XCTAssertEqual(reply.enabled, false)
        XCTAssertEqual(reply.running, false)
        XCTAssertFalse(host.isOn)
        XCTAssertEqual(reply.hostname, "aos-test-mac", "the name and the sign-in stay")

        // On again: a new helper (after a restart) starts it from tailnet.json by itself.
        _ = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        await host.shutdown()
        let next = makeHost()
        XCTAssertTrue(next.isOn)
        await next.resume()
        reply = await next.handle(TailnetRequest(op: .status))
        for _ in 0..<20 where reply.statusJSON == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            reply = await next.handle(TailnetRequest(op: .status))
        }
        XCTAssertEqual(reply.running, true)
        XCTAssertEqual(reply.status?.backendState, "Running", "signed in from before")
        await next.shutdown()
    }

    func testLogoutSignsOutAndDeletesTheState() async throws {
        let host = makeHost()
        _ = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        _ = await host.handle(TailnetRequest(op: .login))
        let reply = await host.handle(TailnetRequest(op: .logout))
        XCTAssertTrue(reply.ok)
        XCTAssertNil(reply.message, "signed out at Tailscale")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("logged-out").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TailnetHost.Layout(base: base).state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TailnetHost.Layout(base: base).config.path))
        XCTAssertEqual(reply.enabled, false)
        XCTAssertFalse(host.isOn)
    }

    func testLogoutStartsAStoppedNodeToSignOut() async throws {
        let host = makeHost()
        _ = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        _ = await host.handle(TailnetRequest(op: .login))
        _ = await host.handle(TailnetRequest(op: .stop))
        let reply = await host.handle(TailnetRequest(op: .logout))
        XCTAssertTrue(reply.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("logged-out").path))
        XCTAssertEqual(reply.running, false)
    }

    func testAnEndedNodeStartsAgain() async throws {
        let host = makeHost()
        try "crash".write(to: base.appendingPathComponent("behavior"), atomically: true, encoding: .utf8)
        var reply = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        XCTAssertTrue(host.isOn)
        try FileManager.default.removeItem(at: base.appendingPathComponent("behavior"))
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            reply = await host.handle(TailnetRequest(op: .status))
            if reply.statusJSON != nil { break }
        }
        XCTAssertEqual(reply.running, true, reply.problem ?? "")
        let starts = try String(contentsOf: TailnetHost.Layout(base: base).state.appendingPathComponent("starts"), encoding: .utf8)
        XCTAssertGreaterThanOrEqual(starts.split(separator: "\n").count, 2)
        await host.shutdown()
    }

    func testRefusesAnExecutableThatIsntAOSs() async throws {
        let host = makeHost(verify: { _ in "signed by someone else" })
        let reply = await host.handle(TailnetRequest(op: .start, hostname: "aos-test-mac"))
        XCTAssertEqual(reply.running, false)
        XCTAssertTrue(reply.problem?.contains("signed by someone else") == true, reply.problem ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TailnetHost.Layout(base: base).executable.path),
                       "the copy that failed the check is gone")
        await host.shutdown()
        _ = await host.handle(TailnetRequest(op: .stop))
    }

    func testRefusesBadRequests() async {
        let host = makeHost()
        let reply = await host.handle(TailnetRequest(op: .start, hostname: "Maxs MacBook"))
        XCTAssertFalse(reply.ok)
        XCTAssertFalse(host.isOn)
        let login = await host.handle(TailnetRequest(op: .login))
        XCTAssertFalse(login.ok, "nothing to sign in")
    }

    func testTheRealSignatureCheckRefusesOtherCode() {
        // /bin/ls is Apple's, not aOS's aos-tailnet.
        XCTAssertNotNil(TailnetHost.checkSignature("/bin/ls"))
        XCTAssertNotNil(TailnetHost.checkSignature(fake.path), "a script without a signature")
    }
}
