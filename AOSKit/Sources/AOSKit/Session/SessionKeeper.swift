import Darwin
import Foundation

/// What the keeper does with each conversation, for the app (run/keeper.json).
public struct KeeperStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Running here, reachable in the Claude app.
        case running
        case starting
        /// Another Claude Code process has the conversation (the desktop app, a terminal): it stays there.
        case openElsewhere
        case waitingForNetwork
        /// Claude Code asks something only a person can answer (sign-in, trust), or keeps exiting.
        case needsAttention
        case failed
        case folderMissing
    }

    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var title: String
        public var cwd: String
        public var pinned: Bool
        public var state: State
        public var detail: String
        public var pid: Int32?
        public var since: Date
        public var lastActivity: Date
    }

    public var enabled: Bool
    public var entries: [Entry]
    public var updated: Date

    public static func read(_ paths: Paths) -> KeeperStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: SessionKeeper.statusURL(paths).path) else { return nil }
        return try? decoder.decode(KeeperStatus.self, from: data)
    }
}

/// Keeps Claude Code conversations reachable from the Claude app after the window or terminal that ran them is
/// gone: each one runs as `claude --resume <id> --remote-control <title>` in a pseudo terminal of its own.
///
/// Never twice: when another Claude Code process opens the same conversation (the desktop app, a terminal, Cloupi),
/// the keeper ends its copy at once and only takes over again a while after that process ended. Archived and
/// scheduled conversations of the desktop app stay alone, and so do conversations where Remote Control was
/// switched off. Claude Code itself is unmodified and signs in on its own; the keeper never touches credentials.
public final class SessionKeeper: @unchecked Sendable {
    public let paths: Paths
    private let queue = DispatchQueue(label: "dev.marquart.aos.keeper")
    private let cache = ConversationCache()
    private var kept: [String: Kept] = [:]
    private var lastForeign: [String: Date] = [:]
    private var entries: [String: KeeperStatus.Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var watcher: DispatchSourceFileSystemObject?
    private var settingsWatcher: DispatchSourceFileSystemObject?
    private var network = (ok: false, checked: Date.distantPast)
    private var evaluating = false
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// Where the settings come from (tests and aosctl override it).
    public var settings: (Paths) -> AgentSettings = { AgentSettings.load($0) }

    /// After another process had the conversation, wait this long before taking it back (the desktop app restarts
    /// its process when the user sends the next message there).
    static let handBackDelay: TimeInterval = 60

    final class Kept {
        let id: String
        var pid: pid_t = 0
        var master: Int32 = -1
        var read: DispatchSourceRead?
        var exit: DispatchSourceProcess?
        var startedAt = Date()
        var quickExits = 0
        var notBefore = Date.distantPast
        var recent = ""
        var stopping = false
        init(id: String) { self.id = id }
    }

    public init(paths: Paths) { self.paths = paths }

    static func statusURL(_ paths: Paths) -> URL { paths.run.appendingPathComponent("keeper.json") }
    private var childrenURL: URL { paths.run.appendingPathComponent("keeper-children.json") }

    // MARK: Running

    public func run() {
        queue.async {
            self.reapLeftovers()
            self.watchRegistry()
            self.watchSettings()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 15)
            t.setEventHandler { [weak self] in self?.evaluate() }
            t.resume()
            self.timer = t
        }
    }

    /// Ends every kept conversation (see `terminate`).
    public func stopAll() {
        queue.sync {
            for k in kept.values { terminate(k) }
        }
    }

    /// Children of a keeper that ended without cleaning up still run without anyone reading their terminal: end them,
    /// the next evaluation starts them again under this keeper.
    private func reapLeftovers() {
        guard let data = try? Data(contentsOf: childrenURL),
              let pids = try? JSONDecoder().decode([Int32].self, from: data) else { return }
        let live = Set(ClaudeConversations.live().map(\.pid))
        for pid in pids where live.contains(pid) {
            log("keeper: ending leftover \(pid) of an earlier run")
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: childrenURL)
    }

    private func saveChildren() {
        let pids = kept.values.map(\.pid).filter { $0 > 0 }
        if let data = try? JSONEncoder().encode(pids) { try? data.write(to: childrenURL, options: .atomic) }
    }

