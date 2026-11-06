import CryptoKit
@testable import AOSKit
import XCTest

/// A paired phone in the tests: its signing key, and requests signed the way the iPhone app signs them.
struct TestPhone {
    var id = "4853150ceae1"
    var name = "Max’ iPhone"
    let key = P256.Signing.PrivateKey()

    var trusted: TrustedPhone {
        TrustedPhone(id: id, name: name, signingKey: key.publicKey.x963Representation,
                     paired: Date(timeIntervalSince1970: 1_793_966_400))
    }

    static func nonce() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The request with a signature over it; `by` signs with another key under this phone's id.
    func sign(_ r: AgentRequest, ts: Int = Int(Date().timeIntervalSince1970), nonce: String = TestPhone.nonce(),
              by other: P256.Signing.PrivateKey? = nil) -> AgentRequest {
        var signed = r
        var auth = CompanionAuth(key: id, ts: ts, nonce: nonce, sig: "")
        let message = CompanionSignature.message(CompanionSignature.fields(for: r, auth: auth))!
        auth.sig = try! (other ?? key).signature(for: message).rawRepresentation.base64EncodedString()
        signed.auth = auth
        return signed
    }
}

final class CompanionSignatureTests: XCTestCase {
    /// The reference vector the iPhone's tests check too (iOS/Tests/ProtocolTests.swift, `SignedRequestTests`).
    func testReferenceVector() throws {
        let fields = CompanionSignature.Fields(op: "signin.answer", key: "4853150ceae1", ts: 1_793_966_400,
                                               nonce: "AAECAwQFBgcICQoLDA0ODw", request: "r1", decision: "login",
                                               login: "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5", host: "github.com")
        let message = try XCTUnwrap(CompanionSignature.message(fields))
        XCTAssertEqual(String(decoding: message, as: UTF8.self), """
            aos-companion-v1
            op=signin.answer
            key=4853150ceae1
            ts=1793966400
            nonce=AAECAwQFBgcICQoLDA0ODw
            request=r1
            decision=login
            login=2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5
            host=github.com
            target=
            data=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        // Signed once with the private key 01 02 ... 20 (ECDSA signatures differ each time; this one stays valid)
        let publicKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded:
            "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q=")))
        XCTAssertEqual(publicKey.x963Representation,
                       try P256.Signing.PrivateKey(rawRepresentation: Data(1...32)).publicKey.x963Representation)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Data(base64Encoded:
            "GFcC/pLIqdTnqSkGq/dgSPzvKwrS+An71RilVLIyBblhUdc88QPnXNY4gvOfxo7ZfiDf4tRnBoFjdtXUhA3AWg==")))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: message))
        var other = fields
        other.login = "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e6"
        XCTAssertFalse(publicKey.isValidSignature(signature, for: try XCTUnwrap(CompanionSignature.message(other))))
    }

    func testDataDigests() {
        // Python: hashlib.sha256(b"username:3:max\npassword:6:geheim\n"), and the 12 UTF-8 bytes of "Grüße 😀"
        XCTAssertEqual(CompanionSignature.dataDigest(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CompanionSignature.dataDigest(username: "max", password: "geheim"),
                       "7f8b51cc0836cd46dc9b0f4cf097aab22db8990f183b3d9b5a0ecf48ab1a6c1f")
        XCTAssertEqual(CompanionSignature.dataDigest(text: "Grüße 😀"),
                       "5ea585c8aefd5374907cd0e73a2ce0bdf2218de624576cad57ae294e322d69f7")
        // Absent and empty differ
        XCTAssertNotEqual(CompanionSignature.dataDigest(totp: ""), CompanionSignature.dataDigest())
    }

    func testDecisions() {
        var r = AgentRequest(id: 1, op: "signin.answer")
        r.login = "x"
        XCTAssertEqual(CompanionSignature.decision(for: r), "login")
        r.decline = true
        XCTAssertEqual(CompanionSignature.decision(for: r), "decline")
        r = AgentRequest(id: 1, op: "signin.answer"); r.username = "max"; r.password = "pw"
        XCTAssertEqual(CompanionSignature.decision(for: r), "fill")
        r = AgentRequest(id: 1, op: "signin.answer"); r.totp = "123456"
        XCTAssertEqual(CompanionSignature.decision(for: r), "code")
        r = AgentRequest(id: 1, op: "approval.answer"); r.allowed = true
        XCTAssertEqual(CompanionSignature.decision(for: r), "allow")
        r.allowed = false
        XCTAssertEqual(CompanionSignature.decision(for: r), "deny")
        XCTAssertEqual(CompanionSignature.decision(for: AgentRequest(id: 1, op: "help.done")), "done")
        XCTAssertEqual(CompanionSignature.decision(for: AgentRequest(id: 1, op: "companion.status")), "")
    }

    func testLineBreaksAreNeverSigned() {
        let fields = CompanionSignature.Fields(op: "help.done", key: "4853150ceae1", ts: 1, nonce: "n", request: "a\nlogin=b")
        XCTAssertNil(CompanionSignature.message(fields))
    }
}

@MainActor
final class CompanionGateTests: XCTestCase {
    let phone = TestPhone()

    func gate(_ phones: [TrustedPhone]? = nil) -> CompanionGate {
        CompanionGate(store: MemoryPhoneKeys(phones ?? [phone.trusted]))
    }

    func answer(login: String = "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5") -> AgentRequest {
        var r = AgentRequest(id: 7, op: "signin.answer")
        r.request = "r1"
        r.host = "github.com"
        r.login = login
        return r
    }

    func refusal(_ result: Result<TrustedPhone, CompanionRefusal>) -> CompanionRefusal? {
        if case .failure(let r) = result { return r }
        return nil
    }

    func testAValidSignatureIsAdmitted() {
        let g = gate()
        guard case .success(let p) = g.admit(phone.sign(answer())) else { return XCTFail() }
        XCTAssertEqual(p, phone.trusted)
        // Every kind of phone request
        var screen = AgentRequest(id: 1, op: "companion.screen"); screen.target = "workspace"
        var type = AgentRequest(id: 2, op: "companion.type"); type.text = "Grüße"
        var approval = AgentRequest(id: 3, op: "approval.answer"); approval.request = "a1"; approval.allowed = true
        var fill = AgentRequest(id: 4, op: "signin.answer"); fill.request = "r2"; fill.host = "a.de"
        fill.username = "max"; fill.password = "p\"w"
        for r in [screen, type, approval, fill, AgentRequest(id: 5, op: "companion.hello"),
                  AgentRequest(id: 6, op: "companion.status"), AgentRequest(id: 7, op: "help.done")] {
            guard case .success = g.admit(phone.sign(r)) else { return XCTFail(r.op) }
        }
    }

    func testAnotherKeyIsRefused() {
        let g = gate()
        let signed = phone.sign(answer(), by: P256.Signing.PrivateKey())
        XCTAssertEqual(refusal(g.admit(signed))?.code, "invalid")
        // A signature that isn't 64 bytes
        var short = phone.sign(answer())
        short.auth?.sig = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertEqual(refusal(g.admit(short))?.code, "invalid")
    }

    func testAReplayIsRefused() {
        let g = gate()
        let signed = phone.sign(answer())
        guard case .success = g.admit(signed) else { return XCTFail() }
        let again = refusal(g.admit(signed))
        XCTAssertEqual(again?.code, "invalid")
        XCTAssertTrue(again?.reason.contains("nonce") == true)
        // The same nonce on another request too
        var other = AgentRequest(id: 8, op: "companion.status")
        other = phone.sign(other, nonce: signed.auth!.nonce)
        XCTAssertNotNil(refusal(g.admit(other)))
    }

    func testStaleAndFutureTimestamps() {
        let g = gate()
        let now = Date(timeIntervalSince1970: 1_793_966_400)
        g.now = { now }
        let t = Int(now.timeIntervalSince1970)
        XCTAssertEqual(refusal(g.admit(phone.sign(answer(), ts: t - 121)))?.code, "clock")
        XCTAssertEqual(refusal(g.admit(phone.sign(answer(), ts: t + 121)))?.code, "clock")
        guard case .success = g.admit(phone.sign(answer(), ts: t - 119)) else { return XCTFail() }
        guard case .success = g.admit(phone.sign(answer(), ts: t + 119)) else { return XCTFail() }
    }

    func testTamperedFieldsAreRefused() {
        let g = gate()
        let changes: [(String, (inout AgentRequest) -> Void)] = [
            ("login", { $0.login = "88888888-8888-4888-8888-888888888888" }),
            ("request", { $0.request = "r2" }),
            ("host", { $0.host = "evil.example" }),
            ("decision", { $0.decline = true }),
            ("password", { $0.password = "mine" }),
            ("op", { $0.op = "approval.answer" }),
            ("target", { $0.target = "workspace" }),
            ("time", { $0.auth?.ts += 1 }),
            ("nonce", { $0.auth?.nonce = TestPhone.nonce() }),
            ("key id", { $0.auth?.key = "000000000000" }),
        ]
        for (what, change) in changes {
            var r = phone.sign(answer())
            change(&r)
            XCTAssertNotNil(refusal(g.admit(r)), what)
        }
    }

    func testUnsignedUnknownAndMalformed() {
        let g = gate()
        let unsigned = refusal(g.admit(answer()))
        XCTAssertEqual(unsigned?.code, "pair-again")
        // A phone paired before signing keys (no key on the Mac): it must pair again
        let stranger = TestPhone(id: "aaaaaaaaaaaa")
        XCTAssertEqual(refusal(g.admit(stranger.sign(answer())))?.code, "pair-again")
        var badNonce = phone.sign(answer()); badNonce.auth?.nonce = "short"
        XCTAssertEqual(refusal(g.admit(badNonce))?.code, "invalid")
        var badID = phone.sign(answer()); badID.auth?.key = "../../etc"
        XCTAssertEqual(refusal(g.admit(badID))?.code, "invalid")
        var lineBreak = answer(); lineBreak.request = "r1\nlogin=x"
        lineBreak.auth = CompanionAuth(key: phone.id, ts: Int(Date().timeIntervalSince1970), nonce: TestPhone.nonce(),
                                       sig: Data(repeating: 0, count: 64).base64EncodedString())
        XCTAssertEqual(refusal(g.admit(lineBreak))?.code, "invalid")
    }

    func testSubscriptionsForEventPolls() throws {
        let store = MemoryPhoneKeys([phone.trusted])
        let g = CompanionGate(store: store)
        var clock = Date()
        g.now = { clock }
        var poll = AgentRequest(id: 1, op: "companion.events")
        // No subscription, or a made-up one
        XCTAssertEqual(refusal(g.admit(poll))?.code, "subscription-ended")
        poll.subscription = "made-up"
        XCTAssertEqual(refusal(g.admit(poll))?.code, "subscription-ended")
        // A signed subscribe gives one
        guard case .success(let p) = g.admit(phone.sign(AgentRequest(id: 2, op: "companion.subscribe"))) else { return XCTFail() }
        poll.subscription = g.subscribe(p)
        XCTAssertGreaterThanOrEqual(poll.subscription?.count ?? 0, 40)
        guard case .success(let polled) = g.admit(poll) else { return XCTFail() }
        XCTAssertEqual(polled.name, phone.name)
        // Polled now and then it stays; unused for 5 minutes it ends
        clock = clock.addingTimeInterval(200)
        guard case .success = g.admit(poll) else { return XCTFail() }
        clock = clock.addingTimeInterval(301)
        XCTAssertEqual(refusal(g.admit(poll))?.code, "subscription-ended")
        // A removed phone's subscription ends at once
        poll.subscription = g.subscribe(p)
        try store.remove(id: phone.id)
        XCTAssertEqual(refusal(g.admit(poll))?.code, "subscription-ended")
    }

    func testMemoryStore() throws {
        let store = MemoryPhoneKeys()
        try store.save(phone.trusted)
        XCTAssertEqual(store.phone(id: phone.id), phone.trusted)
        XCTAssertEqual(store.ids(), [phone.id])
        try store.remove(id: phone.id)
        XCTAssertNil(store.phone(id: phone.id))
    }

    func testKeychainStoreRoundTrip() throws {
        let store = KeychainPhoneKeys(service: "dev.marquart.aos.tests.phonekeys-\(UUID().uuidString)")
        defer { try? store.remove(id: phone.id) }
        do {
            try store.save(phone.trusted)
        } catch {
            throw XCTSkip("no login keychain here: \(error)")
        }
        XCTAssertEqual(store.phone(id: phone.id)?.signingKey, phone.trusted.signingKey)
        XCTAssertEqual(store.ids(), [phone.id])
        XCTAssertNil(store.phone(id: "../x"), "only phone ids are looked up")
        try store.remove(id: phone.id)
        XCTAssertNil(store.phone(id: phone.id))
        XCTAssertEqual(store.ids(), [])
    }

    func testAKeyAnotherProgramWroteDoesntCount() throws {
        // Another program of the user (here Apple's `security` tool) adds an item for "any application": aOS must not
        // trust it, and must not let macOS ask about it either (the read fails at once instead of waiting on a dialog).
        let service = "dev.marquart.aos.tests.phonekeys-\(UUID().uuidString)"
        let json = String(decoding: try JSONEncoder().encode(phone.trusted), as: UTF8.self)
        let add = try Subprocess.runBlocking("/usr/bin/security", ["add-generic-password", "-s", service, "-a", phone.id,
                                                                  "-w", json, "-A"], timeout: 20)
        guard add.status == 0 else { throw XCTSkip("no login keychain here") }
        defer { _ = try? Subprocess.runBlocking("/usr/bin/security", ["delete-generic-password", "-s", service], timeout: 20) }
        let store = KeychainPhoneKeys(service: service)
        let start = Date()
        XCTAssertNil(store.phone(id: phone.id))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        let gate = CompanionGate(store: store)
        XCTAssertEqual(refusal(gate.admit(phone.sign(answer())))?.code, "pair-again")
    }
}

/// The app's side: phone requests pass the gate first, the agent's don't need it.
final class CompanionControllerTests: XCTestCase {
    @MainActor
    func controller(_ phones: [TrustedPhone]) throws -> (WorkspaceController, LogBox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-ctl-\(UUID().uuidString)")
        let paths = Paths(root: root)
        try paths.prepare()
        let c = WorkspaceController(paths: paths, bitwarden: BitwardenVault(paths: paths, store: MemorySessionStore()),
                                    phoneKeys: MemoryPhoneKeys(phones))
        let log = LogBox()
        c.log = { log.lines.append($0) }
        return (c, log)
    }

    final class LogBox: @unchecked Sendable { var lines: [String] = [] }

    @MainActor
    func testUnsignedRequestsAreRefusedAndLogged() async throws {
        let phone = TestPhone()
        let (c, log) = try controller([phone.trusted])
        var answered: [String] = []
        c.onCompanionAnswer = { r in answered.append("\(r.op) \(r.device ?? "")"); return nil }
        var approval = AgentRequest(id: 1, op: "approval.answer")
        approval.request = "a1"
        approval.allowed = true
        approval.device = "Forged name"
        let refused = await c.handle(approval)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.code, "pair-again")
        XCTAssertTrue(answered.isEmpty)
        XCTAssertEqual(log.lines.last, "iPhone request approval.answer refused: not signed")
        // Signed, it reaches the app, with the paired phone's name (not the one the request claims)
        let ok = await c.handle(phone.sign(approval))
        XCTAssertTrue(ok.ok, ok.text)
        XCTAssertEqual(answered, ["approval.answer Max’ iPhone"])
        // The screen's credentials and the events need it too
        let screen = await c.handle(AgentRequest(id: 2, op: "companion.screen"))
        XCTAssertFalse(screen.ok)
        let events = await c.handle(AgentRequest(id: 3, op: "companion.events"))
        XCTAssertEqual(events.code, "subscription-ended")
        // The agent's own operations stay as they are
        let status = await c.handle(AgentRequest(id: 4, op: "status"))
        XCTAssertTrue(status.ok)
    }

    @MainActor
    func testSubscribeThenPollEvents() async throws {
        let phone = TestPhone()
        let (c, _) = try controller([phone.trusted])
        c.companion.post(CompanionEvent(event: "signin", request: "r1", agent: "Claude Code", host: "github.com"))
        let subscribed = await c.handle(phone.sign(AgentRequest(id: 1, op: "companion.subscribe")))
        XCTAssertTrue(subscribed.ok)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(subscribed.text.utf8)) as? [String: Any])?["subscription"] as? String)
        var poll = AgentRequest(id: 2, op: "companion.events")
        poll.subscription = token
        poll.since = 0
        let events = await c.handle(poll)
        XCTAssertTrue(events.ok)
        XCTAssertTrue(events.text.contains("github.com"))
        XCTAssertTrue(c.companion.phoneConnected)
    }

    @MainActor
    func testASignInAnswerNamesTheRequestsWebsite() async throws {
        let phone = TestPhone()
        let (c, log) = try controller([phone.trusted])
        let login = "77777777-7777-4777-8777-777777777777"
        c.signInOffers["r1"] = SignInOffer(host: "github.com", field: "password",
                                           logins: [CompanionLogin(id: login, name: "GitHub", username: "max", totp: false)],
                                           bitwarden: "unlocked")
        let answer = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<SignInAnswer?, Never>) in
                c.pendingSignIns["r1"] = continuation
            }
        }
        while c.pendingSignIns["r1"] == nil { await Task.yield() }
        var r = AgentRequest(id: 1, op: "signin.answer")
        r.request = "r1"
        r.login = login
        r.host = "github.com.evil.example"
        let wrongSite = await c.handle(phone.sign(r))
        XCTAssertFalse(wrongSite.ok)
        XCTAssertTrue(log.lines.last?.contains("another website") == true)
        r.host = "github.com"
        let right = await c.handle(phone.sign(r))
        XCTAssertTrue(right.ok, right.text)
        let given = await answer.value
        XCTAssertEqual(given?.login, login)
        XCTAssertEqual(given?.from, "Max’ iPhone")
    }
}
