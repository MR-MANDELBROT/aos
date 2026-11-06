import Foundation
import LocalAuthentication

/// What the vault lists without unlocking anything: no passwords, no TOTP secrets, no notes.
struct VaultEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var username: String
    var uris: [String]
    var hasTOTP: Bool
    var hasNotes: Bool
    var created = Date()
    var modified = Date()

    func matches(host: String) -> Bool { HostMatching.matches(uris: uris, requestHost: host) }

    /// The first web host, for display ("amazon.de").
    var primaryHost: String? { uris.lazy.compactMap(HostMatching.host(ofURI:)).first }

    func matches(search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedStandardContains(q) || username.localizedStandardContains(q)
            || uris.contains { $0.localizedStandardContains(q) }
    }
}

/// The secret part of a login. Read only behind Face ID, held in memory only as long as needed.
struct VaultSecret: Codable, Equatable, Sendable {
    var password: String
    /// An `otpauth://` URI or a base32 secret; empty when the login has none.
    var totp: String
    var notes: String
}

protocol VaultStoring: Sendable {
    func loadIndex() throws -> [VaultEntry]
    func saveIndex(_ entries: [VaultEntry]) throws
    func saveSecret(_ secret: VaultSecret, for id: UUID) throws
    /// Needs an authenticated context on a real device (keychain items behind user presence).
    func secret(for id: UUID, context: LAContext?) throws -> VaultSecret?
    func deleteSecret(for id: UUID) throws
    func deleteAll()
}

/// The vault in the keychain: the index readable while the iPhone is unlocked, every login's secret part in its own
/// item behind user presence (`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`, never synchronized).
struct KeychainVaultStore: VaultStoring {
    private let indexService = "dev.marquart.aos.vault.index"
    private let secretService = "dev.marquart.aos.vault"

    func loadIndex() throws -> [VaultEntry] {
        try Keychain.getJSON([VaultEntry].self, service: indexService, account: "index") ?? []
    }

    func saveIndex(_ entries: [VaultEntry]) throws {
        try Keychain.setJSON(entries, service: indexService, account: "index", protection: .whenUnlocked)
    }

    func saveSecret(_ secret: VaultSecret, for id: UUID) throws {
        try Keychain.setJSON(secret, service: secretService, account: id.uuidString, protection: .userPresence)
    }

    func secret(for id: UUID, context: LAContext?) throws -> VaultSecret? {
        try Keychain.getJSON(VaultSecret.self, service: secretService, account: id.uuidString, context: context,
                             prompt: String(localized: "Unlock the password"))
    }

    func deleteSecret(for id: UUID) throws {
        try Keychain.delete(service: secretService, account: id.uuidString)
    }

    func deleteAll() {
        Keychain.deleteAll(service: secretService)
        Keychain.deleteAll(service: indexService)
    }
}

/// A vault in memory, for the tests and the demo.
final class MemoryVaultStore: VaultStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var index: [VaultEntry] = []
    private var secrets: [UUID: VaultSecret] = [:]

    init(entries: [(VaultEntry, VaultSecret)] = []) {
        index = entries.map(\.0)
        for (entry, secret) in entries { secrets[entry.id] = secret }
    }

    func loadIndex() throws -> [VaultEntry] { lock.withLock { index } }
    func saveIndex(_ entries: [VaultEntry]) throws { lock.withLock { index = entries } }
    func saveSecret(_ secret: VaultSecret, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
    func secret(for id: UUID, context: LAContext?) throws -> VaultSecret? { lock.withLock { secrets[id] } }
    func deleteSecret(for id: UUID) throws { lock.withLock { _ = secrets.removeValue(forKey: id) } }
    func deleteAll() { lock.withLock { index = []; secrets = [:] } }
}
