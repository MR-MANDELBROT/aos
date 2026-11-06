import Foundation
import LocalAuthentication

/// A Mac this iPhone is paired with. Not secret, kept in the keychain (this device only) with the pinned host key.
struct PairedMac: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Names and addresses from the pairing code, tried in this order.
    var hosts: [String]
    var sshPort: UInt16
    var user: String
    /// The Mac's SSH host key (`ssh-ed25519 AAAA...`), pinned at pairing.
    var hostKey: String
    var hostKeyFingerprint: String
    /// Path of `annex-companion` on the Mac.
    var companionPath: String
    var pairedAt = Date()
    /// The address that worked last time; tried first.
    var lastHost: String?

    /// The hosts in the order to try: the one that worked last time first.
    var hostsToTry: [String] {
        guard let lastHost, hosts.contains(lastHost) else { return hosts }
        return [lastHost] + hosts.filter { $0 != lastHost }
    }
}

/// An SSH host the person added for the terminal.
struct SSHHost: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Auth: String, Codable, Sendable, CaseIterable {
        /// This iPhone's key (its public key goes into the host's `authorized_keys`).
        case deviceKey
        /// A password kept in this iPhone's keychain behind Face ID.
        case password
    }

    var id = UUID()
    var label: String
    var host: String
    var port: UInt16 = 22
    var user: String
    var auth: Auth = .deviceKey
    /// Trusted on first use, after the person confirmed the fingerprint.
    var hostKey: String?

    var displayName: String { label.isEmpty ? "\(user)@\(host)" : label }
}

/// The lists of paired Macs and added hosts.
enum ConfigStore {
    private static let macsService = "dev.marquart.annex.macs"
    private static let hostsService = "dev.marquart.annex.hosts"

    static func loadMacs() -> [PairedMac] {
        (try? Keychain.getJSON([PairedMac].self, service: macsService, account: "list")) ?? []
    }

    static func saveMacs(_ macs: [PairedMac]) throws {
        try Keychain.setJSON(macs, service: macsService, account: "list", protection: .afterFirstUnlock)
    }

    static func loadHosts() -> [SSHHost] {
        (try? Keychain.getJSON([SSHHost].self, service: hostsService, account: "list")) ?? []
    }

    static func saveHosts(_ hosts: [SSHHost]) throws {
        try Keychain.setJSON(hosts, service: hostsService, account: "list", protection: .afterFirstUnlock)
    }
}

/// Secrets that open other computers: SSH passwords of added hosts and the Mac account for the Mac's own screen.
/// Every read needs Face ID (or the passcode).
enum SecretStore {
    private static let hostPasswordService = "dev.marquart.annex.hostpassword"
    private static let screenService = "dev.marquart.annex.macscreen"

    struct ScreenLogin: Codable, Equatable, Sendable {
        var username: String
        var password: String
    }

    static func setPassword(_ password: String, for host: SSHHost) throws {
        try Keychain.set(Data(password.utf8), service: hostPasswordService, account: host.id.uuidString,
                         protection: .userPresence)
    }

    static func password(for host: SSHHost, context: LAContext?) throws -> String? {
        try Keychain.get(service: hostPasswordService, account: host.id.uuidString, context: context,
                         prompt: String(localized: "Unlock the password for \(host.displayName)"))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func hasPassword(for host: SSHHost) -> Bool {
        ((try? Keychain.accounts(service: hostPasswordService)) ?? []).contains(host.id.uuidString)
    }

    static func deletePassword(for host: SSHHost) {
        try? Keychain.delete(service: hostPasswordService, account: host.id.uuidString)
    }

    static func setScreenLogin(_ login: ScreenLogin, for mac: PairedMac) throws {
        try Keychain.setJSON(login, service: screenService, account: mac.id.uuidString, protection: .userPresence)
    }

    static func screenLogin(for mac: PairedMac, context: LAContext?) throws -> ScreenLogin? {
        try Keychain.getJSON(ScreenLogin.self, service: screenService, account: mac.id.uuidString, context: context,
                             prompt: String(localized: "Unlock the login for the screen of \(mac.name)"))
    }

    static func hasScreenLogin(for mac: PairedMac) -> Bool {
        ((try? Keychain.accounts(service: screenService)) ?? []).contains(mac.id.uuidString)
    }

    static func deleteScreenLogin(for mac: PairedMac) {
        try? Keychain.delete(service: screenService, account: mac.id.uuidString)
    }
}