    /// Claude Code writes ~/.claude/sessions/<pid>.json for every process: react at once when one appears.
    private func watchRegistry() {
        let path = ClaudeConversations.registryFolder.path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                           queue: queue)
        src.setEventHandler { [weak self] in
            // Several events arrive per change; one evaluation shortly after is enough.
            self?.queue.asyncAfter(deadline: .now() + 0.5) { self?.evaluate() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func watchSettings() {
        let path = paths.root.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: queue)
        src.setEventHandler { [weak self] in self?.queue.asyncAfter(deadline: .now() + 0.5) { self?.evaluate() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        settingsWatcher = src
    }

    // MARK: Deciding

    /// The conversations to keep now, pinned ones first, then the most recent.
    public static func select(_ conversations: [ClaudeConversation], settings s: AgentSettings,
                       exclude folder: String) -> [(ClaudeConversation, pinned: Bool)] {
        let skipped = Set(s.skippedConversations)
        let pinned = Set(s.keptConversations)
        func eligible(_ c: ClaudeConversation) -> Bool {
            if skipped.contains(c.id) { return false }
            if let d = c.desktop, d.archived || d.scheduled || d.remoteControlTurnedOff { return false }
            // aOS's own session runs under the supervisor
            if c.cwd == folder || c.cwd.hasPrefix(folder + "/") { return false }
            return true
        }
        var out: [(ClaudeConversation, Bool)] = conversations.filter { pinned.contains($0.id) && eligible($0) }
            .map { ($0, true) }
        if s.keepAutomatic {
            // Automatically only conversations started in the Claude app (or, if wanted, in a terminal); never ones
            // started by automation (sdk) or by tools that manage their own sessions in a terminal.
            let origins: Set<String> = s.keepTerminal ? ["claude-desktop", "cli"] : ["claude-desktop"]
            let cutoff = Date().addingTimeInterval(-Double(s.keepHours) * 3600)
            for c in conversations where !pinned.contains(c.id) && eligible(c) && c.usedRemoteControl
                && origins.contains(c.startedIn) && c.lastActivity >= cutoff {
                out.append((c, false))
            }
        }
        return Array(out.prefix(s.keepMax))
    }

    private func evaluate() {
        guard !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        let s = settings(paths)
        guard s.keepReachable else {
            for k in kept.values { terminate(k) }
            entries = [:]
            writeStatus(enabled: false)
            return
        }
        var conversations = ClaudeConversations.recent(within: Double(max(s.keepHours, 1)) * 3600, cache: cache)
        for id in s.keptConversations where !conversations.contains(where: { $0.id == id }) {
            if let c = ClaudeConversations.find(id) { conversations.append(c) }
        }
        let wanted = Self.select(conversations, settings: s, exclude: paths.session.standardizedFileURL.path)
        let wantedIds = Set(wanted.map(\.0.id))
        let live = ClaudeConversations.live()

        // Not wanted any more: end them
        for (id, k) in kept where !wantedIds.contains(id) {
            log("keeper: no longer kept: \(id)")
            terminate(k)
            entries[id] = nil
        }
        for id in entries.keys where !wantedIds.contains(id) { entries[id] = nil }

        for (c, pinned) in wanted {
            let ours = kept[c.id]
            let foreign = live.filter { $0.sessionId == c.id && $0.pid != ours?.pid }
            if let other = foreign.first {
                lastForeign[c.id] = Date()
                if let ours, ours.pid > 0, !ours.stopping {
                    log("keeper: \"\(c.title)\" opened in \(other.entrypoint) (pid \(other.pid)), ending the copy here")
                    terminate(ours)
                }
                set(c, pinned, .openElsewhere, where_(other.entrypoint))
                continue
            }
            if let ours, ours.pid > 0 {
                if entries[c.id]?.state == .starting, Date().timeIntervalSince(ours.startedAt) > 20 {
                    set(c, pinned, .running, "", pid: ours.pid)
                } else if entries[c.id] == nil {
                    set(c, pinned, .running, "", pid: ours.pid)
                }
                continue
            }
            if let seen = lastForeign[c.id], Date().timeIntervalSince(seen) < Self.handBackDelay {
                set(c, pinned, .openElsewhere, "was just open elsewhere")
                continue
            }
            guard FileManager.default.fileExists(atPath: c.cwd) else {
                set(c, pinned, .folderMissing, c.cwd)
                continue
            }
            if let k = ours, Date() < k.notBefore { continue }
            guard networkUp() else {
                set(c, pinned, .waitingForNetwork, "")
                continue
            }
            start(c, pinned: pinned, previous: ours)
        }
        writeStatus(enabled: true)
    }

    private func where_(_ entrypoint: String) -> String {
        switch entrypoint {
        case "claude-desktop": return "open in the Claude app"
        case "cli": return "open in a terminal or another tool"
        default: return "open in \(entrypoint)"
        }
    }

    private func networkUp() -> Bool {
        if Date().timeIntervalSince(network.checked) > 30 {
            network = (Network.reachable(host: "api.anthropic.com", port: 443), Date())
        }
        return network.ok
    }

    // MARK: Processes

    private func start(_ c: ClaudeConversation, pinned: Bool, previous: Kept?) {
        guard let claude = ClaudeCode.executable() else {
            set(c, pinned, .failed, "Claude Code is not installed")
            return
        }
        var args = [claude.path, "--resume", c.id, "--remote-control", c.title]
        // The mode the conversation ran in; bypassing permissions is never carried over to a remote session.
        if let mode = c.desktop?.permissionMode, ["default", "acceptEdits", "plan", "auto"].contains(mode) {
            args += ["--permission-mode", mode]
        }
        // Through the login shell, which then becomes Claude Code itself (exec): same pid, PATH like a new terminal.
        let shell = ClaudeCode.loginShell()
        let command = [shell, "-l", "-c", "exec \"$@\"", "aos-keeper"] + args
        guard let (pid, master) = PTY.spawn(command, environment: ClaudeCode.cleanEnvironment(), cwd: c.cwd,
                                            columns: 120, rows: 40) else {
            set(c, pinned, .failed, "could not start a terminal (\(errno))")
            return
        }
        let k = previous ?? Kept(id: c.id)
        k.pid = pid
        k.master = master
        k.startedAt = Date()
        k.recent = ""
        k.stopping = false
        kept[c.id] = k
        saveChildren()
        log("keeper: started \"\(c.title)\" (\(c.id), pid \(pid)) in \(c.cwd)")
        if ProcessInfo.processInfo.environment["AOS_KEEPER_DEBUG"] != nil {
            queue.asyncAfter(deadline: .now() + 25) { [weak self, weak k] in
                guard let self, let k, k.pid == pid else { return }
                let screen = k.recent.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                self.log("keeper: \(c.id.prefix(8)) shows: \(screen.suffix(400))")
            }
        }
        set(c, pinned, .starting, "", pid: pid)

        let r = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        r.setEventHandler { [weak self, weak k] in
            guard let self, let k else { return }
            self.drain(k)
        }
        r.resume()
        k.read = r
        let e = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        e.setEventHandler { [weak self, weak k] in
            guard let self, let k else { return }
            self.exited(k)
        }
        e.resume()
        k.exit = e
    }

    /// Reads the terminal (a full terminal buffer would block Claude Code) and looks for things a person must see.
    private func drain(_ k: Kept) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = Darwin.read(k.master, &buffer, buffer.count)
        guard n > 0 else { return }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        k.recent = String((k.recent + text).suffix(4000))
        let lower = k.recent.lowercased()
        guard var e = entries[k.id] else { return }
        if lower.contains("remote control not started here") {
            // Another process has Remote Control for this conversation: this copy only duplicates it.
            log("keeper: \"\(e.title)\" has Remote Control elsewhere, ending the copy here")
            lastForeign[k.id] = Date()
            terminate(k)
            e.state = .openElsewhere; e.detail = "Remote Control runs elsewhere"; e.since = Date()
        } else if lower.contains("/login") || lower.contains("not logged in") || lower.contains("please log in") {
            e.state = .needsAttention; e.detail = "Claude Code needs a sign-in"; e.since = Date()
        } else if lower.contains("do you trust") || lower.contains("trust this folder") || lower.contains("[y/n]") {
            e.state = .needsAttention; e.detail = "Claude Code asks a question in its terminal"; e.since = Date()
        } else {
            return
        }
        entries[k.id] = e
        writeStatus(enabled: true)
    }

    private func exited(_ k: Kept) {
        var code: Int32 = 0
        waitpid(k.pid, &code, 0)
        k.read?.cancel(); k.read = nil
        k.exit?.cancel(); k.exit = nil
        if k.master >= 0 { close(k.master); k.master = -1 }
        let lived = Date().timeIntervalSince(k.startedAt)
        let intended = k.stopping
        k.pid = 0
        k.stopping = false
        saveChildren()
        log("keeper: \(k.id) exited (status \(code)) after \(Int(lived)) s\(intended ? " as asked" : "")")
        guard !intended else { return }
        k.quickExits = lived < 60 ? k.quickExits + 1 : 0
        let delay = [10.0, 30, 60, 300, 1800][min(k.quickExits, 4)]
        k.notBefore = Date().addingTimeInterval(delay)
        if var e = entries[k.id] {
            e.state = k.quickExits >= 3 ? .needsAttention : .starting
            e.detail = k.quickExits >= 3 ? "Claude Code keeps exiting; next try in \(Int(delay / 60)) min"
                : "restarting in \(Int(delay)) s"
            e.pid = nil
            e.since = Date()
            entries[k.id] = e
        }
        writeStatus(enabled: true)
        queue.asyncAfter(deadline: .now() + delay + 0.5) { [weak self] in self?.evaluate() }
    }

    /// Ends a kept conversation like closing its terminal window would (SIGHUP, which Claude Code handles cleanly),
    /// then SIGTERM, and SIGKILL only if it is still there after 15 s.
    private func terminate(_ k: Kept) {
        guard k.pid > 0, !k.stopping else { return }
        k.stopping = true
        let pid = k.pid
        kill(pid, SIGHUP)
        queue.asyncAfter(deadline: .now() + 5) { [weak k] in
            if let k, k.pid == pid { kill(pid, SIGTERM) }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak k] in
            if let k, k.pid == pid { kill(pid, SIGKILL) }
        }
    }

    // MARK: Status

    private func set(_ c: ClaudeConversation, _ pinned: Bool, _ state: KeeperStatus.State, _ detail: String,
                     pid: pid_t? = nil) {
        let old = entries[c.id]
        let changed = old?.state != state || old?.detail != detail
        entries[c.id] = KeeperStatus.Entry(id: c.id, title: c.title, cwd: c.cwd, pinned: pinned, state: state,
                                           detail: detail, pid: pid ?? kept[c.id].flatMap { $0.pid > 0 ? $0.pid : nil },
                                           since: changed ? Date() : (old?.since ?? Date()),
                                           lastActivity: c.lastActivity)
    }

    private func writeStatus(enabled: Bool) {
        let status = KeeperStatus(enabled: enabled,
                                  entries: entries.values.sorted { ($0.pinned ? 1 : 0, $0.lastActivity) > ($1.pinned ? 1 : 0, $1.lastActivity) },
                                  updated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(status) { try? data.write(to: Self.statusURL(paths), options: .atomic) }
    }
}

/// Starting a program in a new pseudo terminal.
enum PTY {
    static func spawn(_ args: [String], environment: [String], cwd: String, columns: UInt16, rows: UInt16)
        -> (pid_t, Int32)? {
        // Everything the child needs is prepared before fork: no allocation after it.
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup($0) } + [nil]
        let cCwd = strdup(cwd)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cCwd)
        }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &size)
        if pid == 0 {
            // aos-session ignores SIGTERM itself (it handles it through a dispatch source); an ignored signal
            // survives exec, and the child would then ignore SIGTERM too. Start it with every signal at its default.
            for sig in 1..<NSIG { signal(sig, SIG_DFL) }
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            _ = chdir(cCwd)
            execve(cArgs[0], cArgs, cEnv)
            _exit(127)
        }
        guard pid > 0 else { return nil }
        return (pid, fd)
    }
}
