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
        try await user.run("umask 077; /bin/cat > \"$HOME/.aos-bootstrap.sh\"", input: Data(script.utf8),
                           what: "upload of the setup kit")
        log("setting up the guest (Chrome download included, a few minutes)")
        let result = try await user.run(
            "/usr/bin/sudo -S -p '' /bin/zsh -f \"$HOME/.aos-bootstrap.sh\"; rc=$?; " +
            "/bin/rm -f \"$HOME/.aos-bootstrap.sh\"; exit $rc",
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
        let fingerprint = try? kit.fingerprint()
        try VMBundle(url: paths.vm).updateState { $0.bootstrapped = true; $0.kitFingerprint = fingerprint }
        log("guest ready (maintenance over SSH with the host's key)")
    }

    /// Brings the scripts and Chrome policies of a set-up guest up to date (after an app update or a settings
    /// change), if its kit fingerprint differs. Keys and accounts stay as they are.
    public func updateIfNeeded(host: String, log: @Sendable (String) -> Void) async throws {
        let bundle = VMBundle(url: paths.vm)
        let current = try kit.fingerprint()
        guard try bundle.loadState().kitFingerprint != current else { return }
        log("updating the workspace's scripts and browser policies")
        try await maintenance(host: host).waitUntilReachable(timeout: 180)
        let script = GuestKit.bundleScript(files: try kit.updateFiles(), entry: "update.sh")
        try await maintenance(host: host).run("/bin/zsh -f -s", input: Data(script.utf8), timeout: 120, what: "workspace update")
        try bundle.updateState { $0.kitFingerprint = current }
    }

    /// After a cold boot, before the agent gets the screen: waits for the login, puts the browser policies in place
    /// and quits a Chrome that macOS reopened without them (see Resources/Guest/prepare.sh).
    public func prepareSession(host: String) async throws {
        let root = maintenance(host: host)
        try await root.waitUntilReachable(timeout: 180)
        try await root.run("/bin/zsh -f \(GuestKit.libexec)/prepare.sh", timeout: 180, what: "workspace preparation")
    }

    // MARK: The workspace helper's permission

    /// The helper's state (nil: not installed yet or not answering).
    public func helperStatus(host: String) async -> GuestHelper.Status? {
        try? await GuestHelper(provisioner: self, host: host).status()
    }

    /// Lets the user allow the helper: it asks macOS once (so it shows up in the list, macOS shows its own question),
    /// then System Settings opens at Privacy & Security > Accessibility in the guest. Changing that list needs an
    /// administrator: a finished workspace's account becomes one until `endHelperPermission`. Returns whether it was
    /// one before.
    public func beginHelperPermission(host: String) async throws -> Bool {
        let root = maintenance(host: host)
        let user = Brand.guestUser
        let wasAdmin = try await root.run("dseditgroup -o checkmember -m \(user) admin | grep -q '^yes'",
                                          timeout: 30, check: false, what: "administrator check").status == 0
        if !wasAdmin {
            try await root.run("dseditgroup -o edit -a \(user) -t user admin", timeout: 30, what: "temporary administrator")
        }
        let _: GuestHelper.Status? = try? await GuestHelper(provisioner: self, host: host).call(["op": "prompt"], timeout: 20)
        try await root.run("launchctl asuser \"$(id -u \(user))\" sudo -u \(user) /usr/bin/open " +
                           "'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'",
                           timeout: 30, what: "open the Accessibility settings")
        return wasAdmin
    }

    static let securityAgent = "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"
    static let localAuthenticationService = "/System/Library/PrivateFrameworks/LocalAuthenticationUI.framework/Versions/A/XPCServices/LocalAuthenticationRemoteService.xpc/Contents/MacOS/LocalAuthenticationRemoteService"

    /// While the user allows the helper: whether macOS shows its password dialog and whether the
    /// helper is allowed already, in one round trip.
    static let coreAuthAgent = "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"

    /// Prints DIALOG while macOS shows a password dialog on the workspace's screen: an on-screen window that belongs
    /// to one of macOS's own dialog programs (System Settings asks through LocalAuthenticationUI, other requests
    /// through coreautha or SecurityAgent). Not the programs alone: they keep running for a while after a dialog
    /// closed (measured: still there after 4 s, gone after 30 s), and typing then goes to whatever has the focus.
    /// By the program's path, not its name (any process can call itself LocalAuthenticationRemoteService).
    static var dialogCheck: String {
        let jxa = "ObjC.import(\"CoreGraphics\"); var l=ObjC.castRefToObject($.CGWindowListCopyWindowInfo(" +
            "$.kCGWindowListOptionOnScreenOnly,0)); var o=[]; for(var i=0;i<l.count;i++){" +
            "o.push(l.objectAtIndex(i).objectForKey(\"kCGWindowOwnerPID\").js)}; o.join(\" \")"
        return "u=\(Brand.guestUser); for p in $(launchctl asuser $(id -u $u) sudo -u $u /usr/bin/osascript -l JavaScript " +
            "-e '\(jxa)' 2>/dev/null); do case \"$(ps -o comm= -p $p)\" in " +
            "'\(securityAgent)'|'\(localAuthenticationService)'|'\(coreAuthAgent)') echo DIALOG; break;; esac; done"
    }

    public func helperPermissionPoll(host: String) async -> (passwordDialog: Bool, trusted: Bool) {
        let command = Self.dialogCheck + "; echo '{\"op\":\"status\"}' | \(GuestHelper.executable) client"
        guard let r = try? await maintenance(host: host).run(command, timeout: 20, check: false, what: "helper status")
        else { return (false, false) }
        let lines = r.text.split(separator: "\n").map(String.init)
        let status = lines.last.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(GuestHelper.Status.self, from: $0) }
        return (lines.contains("DIALOG"), status?.trusted == true)
    }

    /// Ends `beginHelperPermission`: the account is a standard user again (if it was one), System Settings closes.
    public func endHelperPermission(host: String, wasAdmin: Bool) async throws {
        let root = maintenance(host: host)
        if !wasAdmin {
            try await root.run("dseditgroup -o edit -d \(Brand.guestUser) -t user admin", timeout: 30,
                               what: "standard user again")
        }
        _ = try? await root.run("pkill -x 'System Settings'", timeout: 15, check: false, what: "close System Settings")
        // Allowed now: the helper closes the notices that covered the screen
        let _: GuestHelper.FillResult? = try? await GuestHelper(provisioner: self, host: host)
            .call(["op": "dismiss-notifications"], timeout: 20)
    }

    /// Whether screen sharing is switched on in the guest.
    public func screenSharingEnabled(host: String) async throws -> Bool {
        let r = try await maintenance(host: host).run(
            "launchctl print-disabled system | grep -q '\"com.apple.screensharing\" => enabled'",
            timeout: 30, check: false, what: "screen sharing check")
        return r.status == 0
    }

    /// Opens the Sharing settings in the guest's session, at screen sharing, and returns once they are on screen
    /// (the first time after a boot that takes a while: the user is told to wait until then). Notices left from
    /// the login ("background items added") go first, they would cover the switches.
    public func openSharingSettings(host: String) async throws {
        try await maintenance(host: host).run(
            "u=\(Brand.guestUser); pkill -u $u -x NotificationCenter; sleep 1; " +
            "launchctl asuser \"$(id -u $u)\" sudo -u $u /usr/bin/open " +
            "'x-apple.systempreferences:com.apple.Sharing-Settings.extension'; " +
            "for i in {1..90}; do pgrep -x SharingPrefsExtension >/dev/null && break; sleep 0.5; done; sleep 2",
            timeout: 90, what: "open Sharing settings")
    }

    /// Whether macOS shows its password dialog in the workspace right now (by the program's path, as above).
    public func passwordDialogOpen(host: String) async -> Bool {
        let r = try? await maintenance(host: host).run(Self.dialogCheck, timeout: 15, check: false, what: "password dialog")
        return r?.text.contains("DIALOG") == true
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
