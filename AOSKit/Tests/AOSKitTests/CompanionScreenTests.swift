import CryptoKit
@testable import AOSKit
import XCTest

/// The sealing itself: only the phone that asked can open the workspace's screen login.
final class ScreenSealTests: XCTestCase {
    let op = "companion.screen", phone = "4853150ceae1", nonce = "AAECAwQFBgcICQoLDA0ODw"

    func testRoundTrip() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let plaintext = Data(#"{"host":"192.168.64.5","password":"geheim"}"#.utf8)
        let sealed = try ScreenSeal.seal(plaintext, to: phoneKey.publicKey.x963Representation, op: op, phone: phone,
                                         nonce: nonce)
        XCTAssertEqual(sealed.key.count, 65)
        XCTAssertNil(sealed.box.range(of: Data("geheim".utf8)), "nothing readable in the box")
        XCTAssertEqual(try ScreenSeal.open(sealed, with: phoneKey, op: op, phone: phone, nonce: nonce), plaintext)
        // As JSON and back
        XCTAssertEqual(ScreenSeal.Sealed(json: sealed.json), sealed)
        XCTAssertNil(ScreenSeal.Sealed(json: ["v": 2, "key": "", "box": ""]))
        // A fresh Mac key and GCM nonce every time
        let again = try ScreenSeal.seal(plaintext, to: phoneKey.publicKey.x963Representation, op: op, phone: phone,
                                        nonce: nonce)
        XCTAssertNotEqual(again.key, sealed.key)
        XCTAssertNotEqual(again.box, sealed.box)
    }

