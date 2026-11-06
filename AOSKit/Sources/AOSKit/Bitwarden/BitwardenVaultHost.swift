import Foundation

/// The helper's side of `HelperBitwardenRunner` (runs as root in aos-powerd). It keeps Bitwarden away from the
/// user's own processes:
///   - `bw` lives in `tools` (root, 0755): no process of the user can replace it with one that records passwords;
///   - it runs as the hidden user `_aosvault`, so its environment (the session key, the master password) can't be
///     read by the user's processes, and its files (`vault`, 0700 for that user) can't be read or copied either;
///   - the session key stays here (`sessionFile`, root, 0600): commands carry `BitwardenCLI.heldSession`, the helper
///     puts the real key in, and a new key in a reply is replaced by that marker before the reply leaves;
///   - only the commands aOS needs pass, each argument checked (`allowed`).
public final class BitwardenVaultHost: @unchecked Sendable {
    public struct Layout: Sendable {
        /// /Library/Application Support/aOS (root, 0755).
        public var base: URL
        public var tools: URL { base.appendingPathComponent("bin", isDirectory: true) }
        public var executable: URL { tools.appendingPathComponent("bw") }
        /// HOME of `_aosvault`; Bitwarden's files in `data`.
        public var vault: URL { base.appendingPathComponent("Bitwarden", isDirectory: true) }
        public var data: URL { vault.appendingPathComponent("data", isDirectory: true) }
        public var temporary: URL { vault.appendingPathComponent("tmp", isDirectory: true) }
        public var sessionFile: URL { base.appendingPathComponent("bitwarden-session") }

        public init(base: URL) { self.base = base }
    }

    public static let userName = "_aosvault"

    let layout: Layout
    /// The user `bw` runs as (nil in tests: as this process).
    let account: () throws -> Subprocess.RunAs?
    var log: (String) -> Void
    /// A fixed `bw` (tests); otherwise `layout.executable`, downloaded and checked by `prepare`.
    let fixedExecutable: String?

    private let lock = NSLock()
    private var sessions: [String: Login] = [:]

    public init(layout: Layout, account: @escaping () throws -> Subprocess.RunAs?, executable: String? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        self.layout = layout
        self.account = account
        self.fixedExecutable = executable
        self.log = log
    }

    /// A login conversation and its terminal output so far.
    final class Login: @unchecked Sendable {
        let process: Subprocess.Interactive
        let started = Date()
        private let lock = NSLock()
        private var output = Data()
        private var ended = false

        init(process: Subprocess.Interactive) {
            self.process = process
            Task { [weak self] in
                for await chunk in process.terminal { self?.append(chunk) }
                self?.finish()
            }
        }

        func append(_ d: Data) {
            lock.withLock {
                output.append(d)
                // Only the end matters for the prompts; never keep much.
                if output.count > 1 << 20 { output.removeFirst(output.count - (1 << 20)) }
            }
        }
        func finish() { lock.withLock { ended = true } }
        func read(from offset: Int) -> (Data, Int, Bool) {
            lock.withLock {
                let start = min(max(offset, 0), output.count)
                return (output.subdata(in: start..<output.count), output.count, ended)
            }
        }
    }

    public var hasRunningLogin: Bool { lock.withLock { !sessions.isEmpty } }

    // MARK: Requests

    public func handle(_ request: VaultRequest) async -> VaultReply {
        switch request.op {
        case .prepare: return await prepare(update: false)
        case .update: return await prepare(update: true)
        case .run: return await run(request)
        case .start: return start(request)
        case .read:
            guard let login = login(request.id) else { return VaultReply(ok: false, message: "no such login") }
            let (data, offset, ended) = login.read(from: request.offset ?? 0)
            return VaultReply(ok: true, output: data, offset: offset, ended: ended)
        case .send:
            guard let login = login(request.id), let input = request.input, input.count <= 4096 else {
                return VaultReply(ok: false, message: "no such login")
            }
            login.process.send(input)
            return VaultReply(ok: true)
        case .terminate:
            login(request.id)?.process.terminate()
            return VaultReply(ok: true)
        case .result:
            guard let id = request.id, let login = login(id) else { return VaultReply(ok: false, message: "no such login") }
            let result = await login.process.result()
            _ = lock.withLock { sessions.removeValue(forKey: id) }
            return reply(for: result, arguments: ["login"])
        case .forget:
            forgetSession()
            return VaultReply(ok: true)
        case .erase:
            forgetSession()
            try? FileManager.default.removeItem(at: layout.data)
            try? FileManager.default.removeItem(at: layout.temporary)
            log("vault: Bitwarden's files removed")
            return VaultReply(ok: true)
        }
    }

    private func login(_ id: String?) -> Login? {
        guard let id else { return nil }
        return lock.withLock { sessions[id] }
    }

