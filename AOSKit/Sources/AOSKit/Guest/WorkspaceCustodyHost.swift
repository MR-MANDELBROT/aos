import Foundation

/// Refuses mounting (and ejecting, except by the helper) the volumes of the attached workspace disk. aos-powerd
/// implements it with Disk Arbitration (macOS lets an administrator on the console mount any attached volume).
public protocol DiskGuarding: AnyObject, Sendable {
    /// The whole disks (e.g. "disk10") to guard; everything on them and in APFS containers inside them.
    func guardDisks(_ names: Set<String>)
    /// While true, every disk image's volumes are refused (between `hdiutil attach` and knowing the name).
    func setAttaching(_ attaching: Bool)
    /// The helper itself detaches this disk now.
    func allowEject(_ name: String)
}

/// Attaches the image as a device (aos-powerd: hdiutil, not mounted).
public protocol DiskAttaching: Sendable {
    /// Returns the whole disk's name ("disk10").
    func attach(_ image: URL) throws -> String
    func detach(_ name: String, force: Bool) -> Bool
    /// Names of devices that are attached from this image now (after the helper restarted).
    func attached(_ image: URL) -> [String]
}

/// The helper's side of `WorkspaceCustodyClient` (runs as root in aos-powerd; see WorkspaceCustody.swift).
public final class WorkspaceCustodyHost: @unchecked Sendable {
    public struct Layout: Sendable {
        /// /Library/Application Support/aOS (root, 0755).
        public var base: URL
        /// Keys, password and pinned host key: the hidden user's folder (0700).
        public var keys: URL { base.appendingPathComponent("WorkspaceKeys", isDirectory: true) }
        /// The disk image: root only (0700, the image 0600).
        public var diskFolder: URL { base.appendingPathComponent("Workspace", isDirectory: true) }
        public var diskImage: URL { diskFolder.appendingPathComponent("disk.img") }
        /// Present while the next connection may pin a new host key (a disk this helper created or took over).
        public var pinOpen: URL { diskFolder.appendingPathComponent("pin-open") }
        /// Present while keys taken over from an earlier aOS wait to be replaced.
        public var rotationNeeded: URL { diskFolder.appendingPathComponent("rotation-needed") }
        /// Prints the password for ssh (root, 0755: the hidden user can run it, not change it).
        public var askpass: URL { base.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("aos-askpass") }

        public func key(_ name: String) -> URL { keys.appendingPathComponent(name) }
        public var knownHosts: URL { key("known_hosts") }
        public var password: URL { key("password") }

        public init(base: URL) { self.base = base }
    }

    public static let userName = "_aosworkspace"
    /// The name the workspace's host key is pinned under, whatever its address.
    public static let hostAlias = "aos-workspace"
    static let keyNames = ["maintenance", "maintenance.pub", "stop", "stop.pub", "password"]
    /// The waiting file of `name` ("maintenance.next", "maintenance.next.pub": ssh-keygen adds the ".pub").
    static func next(_ name: String) -> String {
        name.hasSuffix(".pub") ? String(name.dropLast(4)) + ".next.pub" : name + ".next"
    }

    let layout: Layout
    /// The user ssh runs as (nil in tests: as this process).
    let account: () throws -> Subprocess.RunAs?
    let attacher: DiskAttaching
    weak var diskGuard: DiskGuarding?
    var log: (String) -> Void
    let sshPath: String
    /// The guest account's name (the bootstrap logs in with its password).
    let guestUser: String
    /// The home folder of a user id (where an earlier aOS kept the disk image).
    let home: (uid_t) -> URL?

    private let lock = NSLock()
    /// The attached disk and the process it was attached for.
    private var attachedDisk: (name: String, owner: pid_t)?

    public init(layout: Layout, account: @escaping () throws -> Subprocess.RunAs?, attacher: DiskAttaching,
                diskGuard: DiskGuarding? = nil, sshPath: String = "/usr/bin/ssh", guestUser: String = Brand.guestUser,
                home: @escaping (uid_t) -> URL? = WorkspaceCustodyHost.homeFolder,
                log: @escaping (String) -> Void = { _ in }) {
        self.layout = layout
        self.account = account
        self.attacher = attacher
        self.diskGuard = diskGuard
        self.sshPath = sshPath
        self.guestUser = guestUser
        self.home = home
        self.log = log
    }

