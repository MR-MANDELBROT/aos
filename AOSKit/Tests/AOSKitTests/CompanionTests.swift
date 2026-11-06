import CryptoKit
@testable import AOSKit
import XCTest

final class PairingTests: XCTestCase {
    let code = Data((0..<16).map { UInt8($0) })
    let key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEZ2ad7Xe3RTt8RWyZXZXSRjmFHWU3HbKQ+ZKAyzzSs0+4WNOVPPDqcZ3pfMjxNi3b1A8bYFw3ODJjbXzhBRsqU="

    func proof(_ key: String, _ device: String, code: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data((key + "\n" + device).utf8), using: SymmetricKey(data: code))
        return Data(mac).base64EncodedString()
    }

    func request(device: String = "Max’ iPhone", key: String? = nil, proof p: String? = nil) -> Data {
        let k = key ?? self.key
        let o: [String: Any] = ["v": 1, "device": device, "key": k, "proof": p ?? proof(k, device, code: code)]
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testValidRequest() {
        guard case .success(let r) = PairingRequest.verify(request(), code: code) else { return XCTFail() }
        XCTAssertEqual(r.device, "Max’ iPhone")
        XCTAssertEqual(r.id.count, 12)
        XCTAssertEqual(r.key, key)
    }

    func testWrongCodeAndTampering() {
        var wrong = code; wrong[0] ^= 1
        guard case .failure(let reason) = PairingRequest.verify(request(proof: proof(key, "Max’ iPhone", code: wrong)), code: code)
        else { return XCTFail() }
        XCTAssertEqual(reason, "wrong code")
        // The device name is covered by the proof
        let tampered = try! JSONSerialization.data(withJSONObject: ["v": 1, "device": "Other", "key": key,
                                                                    "proof": proof(key, "Max’ iPhone", code: code)])
        guard case .failure = PairingRequest.verify(tampered, code: code) else { return XCTFail() }
    }

    func testKeyBlobMustMatchItsType() {
        // An ed25519 blob announced as ecdsa is refused
        let ed = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        guard case .failure = PairingRequest.verify(request(key: "ecdsa-sha2-nistp256 " + ed), code: code) else { return XCTFail() }
        guard case .success = PairingRequest.verify(request(key: "ssh-ed25519 " + ed), code: code) else { return XCTFail() }
        // A line break or a third part can't sneak in
        guard case .failure = PairingRequest.verify(request(key: key + "\nssh-rsa AAAA"), code: code) else { return XCTFail() }
        guard case .failure = PairingRequest.verify(request(key: key + " extra"), code: code) else { return XCTFail() }
    }

    func testProofReferenceVectorFromThePhone() {
        // The iPhone app's reference vector (iOS/NOTES.md): same proof on both sides
        let c = Data((0..<16).map { UInt8($0) })
        let k = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
        XCTAssertEqual(proof(k, "Max’s iPhone", code: c), "mrui6J5uTrdDd7yaEdlJQU6kWIO77PVkB04oYtW2SAQ=")
    }

    func testUnsupportedKey() {
        let rsa = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7"
        guard case .failure(let reason) = PairingRequest.verify(request(key: rsa), code: code) else { return XCTFail() }
        XCTAssertEqual(reason, "unsupported key")
    }

    func testAuthorizedKeysFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aos-ak-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("authorized_keys")
        let keys = AuthorizedKeys(url: file)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting someone@laptop".write(to: file, atomically: true, encoding: .utf8)
        try keys.add(key: key, id: "abcdef123456", name: "Max’ iPhone; rm -rf /")
        try keys.add(key: key, id: "abcdef123456", name: "Max’ iPhone")  // again: still one line
        let devices = keys.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "abcdef123456")
        XCTAssertEqual(devices.first?.name, "Max’ iPhone")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("someone@laptop"), "other keys stay")
        XCTAssertTrue(text.contains("no-agent-forwarding,no-X11-forwarding ecdsa-sha2-nistp256"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try keys.remove(id: "abcdef123456")
        XCTAssertTrue(keys.devices().isEmpty)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("someone@laptop"))
    }

    func testAuthorizedKeysKeepsOtherBytesAndLinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aos-ak2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A line that isn't UTF-8 (a Latin-1 comment) stays byte for byte
        let real = dir.appendingPathComponent("real_keys")
        var original = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld J".utf8)
        original.append(0xF6)  // ö in Latin-1
        original.append(contentsOf: Array("rg@box\n".utf8))
        try original.write(to: real)
        // authorized_keys is a link to it (dotfiles): the link stays, the real file changes
        let link = dir.appendingPathComponent("authorized_keys")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let keys = AuthorizedKeys(url: link)
        try keys.add(key: key, id: "abcdef123456", name: "iPhone")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path)
        let after = try Data(contentsOf: real)
        XCTAssertTrue(after.starts(with: original), "the old line is unchanged")
        XCTAssertEqual(keys.devices().map(\.id), ["abcdef123456"])
        try keys.remove(id: "abcdef123456")
        XCTAssertEqual(try Data(contentsOf: real), original)

        // A file that exists but can't be read: nothing is written
        let locked = dir.appendingPathComponent("locked")
        try Data("ssh-ed25519 AAAA keep\n".utf8).write(to: locked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        if getuid() != 0 {
            XCTAssertThrowsError(try AuthorizedKeys(url: locked).add(key: key, id: "abcdef123456", name: "iPhone"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
            XCTAssertEqual(try String(contentsOf: locked, encoding: .utf8), "ssh-ed25519 AAAA keep\n")
        }
    }

    func testAnswerAuthenticationVectorFromThePhone() {
        // The same vector as the iPhone's tests (SSHIntegrationTests.answerChecks)
        let mac = PairingSession.answerAuthentication(code: Data(0..<16), user: "max",
                                                      companion: "/Applications/aOS.app/Contents/MacOS/aos-companion")
        XCTAssertEqual(mac.base64EncodedString(), "0jxhZL+aq9pEAtFLHRsylSojkicfFjA8AE3G/gHWyic=")
    }

    func testHostKeyFingerprintMatchesSSHKeygen() throws {
        guard let mine = MacSSH.hostKeyFingerprint() else { throw XCTSkip("no ed25519 host key on this Mac") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-lf", "/etc/ssh/ssh_host_ed25519_key.pub"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text.split(separator: " ").dropFirst().first.map(String.init), mine)
    }

    @MainActor
    func testPairingURL() {
        let session = PairingSession(keys: AuthorizedKeys(url: URL(fileURLWithPath: "/dev/null")))
        let url = session.makeURL(port: 50123, fingerprint: "SHA256:ab+c/d=")
        XCTAssertTrue(url.contains("k=SHA256%3Aab%2Bc%2Fd%3D"), url)
        let c = URLComponents(string: url)!
        XCTAssertEqual(c.scheme, "aos-pair")
        XCTAssertEqual(c.host, "v1")
        let items = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["p"], "50123")
        XCTAssertEqual(items["k"], "SHA256:ab+c/d=", "+ / = in the fingerprint survive")
        XCTAssertEqual(items["s"], "22")
        let codeText = items["c"]!
        XCTAssertFalse(codeText.contains("=") || codeText.contains("+") || codeText.contains("/"))
        var b64 = codeText.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        XCTAssertEqual(Data(base64Encoded: b64)?.count, 16)
    }
}

final class KeeperTests: XCTestCase {
    func conversation(_ id: String, origin: String = "claude-desktop", hoursAgo: Double = 1, rc: Bool = true,
                      archived: Bool = false, cwd: String = "/tmp") -> ClaudeConversation {
        ClaudeConversation(id: id, cwd: cwd, title: id, lastActivity: Date().addingTimeInterval(-hoursAgo * 3600),
                           usedRemoteControl: rc, startedIn: origin,
                           desktop: origin == "claude-desktop" ? .init(archived: archived, scheduled: false,
                                                                       permissionMode: "auto",
                                                                       remoteControlTurnedOff: false, title: nil) : nil)
    }

    func testSelection() {
        var s = AgentSettings()
        s.keepReachable = true
        s.keepHours = 24
        s.keepMax = 3
        let list = [
            conversation("app-recent"),
            conversation("app-old", hoursAgo: 30),
            conversation("terminal", origin: "cli"),
            conversation("sdk", origin: "sdk-cli"),
            conversation("archived", archived: true),
            conversation("no-rc", rc: false),
            conversation("own", cwd: "/aOS/Session"),
            conversation("app-2", hoursAgo: 2),
            conversation("app-3", hoursAgo: 3),
            conversation("app-4", hoursAgo: 4),
        ]
        var chosen = SessionKeeper.select(list, settings: s, exclude: "/aOS/Session").map(\.0.id)
        XCTAssertEqual(chosen, ["app-recent", "app-2", "app-3"], "only the Claude app's, recent, with RC, at most 3")

        s.keptConversations = ["terminal"]
        s.skippedConversations = ["app-2"]
        chosen = SessionKeeper.select(list, settings: s, exclude: "/aOS/Session").map(\.0.id)
        XCTAssertEqual(chosen, ["terminal", "app-recent", "app-3"], "pinned first, skipped never")

        s.keptConversations = ["archived"]
        chosen = SessionKeeper.select(list, settings: s, exclude: "/aOS/Session").map(\.0.id)
        XCTAssertFalse(chosen.contains("archived"), "archived in the app stays archived even when pinned")

        s.keepAutomatic = false
        s.keptConversations = ["app-old"]
        XCTAssertEqual(SessionKeeper.select(list, settings: s, exclude: "/x").map(\.0.id), ["app-old"])
    }

    func testReadingATranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aos-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let lines: [[String: Any]] = [
            ["type": "user", "sessionId": id, "cwd": "/Users/x/project", "entrypoint": "claude-desktop"],
            ["type": "assistant", "sessionId": id, "cwd": "/Users/x/project/sub"],
            ["type": "ai-title", "sessionId": id, "aiTitle": "First title"],
            ["type": "bridge-session", "sessionId": id, "bridgeSessionId": "cse_1"],
            ["type": "custom-title", "sessionId": id, "customTitle": "Named by the user"],
            ["type": "custom-title", "sessionId": "other", "customTitle": "Not this one"],
        ]
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let file = dir.appendingPathComponent("\(id).jsonl")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(ClaudeConversations.read(file, modified: Date()))
        XCTAssertEqual(c.cwd, "/Users/x/project", "the folder it started in")
        XCTAssertEqual(c.title, "Named by the user")
        XCTAssertTrue(c.usedRemoteControl)
        XCTAssertEqual(c.startedIn, "claude-desktop")
    }
}

final class CompanionHubTests: XCTestCase {
    @MainActor
    func testOpenQuestionsAndLongPoll() async {
        let hub = CompanionHub()
        hub.post(CompanionEvent(event: "workspace", state: "open"))
        hub.post(CompanionEvent(event: "signin", request: "r1", agent: "Claude Code", host: "example.com"))
        // A phone that just connected gets the open question, not the history
        var (events, seq) = await hub.events(since: 0, timeout: 1)
        XCTAssertEqual(events.map(\.event), ["signin"])
        XCTAssertEqual(seq, 2)
        // A long poll ends as soon as something happens
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            hub.post(CompanionEvent(event: "signin.closed", request: "r1", result: "filled"))
        }
        let start = Date()
        (events, seq) = await hub.events(since: 2, timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(events.map(\.event), ["signin.closed"])
        XCTAssertTrue(hub.open.isEmpty)
        // Nothing new: an empty answer after the timeout
        (events, _) = await hub.events(since: seq, timeout: 0.2)
        XCTAssertTrue(events.isEmpty)
    }
}
