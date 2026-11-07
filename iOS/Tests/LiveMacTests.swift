import Foundation
import Testing
@testable import aOS

/// Against a real Mac side: aOS's pairing listener (`aosctl pair-test`), an sshd, the real `aos-companion` and
/// the aOS engine with an open workspace. Runs only when `AOS_LIVE_LINK` holds a pairing link (pass it to
/// xcodebuild as `TEST_RUNNER_AOS_LIVE_LINK`). An agent on the Mac calls `sign_in` meanwhile; this test answers it
/// with the test values from `AOS_LIVE_USER` and `AOS_LIVE_PASSWORD` (a test page in the workspace, never a real
/// account). The workspace's screen connects through the SSH connection with Open Screen Sharing's session.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AOS_LIVE_LINK"] != nil))
struct LiveMacTests {
    let env = ProcessInfo.processInfo.environment

    @Test func pairAndUseTheRealMac() async throws {
        let link = try PairingLink(try #require(env["AOS_LIVE_LINK"]))
        let previousMacs = ConfigStore.loadMacs()
        defer { try? ConfigStore.saveMacs(previousMacs) }

        // Pairing with the real listener: the Mac checks the proof and writes the key
        let model = AppModel()
        let previousName = model.deviceName
        defer { model.deviceName = previousName }
        model.deviceName = "aOS Live Test"
        let mac = try await model.pair(with: link) { _ in }
        #expect(mac.hostKeyFingerprint == link.hostKeyFingerprint)

        // The companion on the Mac answers
        let connection = try #require(model.connection)
        try await waitUntil(timeout: .seconds(30)) { connection.companionState == .ready }
        let hello = try #require(connection.hello)
        print("LIVE hello: mac=\(hello.mac) aos=\(hello.aos)")
        print("LIVE workspace: \(String(describing: connection.workspace?.state))")

        // A terminal on the Mac, in the same SSH connection
        let ssh = try #require(connection.ssh)
        let shell = try await ssh.shell(columns: 80, rows: 24)
        try await shell.write(Data("echo aos-live-$((6*7))\n".utf8))
        var seen = ""
        let terminalDeadline = ContinuousClock.now + .seconds(15)
        for try await chunk in shell.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("aos-live-42") || ContinuousClock.now > terminalDeadline { break }
        }
        await shell.close()
        #expect(seen.contains("aos-live-42"))
        print("LIVE terminal ok: \(seen.contains("aos-live-42"))")

        // The agent's sign-in request arrives; answered with the test values
        if let user = env["AOS_LIVE_USER"], let password = env["AOS_LIVE_PASSWORD"] {
            try await waitUntil(timeout: .seconds(240)) { model.presentedSignIn != nil }
            let request = try #require(model.presentedSignIn)
            print("LIVE sign-in request: agent=\(request.agent) host=\(request.host) field=\(request.field.rawValue) purpose=\(request.purpose)")
            try await connection.answerSignIn(request: request.id, host: request.host, username: user, password: password, totp: nil)
            try await waitUntil(timeout: .seconds(90)) { model.signInResults[request.id] != nil }
            print("LIVE sign-in result: \(String(describing: model.signInResults[request.id]))")
            #expect(model.signInResults[request.id] == .filled)
        }

        // The workspace screen through the SSH connection (direct-tcpip to the workspace's screen sharing), with
        // Open Screen Sharing's session and the login the Mac sealed to this iPhone
        let screen = model.workspaceScreen
        await screen.start(mac: connection, login: nil, options: ScreenOptions(), area: CGSize(width: 402, height: 812))
        let client = try #require(screen.client)
        client.start()
        try await waitUntil(timeout: .seconds(40)) { client.state == .connected }
        print("LIVE workspace screen: connected, Apple's screen sharing: \(client.speaksApple), display \(String(describing: screen.displayRequest))")
        screen.stop()

        model.unpair(mac)
    }
}
