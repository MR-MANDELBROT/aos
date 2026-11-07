import AOSRFB
import CoreGraphics
import Foundation
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
        // Grown until macOS has room (600 points on the short side), Retina: exactly the area's shape
        let upright = DisplayRequest.fitting(points: CGSize(width: 402, height: 812), retina: true)
        #expect(upright == DisplayRequest(width: 1200, height: 2424, scale: 2))
        #expect(abs(1200.0 / 2424.0 - 402.0 / 812.0) < 0.001)
        #expect(DisplayRequest.fitting(points: CGSize(width: 750, height: 402), retina: true)?.description == "2238x1200@2")
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

    @Test func theWorkspaceTakesThePhonesShapeByDefault() {
        let options = ScreenOptions(settings: AppSettings(defaults: defaults()))
        #expect(options.matchShape && options.retina)
    }

    @Test func choicesAreKept() {
        let d = defaults()
        let s = AppSettings(defaults: d)
        s.matchWorkspaceShape = false
        s.retinaWorkspace = false
        let again = ScreenOptions(settings: AppSettings(defaults: d))
        #expect(!again.matchShape && !again.retina)
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
