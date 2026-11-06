import AOSRFB
import CoreGraphics
import Foundation
import Testing
@testable import aOS

/// The SSH paths end to end against servers inside the test process (see Support/TestServers.swift).
@Suite(.serialized)
struct SSHIntegrationTests {
    let key = DeviceKey.ephemeral()

    @Test func pairedLoginWithTheFingerprintFromTheCode() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await SSHConnection.connect(
            hosts: ["127.0.0.1"], port: server.port, login: SSHLogin(username: "max", key: key),
            hostKey: .fingerprint(server.hostKeyFingerprint))
        #expect(connection.host == "127.0.0.1")
        #expect(connection.hostKey == server.hostKeyLine)
        #expect(connection.hostKeyFingerprint == server.hostKeyFingerprint)
        await connection.close()
    }

    @Test func aDifferentHostKeyIsRefused() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        await #expect(throws: SSHConnectError.hostKeyMismatch(host: "127.0.0.1", presented: server.hostKeyFingerprint)) {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                login: SSHLogin(username: "max", key: key),
                                                hostKey: .fingerprint(Vectors.ed25519Fingerprint))
        }
        // Pinned keys too
        await #expect(throws: SSHConnectError.self) {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                login: SSHLogin(username: "max", key: key),
                                                hostKey: .pinned(Vectors.ed25519Key))
        }
    }

    @Test func unknownHostsStopAtTheKey() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        do {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                login: SSHLogin(username: "max", key: key), hostKey: .askFirst)
            Issue.record("connected without asking")
        } catch let SSHConnectError.unknownHostKey(host, presented, fingerprint) {
            #expect(host == "127.0.0.1")
            #expect(presented == server.hostKeyLine)
            #expect(fingerprint == server.hostKeyFingerprint)
            // Trusting it: the next connection pins it
            let connection = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                             login: SSHLogin(username: "max", key: key),
                                                             hostKey: .pinned(presented))
            await connection.close()
        }
    }

    @Test func keysAndPasswordsTheServerDoesntTakeFailTheLogin() async throws {
        let server = try await TestSSHServer.start(allowedKey: nil, password: "correct horse")
        defer { Task { await server.stop() } }
        await #expect(throws: SSHConnectError.authenticationFailed(host: "127.0.0.1")) {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                login: SSHLogin(username: "max", key: key),
                                                hostKey: .pinned(server.hostKeyLine))
        }
        await #expect(throws: SSHConnectError.authenticationFailed(host: "127.0.0.1")) {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                login: SSHLogin(username: "max", password: "wrong"),
                                                hostKey: .pinned(server.hostKeyLine))
        }
        let connection = try await SSHConnection.connect(
            hosts: ["127.0.0.1"], port: server.port, login: SSHLogin(username: "max", password: "correct horse"),
            hostKey: .pinned(server.hostKeyLine))
        await connection.close()
    }

    @Test func unreachableAddressesAreSkipped() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let start = Date()
        // 192.0.2.1 is TEST-NET (never answers), "nonexistent.invalid" never resolves
        let connection = try await SSHConnection.connect(
            hosts: ["192.0.2.1", "nonexistent.invalid", "127.0.0.1"], port: server.port,
            login: SSHLogin(username: "max", key: key), hostKey: .pinned(server.hostKeyLine))
        #expect(connection.host == "127.0.0.1")
        #expect(Date().timeIntervalSince(start) < 5)
        await connection.close()

        let closedPort = try await freeLocalPort()
        await #expect(throws: SSHConnectError.self) {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: closedPort,
                                                login: SSHLogin(username: "max", key: key), hostKey: .askFirst,
                                                perHostTimeout: 2)
        }
    }

    @Test func companionOverAnExecChannel() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                         login: SSHLogin(username: "max", key: key),
                                                         hostKey: .pinned(server.hostKeyLine))
        defer { Task { await connection.close() } }
        let channel = try await connection.exec(CompanionCommand.serve(path: TestSSHServer.companionPath))
        let client = CompanionClient(transport: channel)
        await client.start()
        #expect(try await client.hello(app: "0.1.0", device: "Test").mac == "Max’s MacBook Pro")
        #expect(try await client.status().state == .open)
        try await client.subscribe()
        let request = SignInRequest(id: "r9", agent: "Claude Code", host: "github.com", purpose: "Push", expires: nil)
        server.companion.emit(.signIn(request))
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == .signIn(request))
        try await client.answerSignIn(request: "r9", username: "max", password: "p@ss \"w\" ü", totp: "000111")
        let answer = server.companion.received.last
        #expect(answer?.fields["password"] == .string("p@ss \"w\" ü"))
        #expect(server.events == ["exec '/Applications/aOS.app/Contents/MacOS/aos-companion' serve"])
        await client.close()
    }

    @Test func aMissingCompanionIsReported() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                         login: SSHLogin(username: "max", key: key),
                                                         hostKey: .pinned(server.hostKeyLine))
        defer { Task { await connection.close() } }
        let channel = try await connection.exec(CompanionCommand.serve(path: "/nowhere/aos-companion"))
        let client = CompanionClient(transport: channel)
        await client.start()
        await #expect(throws: (any Error).self) { try await client.hello(app: "1", device: "d") }
    }

    @Test func screenThroughTheForwarder() async throws {
        let rfb = try await FakeRFBServer.start(width: 64, height: 48)
        defer { Task { await rfb.stop() } }
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                         login: SSHLogin(username: "max", key: key),
                                                         hostKey: .pinned(server.hostKeyLine))
        defer { Task { await connection.close() } }

        let forwarder = LocalForwarder(connection: connection, targetHost: "127.0.0.1", targetPort: rfb.port)
        let localPort = try await forwarder.start()
        defer { forwarder.stop() }
        #expect(localPort > 0)

        let client = RFBClient(host: "127.0.0.1", port: localPort, username: "", password: "")
        var frames = client.liveFrames(minimumInterval: 0.02).makeAsyncIterator()
        let first: CGImage?
        do {
            first = try await frames.next()
        } catch {
            Issue.record("no picture: \(error); forwarder: \(String(describing: forwarder.lastError)); server: \(server.events)")
            throw error
        }
        #expect(first?.width == 64)
        #expect(first?.height == 48)
        _ = try await frames.next()
        #expect(rfb.log.updateCount >= 2)

        try await client.pointer(x: 10, y: 20, pressed: [.left])
        try await client.pointer(x: 10, y: 20, pressed: [])
        try await client.key(0x61, down: true)
        try await client.key(0x61, down: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rfb.log.pointerEvents.contains { $0.buttons == 1 && $0.x == 10 && $0.y == 20 })
        #expect(rfb.log.keyEvents.map(\.keysym).contains(0x61))
        await client.disconnect()
    }

    @Test func shellInAPseudoTerminal() async throws {
        let server = try await TestSSHServer.start(allowedKey: key)
        defer { Task { await server.stop() } }
        let connection = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: server.port,
                                                         login: SSHLogin(username: "max", key: key),
                                                         hostKey: .pinned(server.hostKeyLine))
        defer { Task { await connection.close() } }
        let shell = try await connection.shell(columns: 80, rows: 24)
        var output = Data()
        var iterator = shell.output.makeAsyncIterator()
        while !String(decoding: output, as: UTF8.self).hasSuffix("$ ") {
            output.append(try await iterator.next() ?? Data())
        }
        try await shell.write(Data("hello ü\r".utf8))
        var echoed = Data()
        while echoed.count < Data("hello ü\r".utf8).count { echoed.append(try await iterator.next() ?? Data()) }
        #expect(String(decoding: echoed, as: UTF8.self) == "hello ü\r")
        try await shell.resize(columns: 100, rows: 30)
        try await shell.write(Data("exit\r".utf8))
        while let chunk = try await iterator.next() { _ = chunk }  // ends when the shell exits
        #expect(server.events.contains("pty xterm-256color 80x24"))
        #expect(server.events.contains("shell"))
        #expect(server.events.contains("size 100x30"))
    }
}

