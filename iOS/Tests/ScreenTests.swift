import AOSRFB
import CoreGraphics
import Foundation
import Network
import ScreenClient
import Testing
@testable import aOS

/// What a screen session gets: the workspace's sealed login and address, the Mac's own screen sharing, the tunnel's
/// target as the Mac sees it, and the workspace in the iPhone's shape. (The session through a real SSH tunnel to a
/// screen sharing server: EndToEndTests and ScreenTunnelTests.)
@MainActor
struct ScreenRouteTests {
    private let mac = PairedMac(name: "Max’s MacBook Pro", hosts: ["mac.local"], sshPort: 22, user: "max",
                                hostKey: "ssh-ed25519 AAAA", hostKeyFingerprint: "SHA256:x", companionPath: CompanionCommand.defaultPath)

    @Test func theWorkspaceUsesTheLoginTheMacSealed() throws {
        let login = ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: "geheim")
        let route = try ScreenRoute.workspace(login, mac: mac, matchShape: true)
        // The tunnel goes where the Mac reaches the workspace; the session itself connects to 127.0.0.1
        #expect(route.targetHost == "192.168.64.5" && route.targetPort == 5900)
        #expect(route.login == .account(username: "aos", password: "geheim"))
        #expect(route.followsWindowShape)
        #expect(route.target == .workspace)
        // The iPhone's clipboard (a copied password, a code) doesn't go to the agent's Mac unless the person turns it on
        #expect(!route.sharesClipboard)
        #expect(try ScreenRoute.workspace(login, mac: mac, matchShape: false).followsWindowShape == false)
    }

    @Test func aWorkspaceAnswerWithoutALoginIsRefused() {
        #expect(throws: ScreenRoute.Problem.noLogin) {
            try ScreenRoute.workspace(ScreenEndpoint(host: "192.168.64.5", port: 5900), mac: mac, matchShape: true)
        }
        #expect(throws: ScreenRoute.Problem.noLogin) {
            try ScreenRoute.workspace(ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: ""),
                                      mac: mac, matchShape: true)
        }
    }

    @Test func theMacIsItsOwnScreenSharingWithTheAccountFromTheKeychain() {
        let route = ScreenRoute.mac(ScreenEndpoint(host: "127.0.0.1", port: 5900), mac: mac,
                                    login: .init(username: "max", password: "pw"))
        #expect(route.targetHost == "127.0.0.1" && route.targetPort == 5900)
        #expect(route.login == .account(username: "max", password: "pw"))
        #expect(!route.followsWindowShape)  // the Mac's screen keeps its size: the iPhone turns to it
        #expect(route.name == mac.name)
        #expect(route.sharesClipboard)  // the person's own Mac: like Universal Clipboard, as in Open Screen Sharing
    }

    @Test func eachScreenOfEachMacHasAnIdOfItsOwn() {
        var other = mac
        other.id = UUID()
        let ids = [ScreenRoute.screenID(.workspace, mac: mac), ScreenRoute.screenID(.mac, mac: mac),
                   ScreenRoute.screenID(.workspace, mac: other), ScreenRoute.screenID(.mac, mac: other)]
        #expect(Set(ids).count == 4)
        #expect(ScreenRoute.screenID(.mac, mac: mac) == ScreenRoute.screenID(.mac, mac: mac))
        #expect(ids[0].uuidString.dropFirst(14).first == "5")
    }

    @Test func theWorkspaceTakesTheShapeOfThePictureArea() {
        // iPhone 17 Pro upright: 402x874 points, the island's 62 on top; on its side the 62 are left and right
        #expect(ScreenRoute.pictureArea(window: CGSize(width: 402, height: 874), top: 62, leading: 0, trailing: 0)
            == CGSize(width: 402, height: 812))
        #expect(ScreenRoute.pictureArea(window: CGSize(width: 874, height: 402), top: 0, leading: 62, trailing: 62)
            == CGSize(width: 750, height: 402))
        // Sized as Open Screen Sharing sizes the Mac's virtual display: grown until the short side has 525 points
        // (the long one 800), two pixels per point on a Retina screen; the area's shape
        let upright = ScreenRoute.display(for: ScreenArea(points: CGSize(width: 402, height: 812), screenScale: 3,
                                                          resolutionScale: 1))
        #expect(upright == DisplayRequest(width: 1050, height: 2120, scale: 2))
        #expect(abs(1050.0 / 2120.0 - 402.0 / 812.0) < 0.002)
        let sideways = ScreenArea(points: CGSize(width: 750, height: 402), screenScale: 3, resolutionScale: 1)
        #expect(ScreenRoute.display(for: sideways)?.description == "1958x1050@2")
        // Open Screen Sharing's resolution: 1.5x the points, more room
        #expect(ScreenRoute.display(for: ScreenArea(points: CGSize(width: 402, height: 812), screenScale: 3,
                                                    resolutionScale: 1.5))?.description == "1206x2436@2")
        // A screen without Retina: one pixel per point
        #expect(ScreenRoute.display(for: ScreenArea(points: CGSize(width: 1024, height: 700), screenScale: 1,
                                                    resolutionScale: 1))?.description == "1024x700@1")
        #expect(ScreenRoute.display(for: ScreenArea(points: .zero, screenScale: 3, resolutionScale: 1)) == nil)
    }

    @Test func bothScreensGetTheSameSize() {
        // The workspace's display request and the Mac's virtual display (Open Screen Sharing's VirtualDisplayMode)
        let size = ScreenClient.displaySize(fitting: CGSize(width: 750, height: 402), screenScale: 3, resolutionScale: 1)
        #expect(size == ScreenDisplaySize(width: 979, height: 525, density: 2))
        #expect(ScreenClient.resolutionScales == [1, 1.25, 1.5, 1.75, 2])
        #expect(ScreenClient.defaultResolutionScale == 1)
    }

    @Test func theDisplayRequestIsSignedWithItsSize() throws {
        let signer = CompanionSigner(phoneID: "4853150ceae1", key: CompanionKey.ephemeral())
        let request = CompanionRequest.display(target: .workspace, size: "1200x2424@2")
        let line = try request.line(id: 3, auth: try signer.auth(for: request))
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: line).object)
        #expect(object["op"]?.string == "display")
        #expect(object["target"]?.string == "workspace")
        #expect(object["text"]?.string == "1200x2424@2")
        let fields = request.signatureFields(key: "k", ts: 1, nonce: "n")
        #expect(fields.op == "companion.display" && fields.target == "workspace")
        #expect(fields.data == CompanionSignature.dataDigest(text: "1200x2424@2"))
        // The mock Mac checks it like the real one and answers the size
        let server = MockCompanionServer(keepsSecrets: true)
        server.update { $0.trustedPhone = .init(phoneID: signer.phoneID, publicKey: signer.key.publicKey) }
        let answer = String(decoding: try #require(server.handle(line: line)), as: UTF8.self)
        #expect(answer.contains("\"ok\":true") && answer.contains("\"width\":1200"))
    }
}

