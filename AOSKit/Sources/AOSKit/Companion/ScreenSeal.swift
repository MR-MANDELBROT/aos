import CryptoKit
import Foundation

/// The workspace's screen login, readable only by the phone that asked (Docs/COMPANION.md, "The workspace's screen
/// login").
///
/// The phone's request passes through `aos-companion` and the app's agent socket, and any program of the Mac's user can
/// stand in for either. So the phone puts a fresh P-256 key-agreement key into its signed `screen` request (in memory
/// only, one per request), and the Mac answers with ciphertext only: its own fresh key, ECDH, HKDF-SHA256 with a
/// context that names the operation, the phone, the request's nonce and both keys, then AES-GCM. A program in between
/// sees the two public keys and the box, nothing else; a key it swaps in breaks the phone's signature.
///
/// The iPhone has the same scheme in iOS/Sources/Core/ScreenSeal.swift; both test the same reference vector
/// (`ScreenSealTests` here, `SealedScreenLoginTests` there, also computed with Python's `cryptography`).
public enum ScreenSeal {
    public static let version = "aos-screen-v1"

    /// The answer: the Mac's one-time public key and the box (AES-GCM nonce, ciphertext, tag).
    public struct Sealed: Equatable, Sendable {
        /// The Mac's P-256 key-agreement key, X9.63 (65 bytes).
        public var key: Data
        /// AES-GCM combined: 12-byte nonce, ciphertext, 16-byte tag.
        public var box: Data

        public init(key: Data, box: Data) {
            self.key = key
            self.box = box
        }

        /// As the reply carries it: `{"v":1,"key":"<base64>","box":"<base64>"}`.
        public var json: [String: Any] {
            ["v": 1, "key": key.base64EncodedString(), "box": box.base64EncodedString()]
        }

        public init?(json: [String: Any]?) {
            guard let json, (json["v"] as? Int) == 1, let k = json["key"] as? String, let b = json["box"] as? String,
                  let key = Data(base64Encoded: k), let box = Data(base64Encoded: b) else { return nil }
            self.init(key: key, box: box)
        }
    }

    public enum Failure: Error, Equatable {
        /// Not a P-256 point (or not 65 bytes).
        case badKey
        /// A value of the context has a line break.
        case badContext
        /// The box doesn't open: changed on its way, or sealed for another request.
        case broken
    }

    /// What binds the box to one request, these lines joined with "\n" (no newline at the end):
    ///
    ///     aos-screen-v1
    ///     op=<the signed op: companion.screen>
    ///     key=<phone id>
    ///     nonce=<the request's nonce>
    ///     phone=<base64 X9.63 of the phone's one-time key>
    ///     mac=<base64 X9.63 of the Mac's one-time key>
    ///
    /// It is HKDF's info and AES-GCM's additional data.
    public static func context(op: String, phone: String, nonce: String, phoneKey: Data, macKey: Data) -> Data? {
        let values = [op, phone, nonce]
        guard !values.contains(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) else { return nil }
        let lines = [version, "op=\(op)", "key=\(phone)", "nonce=\(nonce)",
                     "phone=\(phoneKey.base64EncodedString())", "mac=\(macKey.base64EncodedString())"]
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func symmetricKey(_ secret: SharedSecret, context: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(version.utf8), sharedInfo: context,
                                       outputByteCount: 32)
    }

    /// The Mac's side: seals `plaintext` for the phone's one-time key. `macKey` and `nonce` are fresh unless a test
    /// fixes them.
    public static func seal(_ plaintext: Data, to phoneKey: Data, op: String, phone: String, nonce: String,
                            macKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
                            gcmNonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Sealed {
        guard phoneKey.count == 65, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: phoneKey) else {
            throw Failure.badKey
        }
        let macPublic = macKey.publicKey.x963Representation
        guard let info = context(op: op, phone: phone, nonce: nonce, phoneKey: phoneKey, macKey: macPublic) else {
            throw Failure.badContext
        }
        let secret = try macKey.sharedSecretFromKeyAgreement(with: peer)
        let box = try AES.GCM.seal(plaintext, using: symmetricKey(secret, context: info), nonce: gcmNonce,
                                   authenticating: info)
        guard let combined = box.combined else { throw Failure.broken }
        return Sealed(key: macPublic, box: combined)
    }

    /// The phone's side: opens the Mac's answer with the one-time key it sent, for the request it signed.
    public static func open(_ sealed: Sealed, with phoneKey: P256.KeyAgreement.PrivateKey, op: String, phone: String,
                            nonce: String) throws -> Data {
        guard sealed.key.count == 65, let peer = try? P256.KeyAgreement.PublicKey(x963Representation: sealed.key) else {
            throw Failure.badKey
        }
        guard let info = context(op: op, phone: phone, nonce: nonce, phoneKey: phoneKey.publicKey.x963Representation,
                                 macKey: sealed.key) else { throw Failure.badContext }
        do {
            let secret = try phoneKey.sharedSecretFromKeyAgreement(with: peer)
            let box = try AES.GCM.SealedBox(combined: sealed.box)
            return try AES.GCM.open(box, using: symmetricKey(secret, context: info), authenticating: info)
        } catch {
            throw Failure.broken
        }
    }
}
