import Darwin
import Foundation

/// The state of Claude Code's server mode, for the app (run/remote.json).
public struct RemoteServerStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case off, waitingForNetwork, starting, running, needsLogin, needsTrust, missingClaude, restarting
    }
    public var state: State
    public var detail: String
    public var pid: Int32?
    public var folder: String
    public var since: Date

    static func url(_ paths: Paths) -> URL { paths.run.appendingPathComponent("remote.json") }
    /// The app puts the user's answer to Claude Code's question about trusting the folder here.
    public static func trustURL(_ paths: Paths) -> URL { paths.run.appendingPathComponent("remote-trust.json") }

    /// The user trusts `folder` (they clicked in the app): the server answers Claude Code's question with yes.
    public static func trust(folder: String, paths: Paths) throws {
        try JSONEncoder().encode(["folder": folder]).write(to: trustURL(paths), options: .atomic)
    }

    public static func read(_ paths: Paths) -> RemoteServerStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: url(paths).path) else { return nil }
        return try? decoder.decode(RemoteServerStatus.self, from: data)
    }
}

/// Claude Code's Remote Control server mode (`claude remote-control`): the Mac appears as a device in the Claude
/// app, and every new chat the user starts there runs on this Mac, in the chosen folder, with the user's own Claude
/// Code (their sign-in, settings and MCP servers, aOS among them). Waits for the network first (without it the
/// server gives up after 10 minutes), starts it again when it ends (with back-off) and follows the settings.
/// Never touches credentials; when Claude Code isn't signed in, the app says so.
public final class RemoteServer: @unchecked Sendable {
    public let paths: Paths
    /// Where the settings come from (tests pass their own).
    public var settings: (Paths) -> AgentSettings = { AgentSettings.load($0) }
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    private let queue = DispatchQueue(label: "\(Brand.bundleIdentifierPrefix).remote")
    private var child: pid_t = 0
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var folder = ""
    private var startedAt = Date()
    private var quickExits = 0
    private var nextStart = Date.distantPast
    private var recentOutput = ""
    private var status = RemoteServerStatus(state: .off, detail: "", pid: nil, folder: "", since: Date())

    public init(paths: Paths) { self.paths = paths }

    var childRecordURL: URL { paths.run.appendingPathComponent("remote-child.json") }

    /// The arguments for the server (the login shell gives it the user's PATH, as a terminal would).
    static func arguments(claude: String, shell: String) -> [String] {
        [shell, "-l", "-c", "exec \"$@\"", "aos-remote", claude, "remote-control",
         "--spawn", "same-dir", "--no-create-session-in-dir", "--permission-mode", "default",
         "--remote-control-session-name-prefix", Brand.name]
    }

    public func run() {
        queue.async {
            self.reapLeftover()
            self.reconcile()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { [weak self] in self?.reconcile() }
            t.resume()
            self.timer = t
        }
    }