/// Open Screen Sharing's license travels with the app (Settings > Acknowledgements shows it).
@MainActor
struct ScreenLicenseTests {
    @Test func theLicenseNoticeAndTheGPLAreBundled() {
        #expect(ScreenClient.licenseNotice.contains("nekohasekai"))
        #expect(ScreenClient.licenseNotice.contains("GNU General Public License"))
        #expect(ScreenClient.licenseText.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(ScreenClient.licenseText.contains("Version 3, 29 June 2007"))
        #expect(ScreenClient.sourceCode.absoluteString == "https://github.com/nekohasekai/open-screen-sharing")
    }
}

@MainActor
struct ScreenSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "screen-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func bothScreensTakeThePhonesSizeByDefault() {
        let options = ScreenOptions(settings: AppSettings(defaults: defaults()))
        #expect(options.matchesPhone)
        #expect(options.resolutionScale == 1)
    }

    @Test func choicesAreKept() {
        let d = defaults()
        let s = AppSettings(defaults: d)
        s.screenMatchesPhone = false
        s.screenResolution = 1.5
        let again = ScreenOptions(settings: AppSettings(defaults: d))
        #expect(!again.matchesPhone)
        #expect(again.resolutionScale == 1.5)
    }

    @Test func theOldWorkspaceChoiceCarriesOver() {
        let d = defaults()
        d.set(false, forKey: "matchWorkspaceShape")
        #expect(!AppSettings(defaults: d).screenMatchesPhone)
        // A resolution outside Open Screen Sharing's 1x to 2x is Native
        d.set(7.0, forKey: "screenResolution")
        #expect(AppSettings(defaults: d).screenResolution == 1)
    }
}