    public static func homeFolder(_ uid: uid_t) -> URL? {
        guard let pw = getpwuid(uid) else { return nil }
        return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true)
    }

    public var isAttached: Bool { lock.withLock { attachedDisk != nil } }

    // MARK: Requests

    public func handle(_ request: CustodyRequest, caller: uid_t, pid: pid_t) async -> (CustodyReply, FileHandle?) {
        do {
            switch request.op {
            case .status: return (status(), nil)
            case .prepare: return (try prepare(), nil)
            case .password:
                var r = CustodyReply(ok: true)
                r.password = try read(layout.password)
                return (r, nil)
            case .ssh: return (try await ssh(request), nil)
            case .importLegacy: return (try importLegacy(request.files ?? [:]), nil)
            case .pin: return (try pin(request.files?["known_hosts"] ?? Data()), nil)
            case .rotateBegin: return (try rotateBegin(), nil)
            case .rotateCommit: return (try rotateCommit(keepPassword: request.keepPassword ?? false), nil)
            case .rotateAbort:
                for name in Self.keyNames { try? FileManager.default.removeItem(at: layout.key(Self.next(name))) }
                return (CustodyReply(ok: true), nil)
            case .createDisk: return (try createDisk(gibibytes: request.gibibytes ?? 64, replace: request.replace ?? false), nil)
            case .adoptDisk: return (try adoptDisk(caller: caller), nil)
            case .attachDisk:
                let handle = try attachDisk(owner: pid)
                return (CustodyReply(ok: true), handle)
            case .detachDisk:
                detachDisk()
                return (CustodyReply(ok: true), nil)
            case .eraseDisk: return (try eraseDisk(), nil)
            }
        } catch {
            log("workspace: \(request.op.rawValue) failed: \(error.localizedDescription)")
            return (.failure(error.localizedDescription), nil)
        }
    }

    func status() -> CustodyReply {
        let fm = FileManager.default
        var r = CustodyReply(ok: true)
        // The helper holds the secrets once it has the password (the keys follow with `prepare`).
        r.hasKeys = fm.fileExists(atPath: layout.password.path)
        r.hasDisk = fm.fileExists(atPath: layout.diskImage.path)
        r.attached = isAttached
        r.pinned = pinned()
        r.rotating = fm.fileExists(atPath: layout.key("maintenance.next").path)
        r.rotationNeeded = fm.fileExists(atPath: layout.rotationNeeded.path)
        return r
    }

    // MARK: Keys

    func makeFolders(owner: Subprocess.RunAs?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(at: layout.keys, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let owner, chown(layout.keys.path, owner.uid, owner.gid) != 0 {
            throw CustodyError.helper("couldn't hand the keys folder to \(Self.userName)")
        }
        chmod(layout.keys.path, 0o700)
        try fm.createDirectory(at: layout.diskFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(layout.diskFolder.path, 0o700)
        // Only root may change the script ssh runs to get the password.
        let bin = layout.askpass.deletingLastPathComponent()
        try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let script = "#!/bin/sh\nexec /bin/cat \"\(layout.password.path)\"\n"
        if (try? String(contentsOf: layout.askpass, encoding: .utf8)) != script {
            try Data(script.utf8).write(to: layout.askpass, options: .atomic)
        }
        chmod(layout.askpass.path, 0o755)
    }

    /// Writes a secret file of the hidden user (0600), never over an existing one.
    func writeSecret(_ data: Data, to url: URL, owner: Subprocess.RunAs?, mode: mode_t = 0o600) throws {
        let fm = FileManager.default
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        guard fm.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw CustodyError.helper("couldn't write \(url.lastPathComponent)")
        }
        if let owner { _ = chown(staged.path, owner.uid, owner.gid) }
        chmod(staged.path, mode)
        guard rename(staged.path, url.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw CustodyError.helper("couldn't put \(url.lastPathComponent) in place")
        }
    }

    func read(_ url: URL) throws -> String {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { throw CustodyError.helper("\(url.lastPathComponent) is missing") }
        return text
    }

    func keygen(_ url: URL, comment: String, owner: Subprocess.RunAs?) throws {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("pub"))
        let r = try Subprocess.runBlocking("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment,
                                                                    "-f", url.path],
                                           environment: ["PATH": "/usr/bin:/bin", "HOME": layout.keys.path],
                                           cwd: layout.keys.path, runAs: owner, timeout: 30)
        guard r.status == 0 else { throw CustodyError.helper("ssh-keygen failed") }
    }

    func publicKeys(next: Bool = false) throws -> (String, String) {
        let names = next ? (Self.next("maintenance.pub"), Self.next("stop.pub")) : ("maintenance.pub", "stop.pub")
        return (try read(layout.key(names.0)), try read(layout.key(names.1)))
    }

    /// The hidden user, the folders, the keys and the password, each made once.
    func prepare() throws -> CustodyReply {
        let who = try account()
        try makeFolders(owner: who)
        let fm = FileManager.default
        if !fm.fileExists(atPath: layout.key("maintenance").path) {
            try keygen(layout.key("maintenance"), comment: "\(Brand.mcpServerName)-maintenance", owner: who)
            log("workspace: maintenance key made")
        }
        if !fm.fileExists(atPath: layout.key("stop").path) {
            try keygen(layout.key("stop"), comment: "\(Brand.mcpServerName)-stop", owner: who)
        }
        if !fm.fileExists(atPath: layout.password.path) {
            try writeSecret(Data(GuestSecrets.randomPassword(length: 32).utf8), to: layout.password, owner: who)
            log("workspace: account password made")
        }
        var r = status()
        (r.maintenancePublicKey, r.stopPublicKey) = try publicKeys()
        return r
    }

    /// Keys, password and known hosts of an earlier aOS (files of the user): they become the helper's, and are
    /// replaced at the workspace's next start (`rotationNeeded`). Only while the helper has none of its own.
    func importLegacy(_ files: [String: Data]) throws -> CustodyReply {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: layout.key("maintenance").path), !fm.fileExists(atPath: layout.password.path) else {
            throw CustodyError.helper("the helper has keys already")
        }
        // A workspace made by an earlier aOS pins its host key from that version's known hosts below.
        // The password is there from the setup's start; the keys only once the bootstrap made them.
        for (name, data) in files {
            guard ["maintenance", "maintenance.pub", "stop", "stop.pub", "password", "known_hosts"].contains(name),
                  !data.isEmpty, data.count < 65_536 else { throw CustodyError.helper("unexpected file \(name)") }
        }
        guard files["password"] != nil else { throw CustodyError.helper("password missing") }
        let keys = ["maintenance", "maintenance.pub", "stop", "stop.pub"]
        let withKeys = keys.allSatisfy { files[$0] != nil }
        if withKeys {
            guard String(decoding: files["maintenance.pub"]!, as: UTF8.self).hasPrefix("ssh-ed25519 "),
                  String(decoding: files["stop.pub"]!, as: UTF8.self).hasPrefix("ssh-ed25519 ") else {
                throw CustodyError.helper("unexpected key type")
            }
        }
        let who = try account()
        try makeFolders(owner: who)
        try writeSecret(files["password"]!, to: layout.password, owner: who)
        if withKeys {
            for name in ["maintenance", "stop"] { try writeSecret(files[name]!, to: layout.key(name), owner: who) }
            for name in ["maintenance.pub", "stop.pub"] {
                try writeSecret(files[name]!, to: layout.key(name), owner: who, mode: 0o644)
            }
        }
        if let known = files["known_hosts"], !pinned() {
            let lines = Self.pinLines(fromKnownHosts: String(decoding: known, as: UTF8.self))
            if !lines.isEmpty {
                try writeSecret(Data((lines.joined(separator: "\n") + "\n").utf8), to: layout.knownHosts, owner: who,
                                mode: 0o644)
                try? fm.removeItem(at: layout.pinOpen)
            }
        }
        if withKeys {
            fm.createFile(atPath: layout.rotationNeeded.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        log("workspace: keys of an earlier version taken over" + (withKeys ? " (to be replaced at the next start)" : ""))
        return status()
    }

    /// Pins the workspace's host key from an earlier aOS's known hosts, as long as none is pinned.
    func pin(_ knownHosts: Data) throws -> CustodyReply {
        guard !pinned() else { throw CustodyError.helper("a host key is pinned already") }
        guard knownHosts.count < 65_536 else { throw CustodyError.helper("too large") }
        let lines = Self.pinLines(fromKnownHosts: String(decoding: knownHosts, as: UTF8.self))
        guard !lines.isEmpty else { throw CustodyError.helper("no host key in it") }
        let who = try account()
        try makeFolders(owner: who)
        try writeSecret(Data((lines.joined(separator: "\n") + "\n").utf8), to: layout.knownHosts, owner: who, mode: 0o644)
        try? FileManager.default.removeItem(at: layout.pinOpen)
        log("workspace: host key pinned from an earlier version's known hosts")
        return status()
    }

    /// The host keys of a known_hosts file whose host is an IPv4 address (the workspace's), under the fixed name.
    static func pinLines(fromKnownHosts text: String) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3, !parts[0].hasPrefix("#"), !parts[0].hasPrefix("|"),
                  parts[0].split(separator: ",").allSatisfy({ isIPv4(String($0)) }),
                  parts[1].hasPrefix("ssh-") || parts[1].hasPrefix("ecdsa-") else { continue }
            let entry = "\(hostAlias) \(parts[1]) \(parts[2])"
            if seen.insert(entry).inserted { lines.append(entry) }
        }
        return lines
    }

    func rotateBegin() throws -> CustodyReply {
        let fm = FileManager.default
        guard fm.fileExists(atPath: layout.key("maintenance").path) else { throw CustodyError.helper("no keys yet") }
        let who = try account()
        try makeFolders(owner: who)
        if !fm.fileExists(atPath: layout.key("maintenance.next").path)
            || !fm.fileExists(atPath: layout.key("stop.next").path)
            || !fm.fileExists(atPath: layout.key("password.next").path) {
            try keygen(layout.key("maintenance.next"), comment: "\(Brand.mcpServerName)-maintenance", owner: who)
            try keygen(layout.key("stop.next"), comment: "\(Brand.mcpServerName)-stop", owner: who)
            try writeSecret(Data(GuestSecrets.randomPassword(length: 32).utf8), to: layout.key("password.next"), owner: who)
            log("workspace: new keys and password made (not in use yet)")
        }
        var r = status()
        r.password = try read(layout.password)
        r.nextPassword = try read(layout.key("password.next"))
        (r.nextMaintenancePublicKey, r.nextStopPublicKey) = try publicKeys(next: true)
        return r
    }

    func rotateCommit(keepPassword: Bool) throws -> CustodyReply {
        let fm = FileManager.default
        for name in Self.keyNames {
            guard fm.fileExists(atPath: layout.key(Self.next(name)).path) else { throw CustodyError.helper("nothing to commit") }
        }
        if keepPassword { try? fm.removeItem(at: layout.key("password.next")) }
        // The `.pub` files go first: a key without its matching private key would be worse than the other way round.
        for name in ["maintenance.pub", "stop.pub", "maintenance", "stop"] + (keepPassword ? [] : ["password"]) {
            guard rename(layout.key(Self.next(name)).path, layout.key(name).path) == 0 else {
                throw CustodyError.helper("couldn't put \(name) in place")
            }
        }
        try? fm.removeItem(at: layout.rotationNeeded)
        log("workspace: new keys and password in use")
        return status()
    }

    // MARK: SSH

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCII) && p.allSatisfy(\.isNumber) && Int(p).map { $0 <= 255 } == true
        }
    }

    func pinned() -> Bool {
        guard let text = try? String(contentsOf: layout.knownHosts, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains { $0.hasPrefix(Self.hostAlias + " ") }
    }

    func sshArguments(_ request: CustodyRequest, acceptNew: Bool) throws -> [String] {
        guard let host = request.host, Self.isIPv4(host) else { throw CustodyError.helper("not a workspace address") }
        guard let user = request.user, user == "root" || user == guestUser else { throw CustodyError.helper("not allowed") }
        guard let command = request.command, !command.isEmpty, command.utf8.count < 65_536 else {
            throw CustodyError.helper("no command")
        }
        guard let key = request.key else { throw CustodyError.helper("no key") }
        var args = [
            "-F", "/dev/null",
            // Quoted: ssh splits this value at spaces ("Application Support") into several files.
            "-o", "UserKnownHostsFile=\"\(layout.knownHosts.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(Self.hostAlias)",
            "-o", "StrictHostKeyChecking=\(acceptNew ? "accept-new" : "yes")",
            "-o", "CheckHostIP=no",
            "-o", "UpdateHostKeys=no",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
            "-o", "IdentityAgent=none",
        ]
        switch key {
        case .password:
            guard user == guestUser else { throw CustodyError.helper("not allowed") }
            args += ["-o", "PubkeyAuthentication=no",
                     "-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "NumberOfPasswordPrompts=1"]
        case .maintenance, .stop, .next:
            guard user == "root" else { throw CustodyError.helper("not allowed") }
            let file = layout.key(key == .stop ? "stop" : key == .next ? "maintenance.next" : "maintenance")
            guard FileManager.default.fileExists(atPath: file.path) else { throw CustodyError.helper("no such key") }
            args += ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", file.path]
        }
        args += ["-l", user, "--", host, command]
        return args
    }

    func ssh(_ request: CustodyRequest) async throws -> CustodyReply {
        let fm = FileManager.default
        let acceptNew = !pinned() && fm.fileExists(atPath: layout.pinOpen.path)
        let args = try sshArguments(request, acceptNew: acceptNew)
        guard (request.input?.count ?? 0) <= 64 << 20 else { throw CustodyError.helper("input too large") }
        let who = try account()
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "HOME": layout.keys.path]
        if who != nil { env["USER"] = Self.userName; env["LOGNAME"] = Self.userName }
        if request.key == .password {
            env["SSH_ASKPASS"] = layout.askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = "aos"
        }
        let result = try await Subprocess.run(sshPath, args, environment: env, cwd: layout.keys.path,
                                              input: request.input ?? Data(), runAs: who,
                                              timeout: min(max(request.timeout ?? 120, 5), 1800))
        if acceptNew && pinned() {
            try? fm.removeItem(at: layout.pinOpen)
            log("workspace: host key pinned")
        }
        var r = CustodyReply(ok: true)
        r.status = result.status
        r.stdout = result.stdout
        r.stderr = String(String(decoding: result.stderr, as: UTF8.self).suffix(4096))
        r.timedOut = result.timedOut
        return r
    }

    // MARK: The disk

    func createDisk(gibibytes: UInt64, replace: Bool) throws -> CustodyReply {
        guard (16...2048).contains(gibibytes) else { throw CustodyError.helper("unusual disk size") }
        guard !isAttached else { throw CustodyError.helper("the disk is in use") }
        try makeFolders(owner: try account())
        let fm = FileManager.default
        if fm.fileExists(atPath: layout.diskImage.path) {
            guard replace else { throw CustodyError.helper("a workspace disk exists already") }
            try fm.removeItem(at: layout.diskImage)
            log("workspace: the old disk was removed for a new one")
        }
        guard fm.createFile(atPath: layout.diskImage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CustodyError.helper("couldn't create the disk")
        }
        let handle = try FileHandle(forWritingTo: layout.diskImage)
        defer { try? handle.close() }
        try handle.truncate(atOffset: gibibytes * 1024 * 1024 * 1024)
        // A new workspace has a new host key: its first connection pins it.
        try? fm.removeItem(at: layout.knownHosts)
        fm.createFile(atPath: layout.pinOpen.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        log("workspace: new disk (\(gibibytes) GiB)")
        return status()
    }

    /// The folder an earlier aOS kept the workspace in, for the calling user.
    func legacyDisk(caller: uid_t) -> URL? {
        home(caller)?.appendingPathComponent("Library/Application Support/\(Brand.name)/VM/disk.img")
    }

    func adoptDisk(caller: uid_t) throws -> CustodyReply {
        guard caller != 0, let legacy = legacyDisk(caller: caller) else { throw CustodyError.helper("unknown user") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: layout.diskImage.path) else { throw CustodyError.helper("the helper has a disk already") }
        var st = stat()
        guard lstat(legacy.path, &st) == 0 else { throw CustodyError.helper("no disk of an earlier version") }
        // A plain file of that user, no link: nothing else can be pulled in this way.
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == caller, st.st_nlink == 1 else {
            throw CustodyError.helper("the earlier disk isn't a plain file of this user")
        }
        try makeFolders(owner: try account())
        guard rename(legacy.path, layout.diskImage.path) == 0 else {
            throw CustodyError.helper("couldn't move the disk (\(String(cString: strerror(errno))))")
        }
        _ = chown(layout.diskImage.path, 0, 0)
        chmod(layout.diskImage.path, 0o600)
        // Without a host key from the earlier version (`pin`), the first connection pins it.
        if !pinned() {
            fm.createFile(atPath: layout.pinOpen.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        log("workspace: took over the disk of an earlier version")
        return status()
    }

    func attachDisk(owner: pid_t) throws -> FileHandle {
        guard FileManager.default.fileExists(atPath: layout.diskImage.path) else { throw CustodyError.helper("no workspace disk") }
        let name: String
        if let current = lock.withLock({ attachedDisk?.name }), FileManager.default.fileExists(atPath: "/dev/\(current)") {
            name = current
        } else {
            diskGuard?.setAttaching(true)
            defer { diskGuard?.setAttaching(false) }
            name = try attacher.attach(layout.diskImage)
            diskGuard?.guardDisks([name])
            log("workspace: disk attached as \(name)")
        }
        lock.withLock { attachedDisk = (name, owner) }
        let fd = open("/dev/r\(name)", O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw CustodyError.helper("couldn't open the disk (\(String(cString: strerror(errno))))")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func detachDisk() {
        guard let name = lock.withLock({ attachedDisk?.name }) else { return }
        diskGuard?.allowEject(name)
        var done = attacher.detach(name, force: false)
        if !done {
            Thread.sleep(forTimeInterval: 2)
            done = attacher.detach(name, force: true)
        }
        if done {
            lock.withLock { attachedDisk = nil }
            diskGuard?.guardDisks([])
            log("workspace: disk detached")
        } else {
            log("workspace: couldn't detach \(name)")
        }
    }

    /// The app that attached the disk is gone (quit or crashed; its VM with it).
    public func processEnded(_ pid: pid_t) {
        guard lock.withLock({ attachedDisk?.owner == pid }) else { return }
        log("workspace: the app ended, detaching the disk")
        detachDisk()
    }

    /// After the helper started again: guard a disk that is still attached from an earlier run.
    public func recover() {
        guard let name = attacher.attached(layout.diskImage).first else { return }
        lock.withLock { attachedDisk = (name, 0) }
        diskGuard?.guardDisks([name])
        log("workspace: disk \(name) is still attached, guarded again")
    }

    func eraseDisk() throws -> CustodyReply {
        if isAttached { detachDisk() }
        guard !isAttached else { throw CustodyError.helper("the disk is in use") }
        let fm = FileManager.default
        try? fm.removeItem(at: layout.diskImage)
        try? fm.removeItem(at: layout.knownHosts)
        fm.createFile(atPath: layout.pinOpen.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        log("workspace: disk removed")
        return status()
    }
}

/// `hdiutil`, as root: raw image, no mount, no check.
public struct HdiutilAttacher: DiskAttaching {
    public init() {}

    public func attach(_ image: URL) throws -> String {
        let r = try Subprocess.runBlocking("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                                                                 "-nomount", "-noverify", "-noautofsck", "-plist", image.path],
                                           environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 60)
        guard r.status == 0, let name = Self.wholeDisk(fromAttachPlist: r.stdout) else {
            throw CustodyError.helper("hdiutil attach failed: \(String(decoding: r.stderr, as: UTF8.self).prefix(200))")
        }
        return name
    }

    /// The first entity is the whole disk ("/dev/disk10").
    static func wholeDisk(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        let names = entities.compactMap { $0["dev-entry"] as? String }.map { $0.replacingOccurrences(of: "/dev/", with: "") }
        return names.first { $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil }
    }

    public func detach(_ name: String, force: Bool) -> Bool {
        let r = try? Subprocess.runBlocking("/usr/bin/hdiutil", ["detach"] + (force ? ["-force"] : []) + ["/dev/\(name)"],
                                            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 60)
        return r?.status == 0
    }

    public func attached(_ image: URL) -> [String] {
        guard let r = try? Subprocess.runBlocking("/usr/bin/hdiutil", ["info", "-plist"],
                                                  environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 30),
              r.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let path = image.resolvingSymlinksInPath().path
        return images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == path }
            .compactMap { img in
                let names = (img["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
                    .map { $0.replacingOccurrences(of: "/dev/", with: "") }
                return names.first { $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil }
            }
    }
}
