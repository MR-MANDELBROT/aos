import CryptoKit
import Foundation
@preconcurrency import NIOSSH
import Security

/// The iPhone's SSH key: P-256, created on this iPhone and never leaving it.
///
/// On a real iPhone the private key lives in the Secure Enclave; the keychain only holds the enclave's encrypted
/// handle to it, usable on this device only. Where there is no Secure Enclave (the simulator) the key is a software
/// key in the keychain, this device only.
struct DeviceKey: Sendable {
    enum Storage: String, Codable, Sendable { case secureEnclave, keychain }

    let storage: Storage
    /// The key's handle (Secure Enclave) or raw private key (software); stays in memory only while needed.
    private let material: Data
    /// `ecdsa-sha2-nistp256 AAAA...`: what the Mac puts into `authorized_keys`.
    let publicKey: String
    let fingerprint: String

    private static let service = "dev.marquart.aos.devicekey"
    private static let account = "ssh-p256"

    /// The key of this iPhone, created on first use.
    static func loadOrCreate() throws -> DeviceKey {
        if let stored = try Keychain.getJSON(Stored.self, service: service, account: account),
           let key = try? DeviceKey(stored) {
            return key
        }
        let key = try create()
        try Keychain.setJSON(Stored(storage: key.storage, material: key.material), service: service, account: account,
                             protection: .afterFirstUnlock)
        return key
    }

    /// A software key that is not stored anywhere (tests).
    static func ephemeral() -> DeviceKey {
        let key = P256.Signing.PrivateKey(compactRepresentable: false)
        return DeviceKey(storage: .keychain, material: key.rawRepresentation, publicX963: key.publicKey.x963Representation)
    }

    /// Forgets the key (a new one is made next time). Every Mac and host that trusted it must be paired again.
    static func reset() throws {
        try Keychain.delete(service: service, account: account)
    }

    /// The private key for an SSH login. Secure Enclave keys sign inside the enclave.
    func sshPrivateKey() throws -> NIOSSHPrivateKey {
        switch storage {
        case .secureEnclave:
            return NIOSSHPrivateKey(secureEnclaveP256Key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material))
        case .keychain:
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: material))
        }
    }

    // MARK: Private

    private struct Stored: Codable {
        var storage: Storage
        var material: Data
    }

    private init(storage: Storage, material: Data, publicX963: Data) {
        self.storage = storage
        self.material = material
        publicKey = SSHKeyFormat.openSSHP256(x963: publicX963)
        fingerprint = SSHKeyFormat.fingerprint(openSSHKey: publicKey) ?? ""
    }

    private init(_ stored: Stored) throws {
        switch stored.storage {
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.material)
            self.init(storage: .secureEnclave, material: stored.material, publicX963: key.publicKey.x963Representation)
        case .keychain:
            let key = try P256.Signing.PrivateKey(rawRepresentation: stored.material)
            self.init(storage: .keychain, material: stored.material, publicX963: key.publicKey.x963Representation)
        }
    }

    private static func create() throws -> DeviceKey {
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            // Usable after the first unlock, so the app can reconnect; the key itself never leaves the enclave.
            if let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                            .privateKeyUsage, &error),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access) {
                return DeviceKey(storage: .secureEnclave, material: key.dataRepresentation,
                                 publicX963: key.publicKey.x963Representation)
            }
        }
        let key = P256.Signing.PrivateKey(compactRepresentable: false)
        return DeviceKey(storage: .keychain, material: key.rawRepresentation, publicX963: key.publicKey.x963Representation)
    }
}
