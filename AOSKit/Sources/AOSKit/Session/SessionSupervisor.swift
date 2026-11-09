import Darwin
import Foundation

/// What the session is doing, for the app (written to run/session.json).
public struct SessionStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case starting, running, waitingForNetwork, needsLogin, needsAttention, missingClaude, restarting, stopped, failed
    }
    public var state: State
    public var detail: String
    public var pid: Int32?
    public var since: Date
    public var restarts: Int
}

/// Keeps one Claude Code session running in a pseudo terminal, reachable through Remote Control. Restarts it
/// when it exits (with back-off), waits for the network first, and relays the terminal to the app (run/session.sock)
/// so the user can look at it and answer Claude Code's own first-run questions there. Never touches credentials.
public final class SessionSupervisor: @unchecked Sendable {
    public let paths: Paths
    private let queue = DispatchQueue(label: "\(Brand.bundleIdentifierPrefix).session")
    private var master: Int32 = -1
    private var child: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var scrollback = Data()
    private let scrollbackLimit = 256 * 1024
    private var viewers: [Int32] = []
    private var listenFD: Int32 = -1
    private var status = SessionStatus(state: .starting, detail: "", pid: nil, since: Date(), restarts: 0)
    private var quickExits = 0
    private var startedAt = Date()
    private var recentText = ""
    /// Restarts in the last 30 minutes (two of them: the conversation starts fresh, it may be the trouble).
    private var recentStarts: [Date] = []
    /// The folder the running session works in.
    private var folder: URL?
    private var messenger: SessionMessenger
    private var messageTimer: DispatchSourceTimer?
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) } {
        didSet { messenger.log = log }
    }

    public static let columns: UInt16 = 120
    public static let rows: UInt16 = 40

    public init(paths: Paths) {
        self.paths = paths
        messenger = SessionMessenger(paths: paths)
    }

    public var statusURL: URL { paths.run.appendingPathComponent("session.json") }
    public var socketURL: URL { paths.run.appendingPathComponent("session.sock") }

    // MARK: Status

    private func setStatus(_ state: SessionStatus.State, _ detail: String = "") {
        if status.state != state || status.detail != detail {
            status.state = state
            status.detail = detail
            status.since = Date()
            log("session: \(state.rawValue)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        status.pid = child > 0 ? child : nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) { try? data.write(to: statusURL, options: .atomic) }
    }

    public static func readStatus(paths: Paths) -> SessionStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: paths.run.appendingPathComponent("session.json").path)
        else { return nil }
        return try? decoder.decode(SessionStatus.self, from: data)
    }

    // MARK: Start

    public func run() {
        queue.async {
            self.startViewerSocket()
            self.startMessenger()
            self.launch()
        }
    }

    /// Routines, reminders and notes: every 10 s what is due goes into the queue, and the head of it into the
    /// session while Claude Code waits for input.
    private func startMessenger() {
        messenger.ready = { [weak self] in
            guard let self, self.child > 0, self.status.state == .running else { return false }
            return ClaudeRegistry.entry(pid: self.child)?.status == "idle"
        }
        messenger.type = { [weak self] data, delay in
            guard let self else { return }
            let write = { [weak self] in
                guard let self, self.master >= 0 else { return }
                _ = data.withUnsafeBytes { Darwin.write(self.master, $0.baseAddress, data.count) }
            }
            if delay > 0 { self.queue.asyncAfter(deadline: .now() + delay, execute: write) } else { write() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.messenger.tick() }
        t.resume()
        messageTimer = t
    }

    /// The conversation the session continues (run/session-conversation.json): its own, in its folder; never just
    /// the newest conversation of the folder, which may be one the user started there in the Claude app.
    private struct Conversation: Codable {
        var folder: String
        var id: String
    }
    private var conversationURL: URL { paths.run.appendingPathComponent("session-conversation.json") }

    private func savedConversation(in folder: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: conversationURL.path),
              let c = try? JSONDecoder().decode(Conversation.self, from: data), c.folder == folder.path,
              UUID(uuidString: c.id) != nil, ClaudeConversations.find(c.id) != nil else { return nil }
        return c.id
    }

    private func forgetConversation() { try? FileManager.default.removeItem(at: conversationURL) }

    /// Notes the conversation of the running process (from Claude Code's registry, once it wrote it).
    private func learnConversation(pid: pid_t, folder: URL, attempt: Int = 0) {
        guard child == pid else { return }
        if let id = ClaudeRegistry.entry(pid: pid)?.sessionId, UUID(uuidString: id) != nil {
            if let data = try? JSONEncoder().encode(Conversation(folder: folder.path, id: id)) {
                try? data.write(to: conversationURL, options: .atomic)
            }
            return
        }
        guard attempt < 20 else { return }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.learnConversation(pid: pid, folder: folder, attempt: attempt + 1)
        }
    }

    private func launch() {
        guard child == 0 else { return }
        let settings = AgentSettings.load(paths)
        guard settings.sessionEnabled else { setStatus(.stopped, "turned off in settings"); return }
        // The same background process also keeps conversations reachable (SessionKeeper); aOS's own session only
        // runs once the setup configured its folder. That can happen after this process started: look again.
        guard ClaudeCode.isConfigured(session: paths.session) else {
            setStatus(.stopped, "not set up")
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.launch() }
            return
        }
        let folder = settings.sessionDirectory(paths)
        guard let claude = ClaudeCode.executable() else {
            setStatus(.missingClaude, "Claude Code is not installed")
            queue.asyncAfter(deadline: .now() + 30) { self.launch() }
            return
        }
        guard Network.reachable(host: "api.anthropic.com", port: 443) else {
            setStatus(.waitingForNetwork)
            queue.asyncAfter(deadline: .now() + 15) { self.launch() }
            return
        }
        // Twice in 30 minutes: start a fresh conversation (the old one may be what keeps it from running).
        recentStarts = recentStarts.filter { Date().timeIntervalSince($0) < 1800 }
        if recentStarts.count >= 2, savedConversation(in: folder) != nil {
            log("session: restarted twice within 30 minutes, starting a fresh conversation")
            forgetConversation()
            recentStarts = []
        }
        var args = [claude.path]
        if let id = savedConversation(in: folder) {
            args += ["--resume", id]
        } else if folder == paths.session.standardizedFileURL, ClaudeCode.hasConversation(in: folder) {
            // aOS's own folder has only the session's conversations
            args.append("--continue")
        }
        args += ["--remote-control", settings.sessionName]
        if !settings.sessionEffort.isEmpty { args += ["--effort", settings.sessionEffort] }
        self.folder = folder
        spawn(args, folder: folder, settings: settings)
    }

    private func environment(_ settings: AgentSettings) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
                  "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            env.removeValue(forKey: k)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS"] = "0"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // The user's environment files (names logged, never values)
        for file in settings.sessionEnvFiles {
            let path = (file as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                log("session: environment file \(file) not readable")
                continue
            }
            let values = EnvironmentFile.parse(text)
            for (k, v) in values where !["PATH", "HOME", "TERM"].contains(k) { env[k] = v }
            log("session: \(values.count) values from \((file as NSString).lastPathComponent)")
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func spawn(_ args: [String], folder: URL, settings: AgentSettings) {
        setStatus(status.restarts == 0 ? .starting : .restarting)
        // Everything the child needs is prepared before fork: no allocation after it.
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = environment(settings).map { strdup($0) } + [nil]
        let cwd = strdup(folder.path)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cwd)
        }
        var size = winsize(ws_row: Self.rows, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &size)
        if pid == 0 {
            // aos-session ignores SIGTERM itself (it handles it through a dispatch source); an ignored signal
            // survives exec, and the child would then ignore SIGTERM too. Start it with every signal at its default.
            for sig in 1..<NSIG { signal(sig, SIG_DFL) }
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            _ = chdir(cwd)
            execve(cArgs[0], cArgs, cEnv)
            _exit(127)
        }
        guard pid > 0 else {
            setStatus(.failed, "could not start a terminal (\(errno))")
            return
        }
        child = pid
        master = fd
        startedAt = Date()
        recentText = ""
        setStatus(.starting)
        recentStarts.append(Date())
        messenger.sessionStarted()
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.learnConversation(pid: pid, folder: folder) }
        log("session: started in \(folder.path == paths.session.standardizedFileURL.path ? "aOS's folder" : folder.path)\(args.contains("--resume") ? ", continuing its conversation" : "")")

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readOutput() }
        src.resume()
        readSource = src

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.childExited() }
        exit.resume()
        exitSource = exit

        // No question from Claude Code within 20 s: it runs.
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.child == pid, self.status.state == .starting else { return }
            self.setStatus(.running)
        }
    }

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = read(master, &buffer, buffer.count)
        guard n > 0 else { return }
        let data = Data(buffer[0..<n])
        scrollback.append(data)
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
        for v in viewers { _ = data.withUnsafeBytes { write(v, $0.baseAddress, n) } }
        recognize(data)
    }

    /// Recognizes Claude Code's questions in the output so the app can ask the user to look.
    private func recognize(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        recentText = String((recentText + text).suffix(4000))
        switch SessionOutput.classify(recentText) {
        case .question:
            setStatus(.needsAttention, "Claude Code is asking a question")
        case .signIn:
            setStatus(.needsLogin, "sign in to Claude Code")
        case .fine:
            if status.state == .needsLogin { setStatus(.running) }
            fallthrough
        case .unknown:
            if status.state == .needsAttention, Date().timeIntervalSince(status.since) > 5, !text.isEmpty,
               SessionOutput.classify(text) == .unknown {
                // New output after the question: probably answered.
                setStatus(.running)
                recentText = ""
            }
        }
    }

    private func childExited() {
        var code: Int32 = 0
        waitpid(child, &code, 0)
        readSource?.cancel(); readSource = nil
        exitSource?.cancel(); exitSource = nil
        if master >= 0 { close(master); master = -1 }
        child = 0
        let lived = Date().timeIntervalSince(startedAt)
        quickExits = lived < 60 ? quickExits + 1 : 0
        status.restarts += 1
        log("session: claude exited (status \(code)) after \(Int(lived)) s")
        if quickExits >= 5 {
            setStatus(.failed, "Claude Code keeps exiting; open the session in \(Brand.name) to see why")
            return  // the app restarts it (restart command over the socket)
        }
        let delay = [5.0, 15, 30, 60, 120][min(quickExits, 4)]
        setStatus(.restarting, "in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    // MARK: Viewer socket

    /// The app connects here: it gets the scrollback, then live output; whatever it sends goes to the terminal.
    /// A first line "restart" (instead of terminal input) restarts a failed session; "stop" ends it.
    private func startViewerSocket() {
        let path = socketURL.path
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        let old = umask(0o177)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        listen(listenFD, 4)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptViewer() }
        src.resume()
        viewerAcceptSource = src
    }
    private var viewerAcceptSource: DispatchSourceRead?
    private var viewerSources: [Int32: DispatchSourceRead] = [:]

    private func acceptViewer() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = scrollback.withUnsafeBytes { write(fd, $0.baseAddress, scrollback.count) }
        viewers.append(fd)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.viewerInput(fd) }
        src.resume()
        viewerSources[fd] = src
    }

    private func viewerInput(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            viewerSources[fd]?.cancel(); viewerSources[fd] = nil
            viewers.removeAll { $0 == fd }
            close(fd)
            return
        }
        let data = Data(buffer[0..<n])
        if data == Data("\u{1B}]aos;restart\u{07}".utf8) {
            quickExits = 0
            if child > 0 { kill(child, SIGTERM) } else { launch() }
            return
        }
        // A fresh conversation: forget the session's one and restart
        if data == Data("\u{1B}]aos;fresh\u{07}".utf8) {
            log("session: a fresh conversation, as asked")
            forgetConversation()
            recentStarts = []
            quickExits = 0
            if child > 0 { kill(child, SIGTERM) } else { launch() }
            return
        }
        // Run a routine now
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("\u{1B}]aos;run;"), text.hasSuffix("\u{07}") {
            messenger.runNow(String(text.dropFirst(10).dropLast()))
            messenger.tick()
            return
        }
        if master >= 0 { _ = data.withUnsafeBytes { write(master, $0.baseAddress, n) } }
        if status.state == .needsAttention || status.state == .needsLogin {
            // The user answered in the app; give Claude Code a moment, then assume it runs.
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.child > 0, self.status.state == .needsAttention else { return }
                self.recentText = ""
                self.setStatus(.running)
            }
        }
    }

    /// Ends the session (SIGTERM, then SIGKILL).
    public func stop() {
        queue.sync {
            guard child > 0 else { return }
            let pid = child
            kill(pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 5) { kill(pid, SIGKILL) }
        }
    }
}