    // MARK: Prepare

    /// The hidden user, the folders, `bw` (downloaded and checked when missing or asked to), its version.
    func prepare(update: Bool) async -> VaultReply {
        do {
            let who = try account()
            try makeFolders(owner: who)
            let path: String
            if let fixedExecutable {
                path = fixedExecutable
            } else {
                if update || BitwardenTool.verify(layout.executable.path) != nil {
                    log("vault: downloading Bitwarden's command line tool")
                    let paths = Paths(root: layout.base)
                    _ = try await BitwardenTool.install(paths, shared: true)
                    log("vault: Bitwarden's command line tool is in place (signed by Bitwarden)")
                }
                path = layout.executable.path
            }
            let version = try? await Subprocess.run(path, ["--version"], environment: environment(nil, who: who),
                                                    cwd: layout.vault.path, runAs: who, timeout: 60)
            let text = version.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            return VaultReply(ok: true, version: text, session: storedSession() != nil)
        } catch {
            log("vault: not ready: \(error.localizedDescription)")
            return VaultReply(ok: false, message: error.localizedDescription)
        }
    }

    func makeFolders(owner: Subprocess.RunAs?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for dir in [layout.vault, layout.data, layout.temporary] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let owner {
                guard chown(dir.path, owner.uid, owner.gid) == 0 else {
                    throw BitwardenError.notRunnable("couldn't hand \(dir.lastPathComponent) to \(Self.userName)")
                }
            }
            chmod(dir.path, 0o700)
        }
    }

    // MARK: Commands

    func run(_ request: VaultRequest) async -> VaultReply {
        guard let arguments = request.arguments, Self.allowed(arguments) else {
            return VaultReply(ok: false, message: "command not allowed")
        }
        do {
            let who = try account()
            let result = try await Subprocess.run(executable, arguments, environment: environment(request.environment, who: who),
                                                  cwd: layout.vault.path, secret: request.secret, runAs: who,
                                                  timeout: min(request.timeout ?? 120, 600))
            if arguments.first == "lock" || arguments.first == "logout" { forgetSession() }
            return reply(for: result, arguments: arguments)
        } catch {
            return VaultReply(ok: false, message: error.localizedDescription)
        }
    }

    func start(_ request: VaultRequest) -> VaultReply {
        guard let arguments = request.arguments, arguments.first == "login", Self.allowed(arguments) else {
            return VaultReply(ok: false, message: "command not allowed")
        }
        do {
            let who = try account()
            let process = try Subprocess.interactive(executable, arguments,
                                                     environment: environment(request.environment, who: who),
                                                     cwd: layout.vault.path, secret: request.secret, runAs: who,
                                                     timeout: min(request.timeout ?? 900, 1200))
            let id = UUID().uuidString
            lock.withLock {
                // At most one sign-in at a time.
                for (_, old) in sessions { old.process.terminate() }
                sessions = [id: Login(process: process)]
            }
            return VaultReply(ok: true, id: id)
        } catch {
            return VaultReply(ok: false, message: error.localizedDescription)
        }
    }

    var executable: String { fixedExecutable ?? layout.executable.path }

    /// A fresh environment: `bw`'s own folders, and from the app only what changes how `bw` answers. The session
    /// key only as the marker, which becomes the key kept here.
    func environment(_ requested: [String: String]?, who: Subprocess.RunAs?) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": layout.vault.path,
            "TMPDIR": layout.temporary.path + "/",
            "BITWARDENCLI_APPDATA_DIR": layout.data.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        if who != nil { env["USER"] = Self.userName; env["LOGNAME"] = Self.userName }
        for key in ["BW_RESPONSE", "BW_NOINTERACTION", "TERM"] {
            if let value = requested?[key], value.count < 64 { env[key] = value }
        }
        if requested?["BW_SESSION"] == BitwardenCLI.heldSession, let key = storedSession() {
            env["BW_SESSION"] = key
        }
        return env
    }

    /// A reply for the app: a new session key (`login`, `unlock`) stays here, the reply names the marker instead.
    func reply(for result: Subprocess.Result, arguments: [String]) -> VaultReply {
        var stdout = result.stdout
        if ["login", "unlock"].contains(arguments.first ?? ""),
           let r = BitwardenCLI.reply(from: stdout), r.success,
           let key = r.object?["raw"] as? String, BitwardenCLI.isSessionKey(key), key != BitwardenCLI.heldSession {
            keep(session: key)
            let text = String(decoding: stdout, as: UTF8.self).replacingOccurrences(of: key, with: BitwardenCLI.heldSession)
            stdout = Data(text.utf8)
        }
        return VaultReply(ok: true, status: result.status, stdout: stdout, timedOut: result.timedOut)
    }

    /// The commands aOS uses, each argument checked; nothing else reaches `bw`.
    static func allowed(_ a: [String]) -> Bool {
        let passwordFile = BitwardenCLI.secretFile
        switch a.first {
        case "--version", "status", "lock", "logout", "sync":
            return a.count == 1
        case "config":
            return a.count == 3 && a[1] == "server" && BitwardenServer.isAllowedConfigValue(a[2])
        case "login":
            return a.count == 4 && BitwardenCLI.isEmail(a[1]) && a[2] == "--passwordfile" && a[3] == passwordFile
        case "unlock":
            return a == ["unlock", "--passwordfile", passwordFile]
        case "list":
            guard a.count == 4, a[1] == "items", a[2] == "--url", a[3].hasPrefix("https://") else { return false }
            return BitwardenCLI.isHost(String(a[3].dropFirst("https://".count)))
        case "get":
            return a.count == 3 && ["item", "totp", "password", "username"].contains(a[1]) && BitwardenCLI.isItemID(a[2])
        default:
            return false
        }
    }

    // MARK: The session key

    private func keep(session key: String) {
        let fm = FileManager.default
        let staged = layout.base.appendingPathComponent(".bitwarden-session-\(UUID().uuidString)")
        guard fm.createFile(atPath: staged.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
            log("vault: couldn't keep the session key")
            return
        }
        if rename(staged.path, layout.sessionFile.path) != 0 { try? fm.removeItem(at: staged) }
    }

    func storedSession() -> String? {
        guard let data = FileManager.default.contents(atPath: layout.sessionFile.path),
              let key = String(data: data, encoding: .utf8), BitwardenCLI.isSessionKey(key) else { return nil }
        return key
    }

    func forgetSession() {
        try? FileManager.default.removeItem(at: layout.sessionFile)
    }
}