/// The direct path to the Mac (Open Screen Sharing's high performance needs UDP to the Mac's own address): from the way
/// the SSH connection went, never loopback, not through aOS's own Tailscale node without the Tailscale app's VPN.
struct DirectPathTests {
    private let tailnet = ["100.101.102.103", "aos-maxs-macbook-pro.tail4c2a.ts.net"]

    @Test func theSameNetworkUsesTheAddressSSHReached() {
        #expect(DirectPath.candidate(route: .host("Maxs-MacBook-Pro.local"), remote: "192.168.178.24", tailnetHosts: tailnet,
                                     systemVPN: false) == .address("192.168.178.24"))
        #expect(DirectPath.candidate(route: .host("192.168.178.24"), remote: nil, tailnetHosts: [], systemVPN: false)
            == .address("192.168.178.24"))
        #expect(DirectPath.candidate(route: .bonjour("Max’s MacBook Pro"), remote: "192.168.178.24", tailnetHosts: [],
                                     systemVPN: false) == .address("192.168.178.24"))
        #expect(DirectPath.network(for: "192.168.178.24") == .localNetwork)
    }

    @Test func theTailnetNeedsTheTailscaleAppsVPN() {
        // Through the Tailscale app's VPN: libsharing's TCP and UDP go there as well
        #expect(DirectPath.candidate(route: .host("100.101.102.103"), remote: "100.101.102.103", tailnetHosts: tailnet,
                                     systemVPN: true) == .address("100.101.102.103"))
        #expect(DirectPath.network(for: "100.101.102.103") == .internet)
        #expect(DirectPath.network(for: "aos-maxs-macbook-pro.tail4c2a.ts.net") == .internet)
        #expect(DirectPath.network(for: "fd7a:115c:a1e0::1234") == .internet)
        // aOS's own node carries only the app's SSH connection
        #expect(DirectPath.candidate(route: .tailnet("aos-maxs-macbook-pro.tail4c2a.ts.net"), remote: "127.0.0.1",
                                     tailnetHosts: tailnet, systemVPN: false) == .tailnetWithoutVPN)
        // ... with the Tailscale app's VPN on as well, the Mac's tailnet address (IPv4 first)
        #expect(DirectPath.candidate(route: .tailnet("aos-maxs-macbook-pro.tail4c2a.ts.net"), remote: nil,
                                     tailnetHosts: tailnet, systemVPN: true) == .address("100.101.102.103"))
    }

    @Test func loopbackIsNoPath() {
        #expect(DirectPath.candidate(route: .host("127.0.0.1"), remote: "127.0.0.1", tailnetHosts: [], systemVPN: false)
            == .noAddress)
        #expect(DirectPath.candidate(route: .host("localhost"), remote: "::1", tailnetHosts: [], systemVPN: false) == .noAddress)
        #expect(DirectPath.candidate(route: .bonjour("Mac"), remote: nil, tailnetHosts: [], systemVPN: false) == .noAddress)
        // A link-local address only with its interface: without it the dial finds no route.
        #expect(DirectPath.candidate(route: .bonjour("Mac"), remote: "fe80::17:52fc:76f0:92ba", tailnetHosts: [],
                                     systemVPN: false) == .noAddress)
        #expect(DirectPath.candidate(route: .bonjour("Mac"), remote: "fe80::17:52fc:76f0:92ba%en0", tailnetHosts: [],
                                     systemVPN: false) == .address("fe80::17:52fc:76f0:92ba%en0"))
        #expect(DirectPath.isLinkLocalIPv6("fe80::1%en0") && !DirectPath.isLinkLocalIPv6("fd7a:115c:a1e0::1234"))
        #expect(DirectPath.isLoopback("127.0.0.2") && DirectPath.isLoopback("::1") && !DirectPath.isLoopback("10.0.0.1"))
    }

    @Test func reachableIsAQuickTCPCheck() async throws {
        let rfb = try await FakeRFBServer.start()
        #expect(await DirectPath.reachable(host: "127.0.0.1", port: rfb.port))
        await rfb.stop()
        let started = ContinuousClock.now
        #expect(await DirectPath.reachable(host: "127.0.0.1", port: rfb.port) == false)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

/// The cards' last pictures stay on the iPhone, protected.
@MainActor
struct ScreenPicturesTests {
    @Test func picturesAreKeptProtectedAndOutOfBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenPictures(directory: directory)
        let id = UUID()
        #expect(store.picture(for: id) == nil)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        store.save(jpeg, for: id)
        #expect(store.picture(for: id) == jpeg)
        // The next launch reads it from the file
        #expect(ScreenPictures(directory: directory).picture(for: id) == jpeg)
        let file = directory.appendingPathComponent("\(id.uuidString).jpg")
        #if targetEnvironment(simulator)
        // The simulator keeps no protection classes (it has no data protection); on the iPhone the file has .complete
        #expect(FileManager.default.fileExists(atPath: file.path))
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        store.forget(id)
        #expect(store.picture(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theDemoKeepsThemInMemoryOnly() {
        let store = ScreenPictures(directory: nil)
        let id = UUID()
        store.save(Data([1, 2, 3]), for: id)
        #expect(store.picture(for: id) == Data([1, 2, 3]))
        #expect(store.revision == 1)
    }
}

