import Foundation
import LocalAuthentication
import Observation
import UIKit
import UniformTypeIdentifiers

/// The vault as the views see it: the index for listing, secrets only behind Face ID.
@MainActor @Observable
final class VaultModel {
    private let store: VaultStoring
    /// False only in the demo, where there is nothing secret to protect.
    private let requiresAuthentication: Bool
    private(set) var entries: [VaultEntry] = []
    private(set) var loadError: String?

    init(store: VaultStoring, requiresAuthentication: Bool = true) {
        self.store = store
        self.requiresAuthentication = requiresAuthentication
        reload()
    }

    func reload() {
        do {
            entries = try store.loadIndex().sorted(by: Self.order)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func entries(matching search: String) -> [VaultEntry] {
        entries.filter { $0.matches(search: search) }
    }

    /// Logins for a sign-in request (Docs/COMPANION.md, "Matching logins").
    func logins(for host: String) -> [VaultEntry] {
        entries.filter { $0.matches(host: host) }
    }

    func entry(id: UUID) -> VaultEntry? { entries.first { $0.id == id } }

    // MARK: Changing

    /// Adds or replaces a login.
    func save(_ entry: VaultEntry, secret: VaultSecret) throws {
        var entry = entry
        entry.hasTOTP = !secret.totp.trimmingCharacters(in: .whitespaces).isEmpty
        entry.hasNotes = !secret.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entry.modified = Date()
        try store.saveSecret(secret, for: entry.id)
        var updated = entries.filter { $0.id != entry.id }
        updated.append(entry)
        try store.saveIndex(updated)
        entries = updated.sorted(by: Self.order)
    }

    func delete(_ entry: VaultEntry) throws {
        try store.deleteSecret(for: entry.id)
        let updated = entries.filter { $0.id != entry.id }
        try store.saveIndex(updated)
        entries = updated
    }

    /// Adds imported logins, skipping ones that are in the vault already (same title, user name and hosts).
    func add(imported logins: [ImportedLogin]) throws -> (added: Int, duplicates: Int) {
        var updated = entries
        var keys = Set(entries.map(Self.duplicateKey))
        var added = 0, duplicates = 0
        for login in logins {
            var entry = VaultEntry(title: login.title, username: login.username, uris: login.uris,
                                   hasTOTP: !login.totp.isEmpty, hasNotes: !login.notes.isEmpty)
            guard keys.insert(Self.duplicateKey(entry)).inserted else { duplicates += 1; continue }
            entry.created = Date()
            try store.saveSecret(VaultSecret(password: login.password, totp: login.totp, notes: login.notes), for: entry.id)
            updated.append(entry)
            added += 1
        }
        try store.saveIndex(updated)
        entries = updated.sorted(by: Self.order)
        return (added, duplicates)
    }

    // MARK: Secrets

    /// Asks for Face ID, then reads the secret part of a login.
    func unlock(_ entry: VaultEntry, reason: String) async throws -> VaultSecret {
        let context = try await authenticate(reason: reason)
        defer { context?.invalidate() }
        guard let secret = try store.secret(for: entry.id, context: context) else { throw VaultError.missing }
        return secret
    }

    /// Face ID once, for a read of several secrets (the context unlocks them without asking again).
    func authenticate(reason: String) async throws -> LAContext? {
        guard requiresAuthentication else { return nil }
        return try await Biometrics.authenticate(reason: reason)
    }

    func secret(for entry: VaultEntry, context: LAContext?) throws -> VaultSecret {
        guard let secret = try store.secret(for: entry.id, context: context) else { throw VaultError.missing }
        return secret
    }

    enum VaultError: LocalizedError {
        case missing
        var errorDescription: String? { String(localized: "This login's password is missing on this iPhone.") }
    }

    // MARK: Helpers

    private static func order(_ a: VaultEntry, _ b: VaultEntry) -> Bool {
        a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    private static func duplicateKey(_ entry: VaultEntry) -> String {
        let hosts = Set(entry.uris.compactMap(HostMatching.host(ofURI:))).sorted().joined(separator: ",")
        return entry.title.lowercased() + "\u{1}" + entry.username.lowercased() + "\u{1}" + hosts
    }
}

/// Copying secrets: this device only (no Universal Clipboard), gone after a while.
enum Clipboard {
    static func copy(_ text: String, expiresAfter seconds: Int) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date().addingTimeInterval(TimeInterval(seconds))])
    }

    /// For text that isn't secret (a user name, a public key): still only on this device, but it stays.
    static func copyPlain(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
    }
}

/// Strong random passwords for new logins.
enum PasswordGenerator {
    /// 20 characters from letters, digits and a few symbols, without look-alikes; at least one of each kind.
    static func make(length: Int = 20) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789"), symbols = Array("-_.!?#%+")
        let all = lower + upper + digits + symbols
        var generator = SystemRandomNumberGenerator()
        while true {
            let chars = (0..<length).map { _ in all.randomElement(using: &generator)! }
            if chars.contains(where: lower.contains), chars.contains(where: upper.contains),
               chars.contains(where: digits.contains), chars.contains(where: symbols.contains) {
                return String(chars)
            }
        }
    }
}