/// Finding Claude Code and facts about it. The app never installs a copy of its own or touches credentials:
/// the user installs Claude Code with Anthropic's installer and signs in through Claude Code's own flow.
public enum ClaudeCode {
    /// Whether Claude Code would start in `folder` without asking: the folder (or one above it) is trusted, and the
    /// one-time Remote Control question was answered. Reads only these two flags from ~/.claude.json, nothing else.
    public static func readiness(folder: URL, configFile: URL? = nil) -> (trusted: Bool, remoteControl: Bool) {
        let file = configFile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, false) }
        let projects = root["projects"] as? [String: Any] ?? [:]
        var trusted = false
        var path = folder.standardizedFileURL.path
        while !trusted {
            if let entry = projects[path] as? [String: Any], entry["hasTrustDialogAccepted"] as? Bool == true { trusted = true }
            if path == "/" || path.isEmpty { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return (trusted, root["remoteDialogSeen"] as? Bool == true)
    }

    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// The environment of a fresh terminal: nothing from a Claude Code process that may have started us (its markers
    /// turn off saving the transcript), no API keys.
    public static func cleanEnvironment() -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL"] {
            if let v = inherited[k] { env[k] = v }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = env["HOME"] ?? home
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// The user's login shell if it is one whose `-l -c 'exec "$@"'` we know (it sets PATH like a new terminal
    /// window, which MCP servers started through npx and the like need), otherwise zsh.
    public static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell.map({ String(cString: $0) }),
           ["zsh", "bash", "sh"].contains((shell as NSString).lastPathComponent),
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    /// Claude Code stores conversations per folder in ~/.claude/projects/<folder with / replaced by ->.
    public static func hasConversation(in folder: URL) -> Bool {
        let encoded = folder.standardizedFileURL.path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// Runs `claude` with arguments (no terminal) and returns exit status and output.
    @discardableResult
    public static func run(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 30) throws -> (Int32, String) {
        guard let exe = executable() else { throw SessionError.missingClaude }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        let r = try Subprocess.runBlocking(exe.path, args, environment: env, cwd: cwd?.path, timeout: timeout)
        return (r.status, String(decoding: r.stdout + r.stderr, as: UTF8.self))
    }

    public static func version() -> String? {
        guard let (code, text) = try? run(["--version"], timeout: 15), code == 0 else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `claude auth status` exits 0 when signed in. Only the method is read, nothing secret.
    public static func signedIn() -> (signedIn: Bool, method: String?) {
        guard let (code, text) = try? run(["auth", "status"], timeout: 20) else { return (false, nil) }
        var method: String?
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            method = json["authMethod"] as? String
        }
        return (code == 0 && method != "none", method)
    }

    /// The setup registered the workspace tools for the session folder (see `configure`).
    public static func isConfigured(session: URL) -> Bool {
        FileManager.default.fileExists(atPath: session.appendingPathComponent(".claude/settings.local.json").path)
    }

    /// Registers the MCP server for the session folder only (local scope) and writes the folder's permission
    /// rules: the workspace tools run without asking, except opening the workspace, which the user approves.
    public static func configure(session: URL, mcpBinary: URL) throws {
        try FileManager.default.createDirectory(at: session.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        _ = try? run(["mcp", "remove", "--scope", "local", Brand.mcpServerName], cwd: session)
        let (code, text) = try run(["mcp", "add", "--scope", "local", "--transport", "stdio", Brand.mcpServerName,
                                    "--", mcpBinary.path], cwd: session)
        guard code == 0 else { throw SessionError.configuration(text) }
        let server = Brand.mcpServerName
        let settings: [String: Any] = [
            "permissions": [
                "allow": ["mcp__\(server)__*"],
                "ask": ["mcp__\(server)__workspace_open"],
            ],
            "env": ["CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0"],
        ]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: session.appendingPathComponent(".claude/settings.local.json"), options: .atomic)
    }
}

public enum SessionError: LocalizedError {
    case missingClaude
    case configuration(String)
    public var errorDescription: String? {
        switch self {
        case .missingClaude: return "Claude Code is not installed."
        case .configuration(let s): return "Claude Code could not register the workspace tools: \(s.prefix(300))"
        }
    }
}

/// For files that import Apple's Network framework, where `Network` means the framework.
public typealias TCPCheck = Network

/// Is the host reachable (DNS and TCP)? Waiting for this avoids starting Claude Code without network.
public enum Network {
    public static func reachable(host: String, port: UInt16, timeout: Int32 = 5) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let ok = connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0
                close(fd)
                if ok { return true }
            }
            ai = a.pointee.ai_next
        }
        return false
    }
}

/// What Claude Code's latest output says, for the session's state. Only the latest sign counts: Claude Code prints
/// "OAuth token refresh failed, run /login" when Remote Control drops for a moment, and "/remote-control is active"
/// once it reconnected by itself; a sign-in is needed only while the first is the newer one.
enum SessionOutput: Equatable {
    case question, signIn, fine, unknown

    static let questions = ["enable remote control?", "do you trust", "trust the files", "trust this folder", "[y/n]"]
    static let signIns = ["/login", "not logged in", "please log in", "invalid api key"]
    static let fines = ["remote-control is active", "remote control is active", "remote control connected",
                        "continue here, on your phone"]

    static func classify(_ text: String) -> SessionOutput {
        let lower = text.lowercased()
        func last(_ markers: [String]) -> String.Index? {
            markers.compactMap { lower.range(of: $0, options: .backwards)?.lowerBound }.max()
        }
        let q = last(questions), s = last(signIns), f = last(fines)
        let newest = [q, s, f].compactMap { $0 }.max()
        guard let newest else { return .unknown }
        if newest == f { return .fine }
        if newest == s { return .signIn }
        return .question
    }
}