@Suite(.serialized)
struct PairingClientTests {
    let link = { (port: Int) in
        PairingLink(macName: "Test Mac", hosts: ["127.0.0.1"], pairingPort: UInt16(port), user: "max",
                    hostKeyFingerprint: Vectors.ed25519Fingerprint, code: Vectors.code)
    }

    @Test func pairsWithAValidProof() async throws {
        let listener = try await FakePairingListener.start(code: Vectors.code,
                                                           behavior: .accept(user: "max", companion: "/x/aos-companion"))
        defer { Task { await listener.stop() } }
        let request = PairingRequest(device: "Test iPhone", key: Vectors.p256Key, code: Vectors.code)
        let (response, host) = try await PairingClient.send(request, link: link(listener.port))
        #expect(response.ok)
        #expect(response.user == "max")
        #expect(response.companion == "/x/aos-companion")
        #expect(host == "127.0.0.1")
        #expect(listener.requests == [request])
    }

    @Test func aWrongCodeIsRefused() async throws {
        let listener = try await FakePairingListener.start(code: Data(repeating: 7, count: 16),
                                                           behavior: .accept(user: "max", companion: "/x"))
        defer { Task { await listener.stop() } }
        let request = PairingRequest(device: "Test iPhone", key: Vectors.p256Key, code: Vectors.code)
        await #expect(throws: PairingClient.Failure.refused("wrong proof")) {
            _ = try await PairingClient.send(request, link: link(listener.port))
        }
    }

    @Test func aChangedAnswerIsRejected() async throws {
        let listener = try await FakePairingListener.start(code: Vectors.code,
                                                           behavior: .tampered(user: "max", companion: "/x/aos-companion"))
        defer { Task { await listener.stop() } }
        let request = PairingRequest(device: "Test iPhone", key: Vectors.p256Key, code: Vectors.code)
        await #expect(throws: PairingClient.Failure.notAuthentic) {
            _ = try await PairingClient.send(request, link: link(listener.port))
        }
    }

    @Test func answerChecks() {
        let code = Vectors.code
        let mac = PairingResponse.authentication(code: code, user: "max", companion: "/Applications/aOS.app/Contents/MacOS/aos-companion")
        var r = PairingResponse(ok: true, user: "max", companion: "/Applications/aOS.app/Contents/MacOS/aos-companion",
                                error: nil, mac: mac.base64EncodedString())
        #expect(r.isAuthentic(code: code))
        r.user = "root"
        #expect(!r.isAuthentic(code: code))
        #expect(!PairingResponse.isPlausible(companion: "/bin/sh"))
        #expect(!PairingResponse.isPlausible(companion: "relative/aos-companion"))
        #expect(!PairingResponse.isPlausible(user: "max; rm"))
        // The reference vector the Mac's tests use too
        #expect(PairingResponse.authentication(code: Data(0..<16), user: "max", companion: "/Applications/aOS.app/Contents/MacOS/aos-companion").base64EncodedString()
                == "0jxhZL+aq9pEAtFLHRsylSojkicfFjA8AE3G/gHWyic=")
    }

    @Test func aClosedListenerAndAHangUp() async throws {
        let hangUp = try await FakePairingListener.start(code: Vectors.code, behavior: .hangUp)
        defer { Task { await hangUp.stop() } }
        let request = PairingRequest(device: "Test iPhone", key: Vectors.p256Key, code: Vectors.code)
        await #expect(throws: PairingClient.Failure.noAnswer) {
            _ = try await PairingClient.send(request, link: link(hangUp.port))
        }
        let closedPort = try await freeLocalPort()
        await #expect(throws: PairingClient.Failure.unreachable) {
            _ = try await PairingClient.send(request, link: link(closedPort), timeout: 2)
        }
    }
}

/// The Mac's real sshd, if Remote Login is on: only its host key is read (like ssh-keyscan); no login is attempted.
struct RealSSHDFingerprintTest {
    @Test func fingerprintMatchesSSHKeygen() async throws {
        guard let line = try? String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8),
              let expected = SSHKeyFormat.fingerprint(openSSHKey: line.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            print("real sshd: host key file not readable here, nothing compared")
            return
        }
        do {
            _ = try await SSHConnection.connect(hosts: ["127.0.0.1"], port: 22,
                                                login: SSHLogin(username: "aos-test-no-login"),
                                                hostKey: .askFirst, perHostTimeout: 3)
            Issue.record("connected without a host key decision")
        } catch let SSHConnectError.unknownHostKey(_, key, fingerprint) {
            #expect(key.hasPrefix("ssh-ed25519 "))
            #expect(fingerprint == expected)
            print("real sshd: presented \(fingerprint), file says \(expected)")
        } catch SSHConnectError.unreachable {
            print("real sshd: port 22 closed, nothing compared")
        }
    }
}
