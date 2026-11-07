import AOSRFB
import Foundation
import ScreenClient
import Testing
@testable import aOS

/// The app's own flow end to end, against servers in the test process: pairing (fake listener), SSH with the
/// fingerprint from the code, the connection the model keeps up with the pinned key, the companion's events, an
/// answer, and the workspace screen with a click.
@MainActor
@Suite(.serialized)
struct EndToEndTests {
    final class Steps { var all: [AppModel.PairingStep] = [] }

    @Test func pairServeAnswerAndWatch() async throws {
        let key = try DeviceKey.loadOrCreate()  // the app's own key, in the simulator's keychain
        let started = ContinuousClock.now
        // Screen sharing servers with Apple's account login: the workspace's and the Mac's
        let rfb = try await FakeRFBServer.start(width: 80, height: 50, account: .init(username: "aos", password: "pw"))
        let macRFB = try await FakeRFBServer.start(width: 96, height: 60, account: .init(username: "max", password: "richtig"))
        let companion = MockCompanionServer(keepsSecrets: true)
        companion.update {
            $0.screens[.workspace] = ScreenEndpoint(host: "127.0.0.1", port: UInt16(rfb.port), username: "aos", password: "pw")
            $0.screens[.mac] = ScreenEndpoint(host: "127.0.0.1", port: UInt16(macRFB.port))
        }
        let server = try await TestSSHServer.start(allowedKey: key, companion: companion)
        let code = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let listener = try await FakePairingListener.start(code: code, behavior: .accept(user: "max",
                                                                                     companion: TestSSHServer.companionPath))
        let previousMacs = ConfigStore.loadMacs()
        defer {
            try? ConfigStore.saveMacs(previousMacs)
            Task { await listener.stop(); await server.stop(); await rfb.stop(); await macRFB.stop() }
        }

        let link = PairingLink(macName: "Test Mac", hosts: ["192.0.2.1", "127.0.0.1"], pairingPort: UInt16(listener.port),
                               sshPort: UInt16(server.port), user: "max", hostKeyFingerprint: server.hostKeyFingerprint,
                               code: code)
        let model = AppModel()
        // The Mac checks every companion request against the signing key it got at pairing
        let signingKey = try #require(model.companionKey)
        companion.update { $0.trustedPhone = .init(phoneID: key.phoneID, publicKey: signingKey.publicKey) }
        let steps = Steps()
        let mac = try await model.pair(with: link) { steps.all.append($0) }
        #expect(listener.requests.first?.sign == signingKey.publicKey.base64EncodedString())
        // The dead first address (TEST-NET) doesn't hold pairing up: the addresses are tried at once.
        #expect(ContinuousClock.now - started < .seconds(4))

        // Pairing: the proof checked out, the Mac's key was pinned, the steps were reported
        #expect(listener.requests.first?.key == key.publicKey)
        #expect(mac.hostKey == server.hostKeyLine)
        #expect(mac.hostKeyFingerprint == server.hostKeyFingerprint)
        #expect(mac.lastHost == "127.0.0.1")
        #expect(steps.all.first == .contactingMac)
        #expect(steps.all.contains(.checkingKey))
        #expect(ConfigStore.loadMacs().first?.id == mac.id)

        // The model connects by itself (pinned key) and starts the companion
        let connection = try #require(model.connection)
        try await waitUntil { connection.companionState == .ready }
        #expect(connection.state == .connected(host: "127.0.0.1"))
        #expect(connection.hello?.mac == "Max’s MacBook Pro")
        #expect(connection.workspace?.state == .open)

        // A sign-in request comes up as the sheet; the answer reaches the Mac
        companion.emit(.signIn(SignInRequest(id: "e2e", agent: "Claude Code", host: "github.com", purpose: "Push",
                                             expires: Date().addingTimeInterval(120))))
        try await waitUntil { model.presentedSignIn?.id == "e2e" }
        try await connection.answerSignIn(request: "e2e", host: "github.com", username: "max", password: "geheim", totp: "123456")
        #expect(companion.received.last?.fields["password"] == .string("geheim"))
        #expect(companion.received.last?.fields["totp"] == .string("123456"))
        companion.emit(.signInClosed(request: "e2e", result: .filled))
        try await waitUntil { model.signInResults["e2e"] == .filled }

        // One of the person's Bitwarden logins: the answer names it, no password leaves the iPhone
        companion.emit(.signIn(SignInRequest(id: "e2e-bw", agent: "Claude Code", host: "github.com", purpose: "Push",
                                             expires: Date().addingTimeInterval(120),
                                             logins: [BitwardenLogin(id: "b1", name: "GitHub", username: "max", hasCode: true)],
                                             bitwarden: .unlocked)))
        try await waitUntil { model.signIns.contains { $0.id == "e2e-bw" && $0.logins.count == 1 } }
        try await connection.answerSignIn(request: "e2e-bw", host: "github.com", login: "b1")
        #expect(companion.received.last?.fields["login"] == .string("b1"))
        #expect(companion.received.last?.fields["password"] == nil)

        // A one-time code: only the code goes out
        companion.emit(.signIn(SignInRequest(id: "e2e-code", agent: "Claude Code", host: "github.com", purpose: "2FA",
                                             expires: nil, field: .code)))
        try await waitUntil { model.signIns.contains { $0.id == "e2e-code" && $0.field == .code } }
        try await connection.answerSignInCode(request: "e2e-code", host: "github.com", code: "246810")
        #expect(companion.received.last?.fields["totp"] == .string("246810"))
        #expect(companion.received.last?.fields["password"] == nil)

        // Opening the workspace needs the person
        companion.emit(.approval(ApprovalRequest(id: "e2e-open", agent: "Codex", purpose: "Rechnungen", minutes: 15,
                                                 expires: nil)))
        try await waitUntil { model.approvals.contains { $0.id == "e2e-open" } }
        try await connection.answerApproval(request: "e2e-open", allowed: true)
        #expect(companion.received.last?.op == "approval.answer")
        #expect(companion.received.last?.fields["allowed"] == .bool(true))

        // The Mac app is away for a moment, then back
        companion.emit(.mac(state: "unavailable", detail: "aOS isn't running"))
        try await waitUntil { connection.macAppProblem == "aOS isn't running" }
        companion.emit(.mac(state: "available", detail: ""))
        try await waitUntil { connection.macAppProblem == nil }

        // The workspace screen: Open Screen Sharing's session connects to a loopback listener whose connections go
        // through the SSH connection (direct-tcpip) to the workspace's screen sharing, with Apple's account login
        let screen = model.workspaceScreen
        // The iPhone's picture area (iPhone 17 Pro upright, without the top safe area): the workspace takes its shape
        let upright = ScreenArea(points: CGSize(width: 402, height: 812), screenScale: 3, resolutionScale: 1)
        await screen.start(mac: connection, login: nil, options: ScreenOptions(), area: upright)
        #expect(screen.phase == .running)
        // Its login came sealed to a one-time key the request carried (and signed)
        #expect(companion.received.contains { $0.op == "screen" && $0.fields["reply"]?.string?.count == 88 })
        #expect(screen.route?.targetHost == "127.0.0.1" && screen.route?.targetPort == rfb.port)
        #expect(screen.route?.login == .account(username: "aos", password: "pw"))
        // ... asked for before the first picture, so it comes in the iPhone's shape (sized as Open Screen Sharing
        // sizes the Mac's virtual display)
        #expect(companion.received.contains { $0.op == "display" && $0.fields["text"] == .string("1050x2120@2") })
        #expect(screen.displayRequest == DisplayRequest(width: 1050, height: 2120, scale: 2))
        let client = try #require(screen.client)
        client.start()  // the session's view does this when it appears
        try await waitUntil(timeout: .seconds(30)) { client.state == .connected }
        // The server got the sealed login, through the tunnel; the session is plain TCP (no high performance UDP)
        #expect(rfb.log.receivedLogins.first?.username == "aos")
        #expect(rfb.log.receivedLogins.first?.password == "pw")
        #expect(screen.localPort != nil && screen.localPort != UInt16(rfb.port))
        #expect(screen.path == .tunnel && !client.usesHighPerformance && client.picturesFollowWindow)
        try await waitUntil(timeout: .seconds(10)) { rfb.log.updateCount > 0 }
        screen.stop()
        #expect(screen.phase == .idle && screen.client == nil)
        // Stopping gives the workspace its own size back
        try await waitUntil { companion.received.last?.op == "display" && companion.received.last?.fields["text"] == .string("reset") }

        // The Mac's own screen with an account it refuses: the session ends and the login form comes back
        let displayRequests = companion.received.filter { $0.op == "display" }.count
        let macScreen = model.macScreen
        let sideways = ScreenArea(points: CGSize(width: 750, height: 402), screenScale: 3, resolutionScale: 1)
        await macScreen.start(mac: connection, login: .init(username: "max", password: "falsch"), options: ScreenOptions(),
                              area: sideways)
        #expect(macScreen.route?.targetPort == macRFB.port && macScreen.route?.followsWindowShape == false)
        try #require(macScreen.client).start()
        try await waitUntil(timeout: .seconds(30)) { macScreen.phase == .needsLogin }
        #expect(macScreen.loginProblem != nil)
        #expect(macRFB.log.receivedLogins.first?.password == "falsch")
        // ... and with the right one it connects
        await macScreen.start(mac: connection, login: .init(username: "max", password: "richtig"), options: ScreenOptions(),
                              area: sideways)
        let macClient = try #require(macScreen.client)
        macClient.start()
        try await waitUntil(timeout: .seconds(30)) { macClient.state == .connected }
        // The test's SSH connection reaches 127.0.0.1: no direct path, so through the tunnel in the Mac's own size
        #expect(macScreen.path == .tunnel && macScreen.tunnelReason == .noAddress && !macClient.usesHighPerformance)
        // (no display requests for the Mac: its virtual display is Open Screen Sharing's, on the direct path)
        #expect(companion.received.filter { $0.op == "display" }.count == displayRequests)
        macScreen.stop()

        // The Mac in the iPhone's size on the direct path (here its screen sharing server itself on 127.0.0.1, its key
        // known from the session through SSH): high performance with the virtual display. This server offers none, so
        // the tunnel takes over; the login is the one of this connect: one Face ID for the tap, none for the tunnel,
        // none for coming back from the background.
        let savedCandidate = ScreenSession.directCandidate, savedPort = ScreenSession.directPort
        let savedUnlock = ScreenSession.unlockLogin
        defer {
            ScreenSession.directCandidate = savedCandidate
            ScreenSession.directPort = savedPort
            ScreenSession.unlockLogin = savedUnlock
        }
        ScreenSession.directCandidate = { _, _ in .address("127.0.0.1") }
        ScreenSession.directPort = macRFB.port
        final class Asks { var count = 0 }
        let asks = Asks()
        ScreenSession.unlockLogin = { _ in
            asks.count += 1
            return .init(username: "max", password: "richtig")
        }
        let loginsBefore = macRFB.log.receivedLogins.count
        await macScreen.connect(mac: connection, options: ScreenOptions(), area: sideways)
        #expect(asks.count == 1)
        #expect(macScreen.path == .direct(host: "127.0.0.1", network: .localNetwork))
        let direct = try #require(macScreen.client)
        #expect(direct.usesHighPerformance)
        direct.start()
        try await waitUntil(timeout: .seconds(30)) { macScreen.path == .tunnel }
        #expect(macScreen.tunnelReason == .noHighPerformance)
        let tunneled = try #require(macScreen.client)
        #expect(tunneled !== direct && !tunneled.usesHighPerformance)
        tunneled.start()
        try await waitUntil(timeout: .seconds(30)) { tunneled.state == .connected }
        // Both signed in with the same login: directly, then through SSH
        #expect(macRFB.log.receivedLogins.dropFirst(loginsBefore).map(\.password) == ["richtig", "richtig"])
        // The app in the background for a while: the session lets go, and comes back with the app
        macScreen.pause()
        #expect(macScreen.phase == .paused && macScreen.client == nil)
        await macScreen.resume(with: connection)
        let resumed = try #require(macScreen.client)
        resumed.start()
        try await waitUntil(timeout: .seconds(30)) { resumed.state == .connected }
        // ... still the one Face ID; the Mac without high performance goes straight through SSH now
        #expect(asks.count == 1 && macScreen.path == .tunnel)
        macScreen.stop()
        // A new tap is a new connect: Face ID again
        await macScreen.connect(mac: connection, options: ScreenOptions(matchesPhone: false), area: sideways)
        #expect(asks.count == 2 && macScreen.path == .tunnel && macScreen.phase == .running)
        macScreen.stop()

        // The Mac no longer has this iPhone's key (removed there, or paired before signing keys): when the
        // subscription ends, subscribing again gets "pair again", and the Mac card says so
        companion.update { $0.trustedPhone = .init(phoneID: "000000000000", publicKey: signingKey.publicKey) }
        companion.emit(.subscriptionEnded)
        try await waitUntil { connection.companionState == .needsPairing }

        // Unpairing forgets the Mac
        model.unpair(mac)
        #expect(!ConfigStore.loadMacs().contains { $0.id == mac.id })
        #expect(model.connection == nil || model.connection?.mac.id != mac.id)
    }
}

/// Waits for a condition on the main actor, polling.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
