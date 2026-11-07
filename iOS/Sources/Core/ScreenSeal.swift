import CryptoKit
import Foundation

/// The workspace's screen login, readable only by this iPhone (Docs/COMPANION.md, "The workspace's screen login").
/// The same scheme as aOS on the Mac (AOSKit `ScreenSeal`; both test the same reference vector):
///
/// The `screen` request for the workspace carries a fresh P-256 key-agreement key, made for this one request and kept
/// in memory only until the answer is open; the signature covers it. The Mac answers with its own fresh key and an
/// AES-GCM box: ECDH, then HKDF-SHA256 over a context naming the op, this iPhone, the request's nonce and both keys.
/// `aos-companion`, and whatever stands in for it on the Mac, sees only ciphertext.
enum ScreenSeal {
    static let version = "aos-screen-v1"

    /// The answer: the Mac's one-time public key and the box (AES-GCM nonce, ciphertext, tag).
    struct Sealed: Equatable, Sendable {
        /// The Mac's P-256 key-agreement key, X9.63 (65 bytes).
        var key: Data
        /// AES-GCM combined: 12-byte nonce, ciphertext, 16-byte tag.
        var box: Data

        init(key: Data, box: Data) {
            self.key = key
            self.box = box
        }

        /// `{"v":1,"key":"<base64>","box":"<base64>"}` in the answer.
        init?(_ value: JSONValue?) {
            guard let o = value?.object, o["v"]?.int == 1,
                  let key = o["key"]?.string.flatMap({ Data(base64Encoded: $0) }),
                  let box = o["box"]?.string.flatMap({ Data(base64Encoded: $0) }) else { return nil }
            self.init(key: key, box: box)
        }

        var json: JSONValue {
            .object(["v": .number(1), "key": .string(key.base64EncodedString()), "box": .string(box.base64EncodedString())])
        }
    }

    enum Failure: Error, Equatable {
        case badKey, badContext, broken
    }

    /// What binds the box to one request, these lines joined with "\n" (no newline at the end); HKDF's info and
    /// AES-GCM's additional data:
    ///
    ///     aos-screen-v1
    ///     op=companion.screen
    ///     key=<phone id>
    ///     nonce=<the request's nonce>
    ///     phone=<base64 X9.63 of this iPhone's one-time key>
    ///     mac=<base64 X9.63 of the Mac's one-time key>
    static func context(op: String, phone: String, nonce: String, phoneKey: Data, macKey: Data) -> Data? {
        guard ![op, phone, nonce].contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) else {
            return nil
        }
        let lines = [version, "op=\(op)", "key=\(phone)", "nonce=\(nonce)",
                     "phone=\(phoneKey.base64EncodedString())", "mac=\(macKey.base64EncodedString())"]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func symmetricKey(_ secret: SharedSecret, context: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(version.utf8), sharedInfo: context,
                                       outputByteCount: 32)
    }

    /// Opens the Mac's answer with the one-time key this iPhone sent, for the request it signed.
    static func open(_ sealed: Sealed, with phoneKey: P256.KeyAgreement.PrivateKey, op: String, phone: String,
                     nonce: String) throws -> Data {
        guard sealed.key.count == 65, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: sealed.key) else {
            throw Failure.badKey
        }
        guard let info = context(op: op, phone: phone, nonce: nonce, phoneKey: phoneKey.publicKey.x963Representation,
                                 macKey: sealed.key) else { throw Failure.badContext }
        do {
            let secret = try phoneKey.sharedSecretFromKeyAgreement(with: peer)
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.box),
                                    using: symmetricKey(secret, context: info), authenticating: info)
        } catch {
            throw Failure.broken
        }
    }

    /// The Mac's side, for the in-memory Mac of the tests and the demo (`MockCompanionServer`).
    static func seal(_ plaintext: Data, to phoneKey: Data, op: String, phone: String, nonce: String) throws -> Sealed {
        guard phoneKey.count == 65, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: phoneKey) else {
            throw Failure.badKey
        }
        let macKey = P256.KeyAgreement.PrivateKey()
        let macPublic = macKey.publicKey.x963Representation
        guard let info = context(op: op, phone: phone, nonce: nonce, phoneKey: phoneKey, macKey: macPublic) else {
            throw Failure.badContext
        }
        let secret = try macKey.sharedSecretFromKeyAgreement(with: peer)
        guard let combined = try AES.GCM.seal(plaintext, using: symmetricKey(secret, context: info),
                                              authenticating: info).combined else { throw Failure.broken }
        return Sealed(key: macPublic, box: combined)
    }

    /// The workspace's login in the answer to a `screen` request: opened with the request's one-time key and the
    /// signature it went with. An answer without a sealed login (an older Mac, or someone answering in its place in
    /// plaintext) is never taken: `CompanionError.updateMac`. One that doesn't open: `CompanionError.invalidAnswer`.
    static func login(in response: CompanionResponse, with oneTimeKey: P256.KeyAgreement.PrivateKey, op: String,
                      auth: CompanionAuth?) throws -> ScreenEndpoint {
        guard let sealed = Sealed(response.body["sealed"]) else { throw CompanionError.updateMac }
        guard let plaintext = try? open(sealed, with: oneTimeKey, op: op, phone: auth?.key ?? "", nonce: auth?.nonce ?? ""),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: plaintext))?.object,
              let login = ScreenEndpoint(body: object) else { throw CompanionError.invalidAnswer }
        return login
    }
}
