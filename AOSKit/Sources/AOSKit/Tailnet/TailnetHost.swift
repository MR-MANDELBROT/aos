import Foundation
import Security

/// The helper's side of the tailnet node (runs as root in aos-powerd; see TailnetHelper.swift).
///
/// - aos-tailnet runs as the hidden user `_aostailnet` (made with VaultAccount.ensure), from a copy in
///   `/Library/Application Support/aOS/bin` (root, 0755) whose code signature was checked: aOS's team, identifier
///   aos-tailnet. The app bundle is the person's to change, the copy isn't.
/// - Its state (the node's keys) is in `/Library/Application Support/aOS/Tailscale` (0700, `_aostailnet`); whether it
///   should run, and with which name, in `tailnet.json` (root, 0600). The helper starts it again when it starts
///   itself (at boot, after an update), and after the node's process ended (with growing pauses).
/// - The helper talks to it over the process's stdin and stdout (the line protocol in Tailnet/protocol.go).
public actor TailnetHost {
    public struct Layout: Sendable {
        /// /Library/Application Support/aOS (root, 0755).
        public var base: URL
        public var state: URL { base.appendingPathComponent("Tailscale", isDirectory: true) }
        public var temporary: URL { state.appendingPathComponent("tmp", isDirectory: true) }
        public var config: URL { base.appendingPathComponent("tailnet.json") }
        public var executable: URL { base.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("aos-tailnet") }

        public init(base: URL) { self.base = base }
    }

    public static let userName = "_aostailnet"
    /// Who may be aos-tailnet: aOS's own build (Tools/build-tailnet.sh signs it so).
    public static var requirement: String {
        "anchor apple generic and identifier \"aos-tailnet\" and certificate leaf[subject.OU] = \"\(PowerHelperService.teamID)\""
    }

    struct Config: Codable, Equatable {
        var enabled: Bool
        var hostname: String
    }

    let layout: Layout
    /// The user aos-tailnet runs as (nil in tests: as this process).
    let account: @Sendable () throws -> Subprocess.RunAs?
    /// aos-tailnet in the app bundle (next to the helper).
    let source: @Sendable () -> URL?
    /// Checks a file's code signature; nil when it is aOS's aos-tailnet.
    let verify: @Sendable (String) -> String?
    let log: @Sendable (String) -> Void
    /// Pauses before starting a node again whose process ended (tests make them short).
    let restartDelays: [TimeInterval]

    private var config: Config?
    private var child: TailnetChild?
    private var problem: String?
    private var quickEnds = 0
    private var restart: Task<Void, Never>?
    /// For the helper's idle check, without waiting for the actor.
    private nonisolated let on = Locked(false)

    public init(layout: Layout, account: @escaping @Sendable () throws -> Subprocess.RunAs?,
                source: @escaping @Sendable () -> URL?,
                verify: @escaping @Sendable (String) -> String? = { TailnetHost.checkSignature($0) },
                restartDelays: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300],
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.layout = layout
        self.account = account
        self.source = source
        self.verify = verify
        self.restartDelays = restartDelays
        self.log = log
        let saved = Self.readConfig(layout.config)
        config = saved
        on.set(saved?.enabled == true)
    }

    /// The node should run: the helper doesn't exit while it does.
    public nonisolated var isOn: Bool { on.get() }

    // MARK: Requests

    public func handle(_ request: TailnetRequest) async -> TailnetReply {
        if let problem = request.problem { return .failure(problem) }
        switch request.op {
        case .status:
            return await status()
        case .start:
            return await start(hostname: request.hostname ?? "")
        case .stop:
            setConfig(config.map { Config(enabled: false, hostname: $0.hostname) })
            await stopChild()
            log("tailnet: stopped (the sign-in stays)")
            return await status()
        case .login:
            guard let child, child.isRunning else { return .failure("the node isn't running") }
            guard let answer = await child.request("login", timeout: 25), answer.ok else {
                return .failure("no new sign-in link")
            }
            return await status()
        case .reconnect:
            guard config?.enabled == true else { return .failure("the node is off") }
            await stopChild()
            problem = nil
            quickEnds = 0
            startChild()
            return await status(waitForAnswer: true)
        case .logout:
            return await logout()
        }
    }

    /// At the helper's start: the node again if it should run.
    public func resume() {
        guard config?.enabled == true, child == nil else { return }
        log("tailnet: starting the node again")
        startChild()
    }

    /// The helper stops (signal, update): the node ends with it; it starts again with the next helper.
    public func shutdown() async {
        restart?.cancel()
        restart = nil
        await stopChild()
    }

    func status(waitForAnswer: Bool = false) async -> TailnetReply {
        var reply = TailnetReply(ok: true)
        reply.enabled = config?.enabled == true
        reply.hostname = config?.hostname
        reply.problem = problem
        reply.running = child?.isRunning == true
        if let child, child.isRunning {
            // A node that has just started answers within a few seconds.
            let attempts = waitForAnswer ? 10 : 1
            for attempt in 0..<attempts where child.isRunning {
                if let answer = await child.request("status", timeout: 10), answer.ok, let json = answer.statusJSON {
                    reply.statusJSON = json
                    break
                }
                if attempt + 1 < attempts { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            reply.problem = problem
            reply.running = child.isRunning
        }
        return reply
    }

    func start(hostname: String) async -> TailnetReply {
        let wasRunning = child?.isRunning == true
        let sameName = config?.hostname == hostname
        setConfig(Config(enabled: true, hostname: hostname))
        if wasRunning && sameName { return await status() }
        if wasRunning { await stopChild() }
        problem = nil
        quickEnds = 0
        startChild()
        log("tailnet: node started as \(hostname)")
        return await status(waitForAnswer: true)
    }

    func logout() async -> TailnetReply {
        restart?.cancel()
        restart = nil
        var note: String?
        let hasState = FileManager.default.fileExists(atPath: layout.state.appendingPathComponent("tailscaled.state").path)
        if hasState {
            // Signing out needs the node: started for the purpose if it wasn't running.
            if child?.isRunning != true, let hostname = config?.hostname {
                startChild(hostname: hostname)
                _ = await status(waitForAnswer: true)
            }
            if let answer = await child?.request("logout", timeout: 25), answer.ok {
                log("tailnet: signed out, the device left the tailnet")
            } else {
                note = "Tailscale couldn't be reached; the device stays in the tailnet until you remove it in the admin console."
                log("tailnet: signing out failed, the state is deleted anyway")
            }
        }
        await stopChild()
        setConfig(nil)
        try? FileManager.default.removeItem(at: layout.state)
        problem = nil
        log("tailnet: the node's state was deleted")
        var reply = await status()
        reply.message = note
        return reply
    }

    // MARK: The process

    private func setConfig(_ new: Config?) {
        config = new
        on.set(new?.enabled == true)
        if let new {
            let data = (try? JSONEncoder().encode(new)) ?? Data()
            let staged = layout.base.appendingPathComponent(".tailnet-\(UUID().uuidString).json")
            try? FileManager.default.createDirectory(at: layout.base, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
            if FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]),
               rename(staged.path, layout.config.path) != 0 {
                try? FileManager.default.removeItem(at: staged)
            }
        } else {
            try? FileManager.default.removeItem(at: layout.config)
        }
    }

    static func readConfig(_ url: URL) -> Config? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              TailnetRequest.isValidHostname(config.hostname) else { return nil }
        return config
    }

    private func startChild(hostname: String? = nil) {
        guard let name = hostname ?? config?.hostname else { return }
        restart?.cancel()
        restart = nil
        do {
            let who = try account()
            try makeFolders(owner: who)
            let executable = try installExecutable()
            let process = try Subprocess.spawn(executable, ["serve", "--dir", layout.state.path, "--hostname", name],
                                               environment: environment(who), cwd: layout.state.path, runAs: who)
            let started = TailnetChild(process: process, log: log)
            child = started
            Task { [weak self] in
                let status = await started.process.waitForExit()
                await self?.childEnded(started, status: status)
            }
        } catch {
            problem = error.localizedDescription
            log("tailnet: the node couldn't start: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func stopChild() async {
        guard let current = child else { return }
        child = nil
        current.stop()
        _ = await current.process.waitForExit()
    }

    private func childEnded(_ ended: TailnetChild, status: Int32) {
        guard child === ended else { return }
        child = nil
        let lived = Date().timeIntervalSince(ended.started)
        problem = "the node ended (status \(status))"
        log("tailnet: the node ended after \(Int(lived)) s (status \(status))")
        quickEnds = lived > 60 ? 0 : quickEnds + 1
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard config?.enabled == true, restart == nil else { return }
        let delay = restartDelays.isEmpty ? 300 : restartDelays[min(quickEnds, restartDelays.count - 1)]
        restart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.restartNow()
        }
    }

    private func restartNow() {
        restart = nil
        guard config?.enabled == true, child == nil else { return }
        startChild()
    }

    func makeFolders(owner: Subprocess.RunAs?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for dir in [layout.state, layout.temporary] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let owner, chown(dir.path, owner.uid, owner.gid) != 0 {
                throw CustodyError.helper("couldn't hand \(dir.lastPathComponent) to \(Self.userName)")
            }
            chmod(dir.path, 0o700)
        }
        let bin = layout.executable.deletingLastPathComponent()
        try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }

    /// Copies aos-tailnet from the app bundle to where only root can change it, then checks the copy's signature.
    /// Returns the copy's path.
    func installExecutable() throws -> String {
        guard let source = source(), FileManager.default.fileExists(atPath: source.path) else {
            throw CustodyError.helper("aos-tailnet is missing in the app")
        }
        let target = layout.executable
        let staged = target.deletingLastPathComponent().appendingPathComponent(".aos-tailnet-\(UUID().uuidString)")
        guard let data = FileManager.default.contents(atPath: source.path),
              FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o755])
        else { throw CustodyError.helper("couldn't copy aos-tailnet") }
        if let problem = verify(staged.path) {
            try? FileManager.default.removeItem(at: staged)
            throw CustodyError.helper("aos-tailnet isn't aOS's (\(problem))")
        }
        guard rename(staged.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw CustodyError.helper("couldn't put aos-tailnet in place")
        }
        return target.path
    }

    /// A fresh environment: nothing of the helper's.
    func environment(_ who: Subprocess.RunAs?) -> [String: String] {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": layout.state.path,
            "TMPDIR": layout.temporary.path + "/",
            "LANG": "en_US.UTF-8",
            // No log uploads to Tailscale (the node sets it itself as well).
            "TS_NO_LOGS_NO_SUPPORT": "true",
        ]
        if who != nil { env["USER"] = Self.userName; env["LOGNAME"] = Self.userName }
        return env
    }

    /// Checks a file against `requirement`: nil when it holds.
    public static func checkSignature(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return "no code signature" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return "bad requirement" }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        switch status {
        case errSecSuccess: return nil
        case errSecCSUnsigned: return "not signed"
        case errSecCSReqFailed: return "signed by someone else"
        default: return "signature not valid (\(status))"
        }
    }
}

