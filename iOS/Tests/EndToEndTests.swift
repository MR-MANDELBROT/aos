import Foundation
import Testing
@testable import Annex

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
        let rfb = try await FakeRFBServer.start(width: 80, height: 50)
        let companion = MockCompanionServer(keepsSecrets: true)
        companion.update { $0.screens[.workspace] = ScreenEndpoint(host: "127.0.0.1", port: UInt16(rfb.port),
                                                                   username: "annex", password: "pw") }
        let server = try await TestSSHServer.start(allowedKey: key, companion: companion)
        let code = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let listener = try await FakePairingListener.start(code: code, behavior: .accept(user: "max",
                                                                                     companion: TestSSHServer.companionPath))
        let previousMacs = ConfigStore.loadMacs()
        defer {
            try? ConfigStore.saveMacs(previousMacs)
            Task { await listener.stop(); await server.stop(); await rfb.stop() }
        }

        let link = PairingLink(macName: "Test Mac", hosts: ["192.0.2.1", "127.0.0.1"], pairingPort: UInt16(listener.port),
                               sshPort: UInt16(server.port), user: "max", hostKeyFingerprint: server.hostKeyFingerprint,
                               code: code)
        let model = AppModel()
        let steps = Steps()
        let mac = try await model.pair(with: link) { steps.all.append($0) }
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
        try await connection.answerSignIn(request: "e2e", username: "max", password: "geheim", totp: "123456")
        #expect(companion.received.last?.fields["password"] == .string("geheim"))
        #expect(companion.received.last?.fields["totp"] == .string("123456"))
        companion.emit(.signInClosed(request: "e2e", result: .filled))
        try await waitUntil { model.signInResults["e2e"] == .filled }

        // A one-time code: only the code goes out
        companion.emit(.signIn(SignInRequest(id: "e2e-code", agent: "Claude Code", host: "github.com", purpose: "2FA",
                                             expires: nil, field: .code)))
        try await waitUntil { model.signIns.contains { $0.id == "e2e-code" && $0.field == .code } }
        try await connection.answerSignInCode(request: "e2e-code", code: "246810")
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
        companion.emit(.mac(state: "unavailable", detail: "Annex isn't running"))
        try await waitUntil { connection.macAppProblem == "Annex isn't running" }
        companion.emit(.mac(state: "available", detail: ""))
        try await waitUntil { connection.macAppProblem == nil }

        // The workspace screen through the SSH connection, and a click on it
        let screen = model.workspaceScreen
        await screen.start(mac: connection, login: nil, interval: 0.02)
        try await waitUntil { screen.phase == .live }
        #expect(screen.size == CGSize(width: 80, height: 50))
        screen.click(at: CGPoint(x: 30, y: 20))
        try await waitUntil { rfb.log.pointerEvents.contains { $0.buttons == 1 && $0.x == 30 && $0.y == 20 } }
        screen.type("Hi")
        try await waitUntil { rfb.log.keyEvents.filter(\.down).map(\.keysym) == [0xffe1, 0x48, 0x69] }
        // Beyond ASCII the workspace types it itself (companion "type"), in order after the keys before it
        screen.type("Grüße")
        try await waitUntil { companion.received.last?.op == "type" }
        #expect(companion.received.last?.fields["text"] == .string("Grüße"))
        #expect(rfb.log.keyEvents.filter(\.down).count == 3)
        screen.stop()

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
