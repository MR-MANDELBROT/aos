import Foundation
import Security

/// Secrets that belong to the VM only: the password of the guest account (needed once, for the first
/// SSH login and the screen sharing switch) and the SSH keys the agent uses to maintain the guest.
/// They live in the private Keys folder (0700, files 0600). None of them is a credential of the user.
public struct GuestSecrets: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public var adminPasswordURL: URL { paths.keys.appendingPathComponent("guest-account.pw") }
    /// Key for maintenance over SSH as root (installed by the bootstrap).
    public var maintenanceKey: URL { paths.keys.appendingPathComponent("maintenance") }
    /// Key that may only run the orderly shutdown script in the guest.
    public var stopKey: URL { paths.keys.appendingPathComponent("stop") }
    public var knownHosts: URL { paths.keys.appendingPathComponent("known_hosts") }

    /// The guest account's password; created (random, 32 characters) on first use.
    public func adminPassword(createIfMissing: Bool) throws -> String {
        if let data = FileManager.default.contents(atPath: adminPasswordURL.path),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        guard createIfMissing else { throw VMBundleError.missing("guest password") }
        let password = Self.randomPassword(length: 32)
        try Data(password.utf8).write(to: adminPasswordURL, options: [.atomic, .withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: adminPasswordURL.path)
        return password
    }

    /// Letters and digits only: typed into the guest over VNC and passed to sudo, so nothing that a
    /// keyboard layout or a shell could change.
    static func randomPassword(length: Int) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
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
