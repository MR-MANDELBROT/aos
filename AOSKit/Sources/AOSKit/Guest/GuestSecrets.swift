import Foundation
import Security

/// Secrets that belong to the VM only: the password of the guest account (for the first SSH login, the provisioning,
/// the screen sharing switch and screen sharing logins) and the SSH keys that maintain the guest. None of them is a
/// credential of the user.
///
/// In the app they are in the custody of aOS's helper (`custody`, see WorkspaceCustody.swift): the keys never leave
/// it, the password is loaded into memory (`load()`). Without it (tests, the command line tool) they are files in the
/// private Keys folder (0700, files 0600).
public struct GuestSecrets: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    private static let custodyBox = Locked<WorkspaceCustodyClient?>(nil)
    private static let passwordBox = Locked<String?>(nil)

    /// Set once by the app at launch: from then on the helper keeps the keys and the password.
    public static var custody: WorkspaceCustodyClient? {
        get { custodyBox.get() }
        set { custodyBox.set(newValue); passwordBox.set(nil) }
    }

    public var adminPasswordURL: URL { paths.keys.appendingPathComponent("guest-account.pw") }
    /// Key for maintenance over SSH as root (installed by the bootstrap).
    public var maintenanceKey: URL { paths.keys.appendingPathComponent("maintenance") }
    /// Key that may only run the orderly shutdown script in the guest.
    public var stopKey: URL { paths.keys.appendingPathComponent("stop") }
    public var knownHosts: URL { paths.keys.appendingPathComponent("known_hosts") }

    /// Files of an earlier aOS that kept the keys in the user's folder (taken over by the helper, then retired).
    public var hasLocalKeys: Bool {
        FileManager.default.fileExists(atPath: maintenanceKey.path) || FileManager.default.fileExists(atPath: adminPasswordURL.path)
    }

    /// The guest account's password. With the helper: the copy `load()` fetched (it throws before that).
    public func adminPassword(createIfMissing: Bool) throws -> String {
        if Self.custody != nil {
            guard let password = Self.passwordBox.get() else { throw CustodyError.notLoaded }
            return password
        }
        if let data = FileManager.default.contents(atPath: adminPasswordURL.path),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        guard createIfMissing else { throw VMBundleError.missing("guest password") }
        let password = Self.randomPassword(length: 32)
        try Data(password.utf8).write(to: adminPasswordURL, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: adminPasswordURL.path)
        return password
    }

    /// Makes sure the keys and the password exist and holds the password in memory; returns it.
    @discardableResult
    public func load() async throws -> String {
        guard let custody = Self.custody else { return try adminPassword(createIfMissing: true) }
        _ = try await custody.prepare()
        let password = try await custody.password()
        Self.passwordBox.set(password)
        return password
    }

    /// After a rotation: the new password in memory.
    static func remember(password: String) { passwordBox.set(password) }

    /// The public keys to install in the guest (made when missing).
    public func publicKeys() async throws -> (maintenance: String, stop: String) {
        if let custody = Self.custody { return try await custody.prepare() }
        try SSH.ensureKey(maintenanceKey, comment: "\(Brand.mcpServerName)-maintenance")
        try SSH.ensureKey(stopKey, comment: "\(Brand.mcpServerName)-stop")
        return (try SSH.publicKey(maintenanceKey), try SSH.publicKey(stopKey))
    }

    /// Typed into the guest as key presses (the workspace window sends key codes, which the guest reads with
    /// its own keyboard layout) and passed to sudo. So only letters that sit on the same key in the common
    /// layouts (US/ABC, German QWERTZ, French AZERTY): no a, q, w, y, z, m and no digits (Shift on AZERTY).
    /// 40 characters, 32 of them: about 170 bits.
    static let passwordAlphabet = Array("bcdefghijklnoprstuvxBCDEFGHIJKLNOPRSTUVX")

    public static func randomPassword(length: Int) -> String {
        let alphabet = passwordAlphabet
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        // Rejection sampling keeps the distribution uniform.
        var result = ""
        var pool = bytes
        while result.count < length {
            for b in pool where result.count < length {
                let limit = 256 - (256 % alphabet.count)
                if Int(b) < limit { result.append(alphabet[Int(b) % alphabet.count]) }
            }
            pool = [UInt8](repeating: 0, count: length)
            _ = SecRandomCopyBytes(kSecRandomDefault, length, &pool)
        }
        return result
    }
}