// MARK: The hidden user

/// `_aosvault`: a hidden account without a shell, a home or a password, only for running `bw`. Created with dscl
/// the first time (root only), with a group of the same number.
public enum VaultAccount {
    public static func ensure(name: String = BitwardenVaultHost.userName) throws -> Subprocess.RunAs {
        if let existing = try lookup(name) { return existing }
        let used = Set(ids("/Users", "UniqueID") + ids("/Groups", "PrimaryGroupID"))
        guard let id = (360..<400).first(where: { !used.contains($0) }) else {
            throw BitwardenError.notRunnable("no free account number for \(name)")
        }
        let steps: [[String]] = [
            ["-create", "/Groups/\(name)"],
            ["-create", "/Groups/\(name)", "PrimaryGroupID", "\(id)"],
            ["-create", "/Groups/\(name)", "RealName", "aOS Bitwarden"],
            ["-create", "/Groups/\(name)", "Password", "*"],
            ["-create", "/Users/\(name)"],
            ["-create", "/Users/\(name)", "UniqueID", "\(id)"],
            ["-create", "/Users/\(name)", "PrimaryGroupID", "\(id)"],
            ["-create", "/Users/\(name)", "UserShell", "/usr/bin/false"],
            ["-create", "/Users/\(name)", "NFSHomeDirectory", "/var/empty"],
            ["-create", "/Users/\(name)", "RealName", "aOS Bitwarden"],
            ["-create", "/Users/\(name)", "Password", "*"],
            ["-create", "/Users/\(name)", "IsHidden", "1"],
        ]
        for step in steps {
            let r = try Subprocess.runBlocking("/usr/bin/dscl", ["."] + step, environment: [:], timeout: 30)
            guard r.status == 0 else { throw BitwardenError.notRunnable("dscl \(step.joined(separator: " ")) failed") }
        }
        guard let created = try lookup(name), created.uid == UInt32(id) else {
            throw BitwardenError.notRunnable("\(name) wasn't created")
        }
        return created
    }

    static func lookup(_ name: String) throws -> Subprocess.RunAs? {
        guard let pw = getpwnam(name) else { return nil }
        // Only an account that looks like ours: no login shell, a system number.
        let shell = String(cString: pw.pointee.pw_shell)
        guard pw.pointee.pw_uid >= 200, pw.pointee.pw_uid < 500, shell == "/usr/bin/false" else {
            throw BitwardenError.notRunnable("\(name) exists but isn't aOS's hidden account")
        }
        return Subprocess.RunAs(uid: pw.pointee.pw_uid, gid: pw.pointee.pw_gid)
    }

    static func ids(_ path: String, _ key: String) -> [Int] {
        guard let r = try? Subprocess.runBlocking("/usr/bin/dscl", [".", "-list", path, key], environment: [:], timeout: 30)
        else { return [] }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
            .compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).last.flatMap { Int($0) } }
    }
}