    /// Ends the server (aos-session is quitting). Synchronous enough for the 6 s aos-session waits.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            terminate(waitForExit: true)
            set(.off, "stopped")
        }
    }

    // MARK: Following the settings

    private func reconcile() {
        if status.state == .needsTrust { answerTrustIfAsked() }
        let s = settings(paths)
        guard s.newChats else {
            if child > 0 { log("remote: turned off in the settings"); terminate(waitForExit: false) }
            set(.off, "turned off in settings")
            return
        }
        let wanted = s.newChatsDirectory.path
        if child > 0 {
            guard wanted != folder else { return }
            log("remote: folder changed to \(wanted), starting again there")
            terminate(waitForExit: false)
            return  // the exit handler clears child; the next tick starts it in the new folder
        }
        guard Date() >= nextStart else { return }
        nextStart = Date().addingTimeInterval(15)
        guard let claude = ClaudeCode.executable() else {
            set(.missingClaude, "Claude Code is not installed")
            return
        }
        guard Network.reachable(host: "api.anthropic.com", port: 443) else {
            set(.waitingForNetwork, "")
            return
        }
        start(claude: claude.path, folder: wanted)
    }

    private func start(claude: String, folder: String) {
        let args = Self.arguments(claude: claude, shell: ClaudeCode.loginShell())
        guard let (pid, fd) = PTY.spawn(args, environment: ClaudeCode.cleanEnvironment(), cwd: folder,
                                        columns: 120, rows: 40) else {
            set(.restarting, "could not start Claude Code")
            nextStart = Date().addingTimeInterval(60)
            return
        }
        child = pid
        master = fd
        self.folder = folder
        startedAt = Date()
        recentOutput = ""
        try? JSONEncoder().encode(["pid": Int(pid)]).write(to: childRecordURL, options: .atomic)
        set(.starting, "")
        log("remote: started in \(folder) (pid \(pid))")

        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.setCancelHandler { close(fd) }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.ended(pid) }
        exit.resume()
        exitSource = exit

        // A server that is still there after 20 s runs (it prints nothing reliable to wait for)
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.child == pid, self.status.state == .starting,
                  !Self.plain(self.recentOutput).contains("[y/N]") else { return }
            self.set(.running, "")
        }
    }

    /// Reads what the server prints (nobody looks at it; a full pseudo terminal would stop it) and recognizes a
    /// missing sign-in.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(master, &buffer, buffer.count)
        guard n > 0 else { return }
        recentOutput += String(decoding: buffer[0..<n], as: UTF8.self)
        if recentOutput.count > 8000 { recentOutput = String(recentOutput.suffix(4000)) }
        let text = Self.plain(recentOutput)
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("claude auth login")
            || lower.contains("sign in to claude") {
            set(.needsLogin, "Claude Code is not signed in")
        } else if let range = text.range(of: "Trust ", options: .backwards), text[range.upperBound...].contains("? [y/N]"),
                  !text[range.upperBound...].contains("Ready") {
            set(.needsTrust, folder)
        } else if let ready = text.range(of: "Ready", options: .backwards), status.state != .running,
                  !text[ready.upperBound...].contains("[y/N]") {
            set(.running, "")
        }
    }

    /// Claude Code asked whether to trust the folder and the user said yes in the app: answer it.
    private func answerTrustIfAsked() {
        guard master >= 0, let data = FileManager.default.contents(atPath: RemoteServerStatus.trustURL(paths).path),
              let answer = try? JSONDecoder().decode([String: String].self, from: data), answer["folder"] == folder else { return }
        try? FileManager.default.removeItem(at: RemoteServerStatus.trustURL(paths))
        let yes: [UInt8] = Array("y\r".utf8)
        _ = Darwin.write(master, yes, yes.count)
        log("remote: the user trusts \(folder)")
        set(.starting, "")
    }

    /// Terminal output without colors and cursor movements, for recognizing what the server says.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    private func ended(_ pid: pid_t) {
        var code: Int32 = 0
        waitpid(pid, &code, WNOHANG)
        guard pid == child else { return }
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        child = 0
        master = -1
        try? FileManager.default.removeItem(at: childRecordURL)
        let ran = Date().timeIntervalSince(startedAt)
        if ran < 60 { quickExits += 1 } else { quickExits = 0 }
        let wait = quickExits == 0 ? 5 : min(30 * pow(2, Double(quickExits - 1)), 600)
        nextStart = Date().addingTimeInterval(wait)
        let lastLine = Self.plain(recentOutput).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        if status.state != .needsLogin && status.state != .off {
            let reason = lastLine.lowercased().contains("already served") ? "another server serves this folder" : "ended"
            set(.restarting, "\(reason) after \(Int(ran)) s, starting again in \(Int(wait)) s")
        }
        log("remote: ended after \(Int(ran)) s: \(String(lastLine.prefix(160)))")
    }

    /// Ends the server with SIGTERM (it says goodbye to the Claude app and ends within a second or two), SIGKILL
    /// after 15 s. Never SIGHUP: after one, the server stops answering any signal. A server that was killed stays
    /// registered for some minutes, and a new one in the same folder is refused until then.
    private func terminate(waitForExit: Bool) {
        let pid = child
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        guard waitForExit else {
            queue.asyncAfter(deadline: .now() + 15) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
            return
        }
        var status: Int32 = 0
        let asked = Date()
        defer { log("remote: stopped \(String(format: "%.1f", Date().timeIntervalSince(asked))) s after SIGTERM") }
        // Keep reading its terminal while waiting: on the way out the server still writes, and with nobody
        // reading (this queue is busy here) it would block on that write and never end.
        let fd = master
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<100 {
            if waitpid(pid, &status, WNOHANG) == pid || kill(pid, 0) != 0 { break }
            if fd >= 0 {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 100) > 0, p.revents & Int16(POLLIN) != 0 {
                    if Darwin.read(fd, &buffer, buffer.count) <= 0 { usleep(100_000) }
                }
            } else {
                usleep(100_000)
            }
        }
        if kill(pid, 0) == 0 {
            log("remote: no end within 10 s after SIGTERM, killing it (it stays registered for some minutes)")
            kill(pid, SIGKILL)
        }
        ended(pid)
    }

    /// A server left behind by an earlier run of aos-session that ended abruptly.
    private func reapLeftover() {
        guard let data = FileManager.default.contents(atPath: childRecordURL.path),
              let record = try? JSONDecoder().decode([String: Int].self, from: data), let raw = record["pid"] else { return }
        let pid = pid_t(raw)
        if pid > 0, kill(pid, 0) == 0, ClaudeConversations.isClaude(pid) {
            log("remote: ending a server left from before (pid \(pid))")
            kill(pid, SIGTERM)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: childRecordURL)
    }

    private func set(_ state: RemoteServerStatus.State, _ detail: String) {
        let changed = status.state != state || status.detail != detail
        status.state = state
        status.detail = detail
        status.pid = child > 0 ? child : nil
        status.folder = folder
        if changed {
            status.since = Date()
            if state != .waitingForNetwork || detail != "" { log("remote: \(state.rawValue)\(detail.isEmpty ? "" : " (\(detail))")") }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) { try? data.write(to: RemoteServerStatus.url(paths), options: .atomic) }
    }
}