/// Open Screen Sharing's session through an SSH tunnel (the in-process SSH server's direct-tcpip) to a screen sharing
/// server: the loopback listener, the forwarded connection, Apple's account login, a picture's worth of updates.
@MainActor
@Suite(.serialized)
struct ScreenTunnelTests {
    @Test func theSessionConnectsThroughTheTunnel() async throws {
        let key = DeviceKey.ephemeral()
        let rfb = try await FakeRFBServer.start(width: 64, height: 40, account: .init(username: "aos", password: "pw"))
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop(); await rfb.stop() } }
        let ssh = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                  login: SSHLogin(username: "max", key: key),
                                                  hostKey: .pinned(server.hostKeyLine))
        defer { Task { await ssh.close() } }

        // As the Screen tab does it: the tunnel to the screen as the Mac sees it, the session to 127.0.0.1
        let forwarder = LocalForwarder(targetHost: "127.0.0.1", targetPort: rfb.port) { ssh }
        let port = try await forwarder.start()
        defer { forwarder.stop() }
        let session = ScreenClientSession(screen: UUID(), name: "Workspace", port: Int(port),
                                          login: .account(username: "aos", password: "pw"), followsWindowShape: true,
                                          sharesClipboard: false)
        session.start()
        try await waitUntil(timeout: .seconds(30)) { session.state == .connected }
        #expect(rfb.log.receivedLogins.map(\.username) == ["aos"])
        #expect(!session.sharesClipboard)  // the workspace's clipboard sync starts off
        try await waitUntil(timeout: .seconds(10)) { rfb.log.updateCount > 0 }
        session.close()
        #expect(session.state == .ended)
    }

    @Test func theSetupCheckLearnsTheScreenSharingKeyThroughTheTunnel() async throws {
        let key = DeviceKey.ephemeral()
        let rfb = try await FakeRFBServer.start(account: .init(username: "max", password: "richtig"))
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop(); await rfb.stop() } }
        let ssh = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                  login: SSHLogin(username: "max", key: key),
                                                  hostKey: .pinned(server.hostKeyLine))
        defer { Task { await ssh.close() } }
        let forwarder = LocalForwarder(targetHost: "127.0.0.1", targetPort: rfb.port) { ssh }
        let port = try await forwarder.start()
        defer { forwarder.stop() }

        let screen = UUID()
        #expect(await ScreenClient.checkServer(screen: screen, name: "Mac", port: Int(port),
                                               login: .account(username: "max", password: "falsch")) == .loginRefused)
        #expect(ScreenClient.record(of: screen)?.knowsServerKey == false)
        // The server's key, as it came through SSH, is what a direct connection is checked against later; this server
        // has no high performance (no Apple extensions). The check says what the server offered and what was used.
        let check = await ScreenClient.checkServer(screen: screen, name: "Mac", port: Int(port),
                                                   login: .account(username: "max", password: "richtig"))
        #expect(check == .ok(highPerformance: false, knowsServerKey: true,
                             security: "offered apple-rsa-srp(33), used apple-rsa-srp(33)"))
        #expect(ScreenClient.record(of: screen)?.knowsServerKey == true)
        ScreenClient.forget(screen: screen)
        #expect(ScreenClient.record(of: screen) == nil)
    }

    /// The direct path signs in only with the key learned through SSH (libsharing's RequireTrustedKey, aOS's patch):
    /// a server with another key, one without a key learned, or one without Apple's RSA login gets nothing of the
    /// login. (Apple's RSA login with SRP inside, as screensharingd offers it, checks the key too: the patch's Go tests.)
    @Test func theDirectPathSignsInOnlyWithTheKeyLearnedThroughSSH() async throws {
        let key = DeviceKey.ephemeral()
        let mac = try await FakeRFBServer.start(account: .init(username: "max", password: "richtig"))
        let stranger = try await FakeRFBServer.start(account: .init(username: "max", password: "richtig"))
        let noLogin = try await FakeRFBServer.start()
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop(); await mac.stop(); await stranger.stop(); await noLogin.stop() } }
        let ssh = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                  login: SSHLogin(username: "max", key: key),
                                                  hostKey: .pinned(server.hostKeyLine))
        defer { Task { await ssh.close() } }
        let forwarder = LocalForwarder(targetHost: "127.0.0.1", targetPort: mac.port) { ssh }
        let port = try await forwarder.start()
        defer { forwarder.stop() }
        let login = ScreenLogin.account(username: "max", password: "richtig")

        final class Reasons { var all: [String] = [] }
        func direct(_ screen: UUID, to server: FakeRFBServer) async throws -> String {
            let reasons = Reasons()
            let session = ScreenClientSession(screen: screen, name: "Mac", port: server.port, login: login,
                                              followsWindowShape: false, highPerformance: .localNetwork)
            session.onDirectPathFailed = { reasons.all.append($0) }
            session.start()
            try await waitUntil(timeout: .seconds(20)) { !reasons.all.isEmpty }
            session.close()
            return reasons.all[0]
        }

        // No key learned yet: nothing is sent
        let unknown = UUID()
        let noKey = try await direct(unknown, to: mac)
        #expect(noKey.contains("no trusted server key"))
        #expect(mac.log.receivedLogins.isEmpty)

        // The Mac's key, learned through SSH
        let screen = UUID()
        defer { ScreenClient.forget(screen: screen); ScreenClient.forget(screen: unknown) }
        if case .ok(_, let knowsKey, _) = await ScreenClient.checkServer(screen: screen, name: "Mac", port: Int(port),
                                                                         login: login) {
            #expect(knowsKey)
        } else {
            Issue.record("the check through SSH failed")
        }
        // A stranger with another key gets no login, though it would take the same password
        let changed = try await direct(screen, to: stranger)
        #expect(changed.contains("server key changed"))
        #expect(stranger.log.receivedLogins.isEmpty)
        // A server without Apple's RSA login (no key to check) gets none either
        let unsupported = try await direct(screen, to: noLogin)
        #expect(unsupported.contains("offers security types"))
    }

    @Test func aRefusedLoginGoesBackToAOS() async throws {
        let key = DeviceKey.ephemeral()
        let rfb = try await FakeRFBServer.start(account: .init(username: "max", password: "richtig"))
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop(); await rfb.stop() } }
        let ssh = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                  login: SSHLogin(username: "max", key: key),
                                                  hostKey: .pinned(server.hostKeyLine))
        defer { Task { await ssh.close() } }
        let forwarder = LocalForwarder(targetHost: "127.0.0.1", targetPort: rfb.port) { ssh }
        let port = try await forwarder.start()
        defer { forwarder.stop() }

        let session = ScreenClientSession(screen: UUID(), name: "Mac", port: Int(port),
                                          login: .account(username: "max", password: "falsch"), followsWindowShape: false)
        final class Refused { var count = 0 }
        let refused = Refused()
        session.onLoginRefused = { refused.count += 1 }
        session.start()
        try await waitUntil(timeout: .seconds(30)) { refused.count == 1 }
        // Open Screen Sharing's own sign-in sheet never comes up for aOS's login, and nothing is kept
        #expect(session.state != .connected)
        session.close()
    }
}
