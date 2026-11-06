import CryptoKit
import Foundation
import Security

/// The key this iPhone signs its requests to aOS on the Mac with (Docs/COMPANION.md, "Signed requests"): P-256,
/// created on this iPhone and never leaving it; its public half goes to the Mac at pairing, covered by the pairing
/// code. A key of its own, apart from the SSH key: that one only logs in, and the Mac's authorized_keys can't vouch for
/// anything.
///
/// On a real iPhone the private key lives in the Secure Enclave (the keychain holds the enclave's handle, this device
/// only); on the simulator it is a software key in the keychain, this device only.
struct CompanionKey: Sendable {
    enum Storage: String, Codable, Sendable { case secureEnclave, keychain }

    let storage: Storage
    private let material: Data
    /// X9.63 (`04 || X || Y`, 65 bytes): what the Mac keeps.
    let publicKey: Data

    private static let service = "dev.marquart.aos.companionkey"
    private static let account = "p256-signing"

    /// This iPhone's key, created on first use.
    static func loadOrCreate() throws -> CompanionKey {
        if let stored = try Keychain.getJSON(Stored.self, service: service, account: account),
           let key = try? CompanionKey(stored) {
            return key
        }
        let key = try create()
        try Keychain.setJSON(Stored(storage: key.storage, material: key.material), service: service, account: account,
                             protection: .afterFirstUnlock)
        return key
    }

    /// A software key that is not stored anywhere (tests, the demo).
    static func ephemeral() -> CompanionKey {
        let key = P256.Signing.PrivateKey(compactRepresentable: false)
        return CompanionKey(storage: .keychain, material: key.rawRepresentation, publicKey: key.publicKey.x963Representation)
    }

    /// Forgets the key; every Mac has to be paired again.
    static func reset() throws {
        try Keychain.delete(service: service, account: account)
    }

    /// ECDSA P-256 with SHA-256 over `message`: r and s, 64 bytes.
    func sign(_ message: Data) throws -> Data {
        switch storage {
        case .secureEnclave:
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material).signature(for: message)
                .rawRepresentation
        case .keychain:
            return try P256.Signing.PrivateKey(rawRepresentation: material).signature(for: message).rawRepresentation
        }
    }

    // MARK: Private

    private struct Stored: Codable {
        var storage: Storage
        var material: Data
    }

    private init(storage: Storage, material: Data, publicKey: Data) {
        self.storage = storage
        self.material = material
        self.publicKey = publicKey
    }

    private init(_ stored: Stored) throws {
        switch stored.storage {
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.material)
            self.init(storage: .secureEnclave, material: stored.material, publicKey: key.publicKey.x963Representation)
        case .keychain:
            let key = try P256.Signing.PrivateKey(rawRepresentation: stored.material)
            self.init(storage: .keychain, material: stored.material, publicKey: key.publicKey.x963Representation)
        }
    }

    private static func create() throws -> CompanionKey {
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            // Usable after the first unlock (the app signs its heartbeat in the background too); approvals ask for
            // Face ID in the app before they are signed.
            if let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                            .privateKeyUsage, &error),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access) {
                return CompanionKey(storage: .secureEnclave, material: key.dataRepresentation,
                                    publicKey: key.publicKey.x963Representation)
            }
        }
        return ephemeral()
    }
}

/// Signs the companion requests of this iPhone: its phone id (as the Mac knows it) and its key.
struct CompanionSigner: Sendable {
    /// First 12 hex characters of the SHA-256 of this iPhone's SSH key (the Mac's id for it).
    let phoneID: String
    let key: CompanionKey

    /// A fresh signature for `request`: now, a new nonce.
    func auth(for request: CompanionRequest, now: Date = Date()) throws -> CompanionAuth {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CompanionError.unsignable
        }
        let ts = Int(now.timeIntervalSince1970)
        let nonce = SSHKeyFormat.base64URLEncode(Data(bytes))
        guard let message = CompanionSignature.message(request.signatureFields(key: phoneID, ts: ts, nonce: nonce)) else {
            throw CompanionError.unsignable
        }
        return CompanionAuth(key: phoneID, ts: ts, nonce: nonce, sig: try key.sign(message).base64EncodedString())
    }
}
