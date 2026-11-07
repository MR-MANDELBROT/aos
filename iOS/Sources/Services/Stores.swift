import AOSTailnet
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
    /// Path of `aos-companion` on the Mac.
    var companionPath: String
    var pairedAt = Date()
    /// The address that worked last time; tried first.
    var lastHost: String?
    /// How the iPhone reaches the Mac on the go, from the pairing code (nil: paired before the choice existed).
    var way: ReachWay? = nil
    /// The Mac's tailnet addresses and names from the pairing code (`t`); older pairings: none (the tailnet
    /// addresses among `hosts` count, see `ConnectionPlan`).
    var tailnetHosts: [String]? = nil
    /// The tailnet the Mac is in.
    var tailnetName: String? = nil

    /// The hosts in the order to try: the one that worked last time first.
    var hostsToTry: [String] {
        guard let lastHost, hosts.contains(lastHost) else { return hosts }
        return [lastHost] + hosts.filter { $0 != lastHost }
    }
}

/// The list of paired Macs.
enum ConfigStore {
    private static let macsService = "dev.marquart.aos.macs"

    static func loadMacs() -> [PairedMac] {
        (try? Keychain.getJSON([PairedMac].self, service: macsService, account: "list")) ?? []
    }

    static func saveMacs(_ macs: [PairedMac]) throws {
        try Keychain.setJSON(macs, service: macsService, account: "list", protection: .afterFirstUnlock)
    }

    /// Earlier versions let the terminal reach other computers too ("Other computers"), with their passwords in the
    /// keychain. The terminal is the Mac's alone now: what they kept goes, so no password stays without a way to
    /// remove it.
    static func deleteAddedHosts() {
        Keychain.deleteAll(service: "dev.marquart.aos.hosts")
        Keychain.deleteAll(service: "dev.marquart.aos.hostpassword")
    }
}

/// The Mac account for the Mac's own screen. Every read needs Face ID (or the passcode).
enum SecretStore {
    private static let screenService = "dev.marquart.aos.macscreen"

    struct ScreenLogin: Codable, Equatable, Sendable {
        var username: String
        var password: String
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