    func testATamperedBoxOrAnotherRequestDoesntOpen() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let sealed = try ScreenSeal.seal(Data("secret".utf8), to: phoneKey.publicKey.x963Representation, op: op,
                                         phone: phone, nonce: nonce)
        // Any changed byte: the GCM nonce, the ciphertext, the tag
        for i in [0, 12, sealed.box.count - 1] {
            var changed = sealed
            changed.box[changed.box.startIndex + i] ^= 0x01
            XCTAssertThrowsError(try ScreenSeal.open(changed, with: phoneKey, op: op, phone: phone, nonce: nonce)) {
                XCTAssertEqual($0 as? ScreenSeal.Failure, .broken)
            }
        }
        // Another Mac key in the answer, another nonce (an answer kept from an earlier request), another phone key,
        // another op: the context differs and the box doesn't open
        var swapped = sealed
        swapped.key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        XCTAssertThrowsError(try ScreenSeal.open(swapped, with: phoneKey, op: op, phone: phone, nonce: nonce))
        XCTAssertThrowsError(try ScreenSeal.open(sealed, with: phoneKey, op: op, phone: phone, nonce: "BBECAwQFBgcICQoLDA0ODw"))
        XCTAssertThrowsError(try ScreenSeal.open(sealed, with: P256.KeyAgreement.PrivateKey(), op: op, phone: phone,
                                                 nonce: nonce))
        XCTAssertThrowsError(try ScreenSeal.open(sealed, with: phoneKey, op: "companion.type", phone: phone, nonce: nonce))
        XCTAssertThrowsError(try ScreenSeal.open(sealed, with: phoneKey, op: op, phone: "000000000000", nonce: nonce))
        // Not a key at all, a line break in the context
        XCTAssertThrowsError(try ScreenSeal.seal(Data(), to: Data(repeating: 4, count: 65), op: op, phone: phone,
                                                 nonce: nonce)) { XCTAssertEqual($0 as? ScreenSeal.Failure, .badKey) }
        XCTAssertNil(ScreenSeal.context(op: op, phone: phone, nonce: "a\nb", phoneKey: Data(), macKey: Data()))
    }

    /// The reference vector the iPhone's tests open too (iOS/Tests/SealedScreenLoginTests.swift), also computed with
    /// Python's `cryptography` (ECDH, HKDF-SHA256, AES-GCM) to the same bytes: fixed keys (phone 01..20, Mac 21..40)
    /// and a fixed GCM nonce (00..0b).
    func testReferenceVector() throws {
        let phoneKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        let macKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(33...64))
        let sealed = try ScreenSeal.seal(Data(#"{"password":"geheim"}"#.utf8), to: phoneKey.publicKey.x963Representation,
                                         op: op, phone: phone, nonce: nonce, macKey: macKey,
                                         gcmNonce: try AES.GCM.Nonce(data: Data(0..<12)))
        let context = try XCTUnwrap(ScreenSeal.context(op: op, phone: phone, nonce: nonce,
                                                       phoneKey: phoneKey.publicKey.x963Representation,
                                                       macKey: macKey.publicKey.x963Representation))
        XCTAssertEqual(String(decoding: context, as: UTF8.self), """
            aos-screen-v1
            op=companion.screen
            key=4853150ceae1
            nonce=AAECAwQFBgcICQoLDA0ODw
            phone=BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q=
            mac=BB8UAUa/sbJR+E9N2+DUzc/Xev2YSpUg41eUAh+DErue7JlaCLH6dwTfPcwLUKlmUmP7dxH5X5+KRJxQluR8iSs=
            """)
        XCTAssertEqual(sealed.key.base64EncodedString(),
                       "BB8UAUa/sbJR+E9N2+DUzc/Xev2YSpUg41eUAh+DErue7JlaCLH6dwTfPcwLUKlmUmP7dxH5X5+KRJxQluR8iSs=")
        XCTAssertEqual(sealed.box.base64EncodedString(),
                       "AAECAwQFBgcICQoL+APgE8Y8TlMJetK2W7N66yDO8c6j1i8jHiJdq6KMhUBWtWhTFg==")
        XCTAssertEqual(try ScreenSeal.open(sealed, with: phoneKey, op: op, phone: phone, nonce: nonce),
                       Data(#"{"password":"geheim"}"#.utf8))
    }
}

/// The workspace's screen login goes to the phone sealed to a one-time key its signature covers.
final class CompanionScreenTests: XCTestCase {
    let phone = TestPhone()

    func screenRequest(_ key: P256.KeyAgreement.PrivateKey) -> AgentRequest {
        var r = AgentRequest(id: 4, op: "companion.screen")
        r.target = "workspace"
        r.reply = key.publicKey.x963Representation.base64EncodedString()
        return r
    }

    func testTheReplyKeyIsSigned() {
        // Python: hashlib.sha256(b"reply:88:BFFcPW65...1Q=\n"), the public key of 01..20 (also in the iPhone's tests)
        XCTAssertEqual(CompanionSignature.dataDigest(reply: "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q="),
                       "2c4f2b4babd1464127bd60006cf4448888d07a7b0aaff3dff22f2b97e76f0562")
        // Requests without it sign what they always signed
        XCTAssertEqual(CompanionSignature.dataDigest(reply: nil), CompanionSignature.dataDigest())
        var r = screenRequest(P256.KeyAgreement.PrivateKey())
        let auth = CompanionAuth(key: phone.id, ts: 1, nonce: "AAECAwQFBgcICQoLDA0ODw", sig: "")
        XCTAssertEqual(CompanionSignature.fields(for: r, auth: auth).data, CompanionSignature.dataDigest(reply: r.reply))
        r.reply = nil
        XCTAssertEqual(CompanionSignature.fields(for: r, auth: auth).data, CompanionSignature.dataDigest())
    }

    @MainActor
    func testRoundTripThroughTheGate() throws {
        let gate = CompanionGate(store: MemoryPhoneKeys([phone.trusted]))
        let oneTime = P256.KeyAgreement.PrivateKey()
        let signed = phone.sign(screenRequest(oneTime))
        guard case .success = gate.admit(signed) else { return XCTFail("refused") }
        let login: [String: Any] = ["host": "192.168.64.5", "port": 5900, "username": "aos", "password": "geheim"]
        let sealed = try WorkspaceController.seal(login, for: signed)
        // Opened on the phone with its one-time key and what it signed
        let plaintext = try ScreenSeal.open(sealed, with: oneTime, op: "companion.screen", phone: phone.id,
                                            nonce: try XCTUnwrap(signed.auth?.nonce))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(object["host"] as? String, "192.168.64.5")
        XCTAssertEqual(object["port"] as? Int, 5900)
        XCTAssertEqual(object["username"] as? String, "aos")
        XCTAssertEqual(object["password"] as? String, "geheim")
        // Nobody else opens it
        XCTAssertThrowsError(try ScreenSeal.open(sealed, with: P256.KeyAgreement.PrivateKey(), op: "companion.screen",
                                                 phone: phone.id, nonce: signed.auth!.nonce))
    }

    @MainActor
    func testASwappedKeyFailsTheSignature() {
        let gate = CompanionGate(store: MemoryPhoneKeys([phone.trusted]))
        var signed = phone.sign(screenRequest(P256.KeyAgreement.PrivateKey()))
        // Whoever relays the request puts in its own key, to read the answer: the signature no longer checks out
        signed.reply = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        guard case .failure(let refusal) = gate.admit(signed) else { return XCTFail("admitted a swapped key") }
        XCTAssertEqual(refusal.code, "invalid")
        // Or takes it out, hoping for a plaintext answer: same
        var stripped = phone.sign(screenRequest(P256.KeyAgreement.PrivateKey()))
        stripped.reply = nil
        guard case .failure = gate.admit(stripped) else { return XCTFail("admitted without the key") }
    }

    @MainActor
    func testAReplayFails() {
        let gate = CompanionGate(store: MemoryPhoneKeys([phone.trusted]))
        let signed = phone.sign(screenRequest(P256.KeyAgreement.PrivateKey()))
        guard case .success = gate.admit(signed) else { return XCTFail() }
        guard case .failure(let refusal) = gate.admit(signed) else { return XCTFail("admitted twice") }
        XCTAssertEqual(refusal.message, "This request was sent before.")
    }

    @MainActor
    func testNoPlaintextForTheWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-screen-\(UUID().uuidString)")
        let paths = Paths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = WorkspaceController(paths: paths, bitwarden: BitwardenVault(paths: paths, store: MemorySessionStore()),
                                    phoneKeys: MemoryPhoneKeys([phone.trusted]))
        // An older iPhone app (signed, but no one-time key): told to update, nothing else
        var old = AgentRequest(id: 1, op: "companion.screen")
        old.target = "workspace"
        let refused = await c.handle(phone.sign(old))
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.code, "update")
        XCTAssertFalse(refused.text.contains("password"))
        // With a key but no running workspace: no login either
        let stopped = await c.handle(phone.sign(screenRequest(P256.KeyAgreement.PrivateKey())))
        XCTAssertFalse(stopped.ok)
        XCTAssertEqual(stopped.text, "The workspace is not running.")
        // Unsigned: refused before anything
        let unsigned = await c.handle(screenRequest(P256.KeyAgreement.PrivateKey()))
        XCTAssertEqual(unsigned.code, "pair-again")
        // The Mac's own screen stays plain (it has no login to give)
        var mac = AgentRequest(id: 3, op: "companion.screen")
        mac.target = "mac"
        let own = await c.handle(phone.sign(mac))
        XCTAssertTrue(own.ok)
        XCTAssertEqual(own.text, #"{"host":"127.0.0.1","port":5900}"#)
    }
}