/// One running aos-tailnet and the requests waiting for its answers.
final class TailnetChild: @unchecked Sendable {
    struct Answer: Sendable {
        var ok: Bool
        var error: String?
        var statusJSON: String?
    }

    let process: Subprocess.Running
    let started = Date()
    private let lock = NSLock()
    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<Answer?, Never>] = [:]
    private var ended = false

    init(process: Subprocess.Running, log: @escaping @Sendable (String) -> Void) {
        self.process = process
        let output = process.output.fileDescriptor
        Thread.detachNewThread { [self] in
            Self.readLines(output) { self.received($0) }
            let waiting = lock.withLock { () -> [CheckedContinuation<Answer?, Never>] in
                ended = true
                defer { pending = [:] }
                return Array(pending.values)
            }
            waiting.forEach { $0.resume(returning: nil) }
        }
        let errors = process.errors.fileDescriptor
        Thread.detachNewThread {
            // aos-tailnet writes short notes there, without URLs.
            Self.readLines(errors) { line in
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { log("tailnet: \(text.prefix(300))") }
            }
        }
    }

    var isRunning: Bool { process.exitStatus == nil && !lock.withLock { ended } }

    /// Sends one request; nil when it didn't answer in time or ended.
    func request(_ op: String, timeout: TimeInterval) async -> Answer? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Answer?, Never>) in
            let id: Int64? = lock.withLock {
                guard !ended else { return nil }
                nextID += 1
                pending[nextID] = continuation
                return nextID
            }
            guard let id else { continuation.resume(returning: nil); return }
            let line = Data("{\"id\":\(id),\"op\":\"\(op)\"}\n".utf8)
            do {
                try process.input.write(contentsOf: line)
            } catch {
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) { waiting.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) { waiting.resume(returning: nil) }
            }
        }
    }

    /// Ends it: its stdin closes (it closes the node and exits), SIGTERM, SIGKILL after five seconds.
    func stop() {
        try? process.input.close()
        process.terminate(grace: 5)
    }

    private func received(_ line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = (o["id"] as? NSNumber)?.int64Value else { return }
        var answer = Answer(ok: (o["ok"] as? Bool) ?? false, error: o["error"] as? String)
        if let status = o["status"], let data = try? JSONSerialization.data(withJSONObject: status) {
            answer.statusJSON = String(decoding: data, as: UTF8.self)
        }
        if let waiting = lock.withLock({ pending.removeValue(forKey: id) }) { waiting.resume(returning: answer) }
    }

    /// Reads lines (up to 4 MB each) until the end.
    static func readLines(_ fd: Int32, _ line: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    line(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                if buffer.count > 4 << 20 { buffer.removeAll() }
            } else if n == -1 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }
}
