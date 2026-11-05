import Foundation

/// Brings a freshly provisioned guest into shape (see Resources/Guest/setup.sh) and gives access to it
/// afterwards. Steps report progress as short lines.
public struct Provisioner: Sendable {
    public let paths: Paths
    public let secrets: GuestSecrets
    public let kit: GuestKit

    public init(paths: Paths, kit: GuestKit = GuestKit()) {
        self.paths = paths
        self.secrets = GuestSecrets(paths: paths)
        self.kit = kit
    }

    /// Maintenance access (root, key), after the bootstrap.
    public func maintenance(host: String) -> SSH {
        SSH(host: host, auth: .key(user: "root", keyFile: secrets.maintenanceKey), secrets: secrets)
    }

    /// The stop key: runs only the orderly shutdown script in the guest.
    public func stopAccess(host: String) -> SSH {
        SSH(host: host, auth: .key(user: "root", keyFile: secrets.stopKey), secrets: secrets)
    }

    /// First contact: the account's password over SSH, then the kit as root through sudo.
    public func bootstrap(host: String, log: @Sendable (String) -> Void) async throws {
        try SSH.ensureKey(secrets.maintenanceKey, comment: "\(Brand.mcpServerName)-maintenance")
        try SSH.ensureKey(secrets.stopKey, comment: "\(Brand.mcpServerName)-stop")
        let password = try secrets.adminPassword(createIfMissing: false)

        let user = SSH(host: host, auth: .password(user: Brand.guestUser, passwordFile: secrets.adminPasswordURL),
                       secrets: secrets)
        log("waiting for SSH in the guest")
        try await user.waitUntilReachable(timeout: 300)

        let files = try kit.files(maintenancePublicKey: try SSH.publicKey(secrets.maintenanceKey),
                                  stopPublicKey: try SSH.publicKey(secrets.stopKey))
        let script = GuestKit.bundleScript(files: files, entry: "setup.sh")
        log("uploading the setup kit")
        try await user.run("umask 077; /bin/cat > \"$HOME/.annex-bootstrap.sh\"", input: Data(script.utf8),
                           what: "upload of the setup kit")
        log("setting up the guest (Chrome download included, a few minutes)")
        let result = try await user.run(
            "/usr/bin/sudo -S -p '' /bin/zsh -f \"$HOME/.annex-bootstrap.sh\"; rc=$?; " +
            "/bin/rm -f \"$HOME/.annex-bootstrap.sh\"; exit $rc",
            input: Data((password + "\n").utf8), timeout: 1200, what: "guest setup")
        for line in result.text.split(separator: "\n") { log(String(line)) }

        log("checking maintenance access")
        let root = maintenance(host: host)
        let id = try await root.run("id -u", timeout: 30, what: "maintenance login").text
        guard id.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw SSHError.failed("maintenance login", 1, "not root")
        }
        // Password logins must be gone now.
        let probe = try await user.run("true", timeout: 20, check: false, what: "password login probe")
        guard probe.status != 0 else { throw SSHError.failed("SSH lock-down", 1, "password login still works") }
        try VMBundle(url: paths.vm).updateState { $0.bootstrapped = true }
        log("guest ready (maintenance over SSH with the host's key)")
    }

    /// Whether screen sharing is switched on in the guest.
    public func screenSharingEnabled(host: String) async throws -> Bool {
        let r = try await maintenance(host: host).run(
            "launchctl print-disabled system | grep -q '\"com.apple.screensharing\" => enabled'",
            timeout: 30, check: false, what: "screen sharing check")
        return r.status == 0
    }

    /// Opens the Sharing settings in the guest's session, at screen sharing.
    public func openSharingSettings(host: String) async throws {
        try await maintenance(host: host).run(
            "u=\(Brand.guestUser); launchctl asuser \"$(id -u $u)\" sudo -u $u /usr/bin/open " +
            "'x-apple.systempreferences:com.apple.Sharing-Settings.extension'",
            timeout: 30, what: "open Sharing settings")
    }

    /// Makes the account a standard user (after screen sharing works).
    public func finish(host: String) async throws {
        try await maintenance(host: host).run("/bin/zsh -f \(GuestKit.libexec)/finish.sh", timeout: 60,
                                              what: "final setup step")
    }

    /// Orderly shutdown: Chrome quits (and clears what its policies say), then the guest powers off.
    public func shutdown(host: String) async throws {
        _ = try await stopAccess(host: host).run("shutdown", timeout: 60, check: false, what: "shutdown")
    }
}
