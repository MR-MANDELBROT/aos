import Foundation

/// Claude Code's own record of a running process (~/.claude/sessions/<pid>.json): its conversation and whether it
/// waits for input ("idle"), works ("busy") or waits for an answer in a dialog ("waiting"). Read only.
public enum ClaudeRegistry {
    public struct Entry: Equatable, Sendable {
        public var sessionId: String?
        public var status: String?
    }

    public static func entry(pid: Int32, folder: URL? = nil) -> Entry? {
        let base = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let data = FileManager.default.contents(atPath: base.appendingPathComponent("\(pid).json").path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["pid"] as? Int).map({ Int32($0) == pid }) ?? true else { return nil }
        return Entry(sessionId: json["sessionId"] as? String, status: json["status"] as? String)
    }
}

/// Sends routines, reminders and notes into aOS's session: what is due goes into a queue (kept in
/// run/routines-state.json, so a restart loses nothing), and the head of the queue is typed into the session's
/// terminal only while Claude Code waits for input ("idle" in its registry): never while it works, and never into a
/// question or permission dialog. Runs on the supervisor's queue.
final class SessionMessenger {
    struct State: Codable {
        /// Per routine: the scheduled time it last went out (or when aOS first saw it).
        var lastRun: [String: Date] = [:]
        /// The schedule each routine had then (a changed schedule starts from now).
        var schedules: [String: String] = [:]
        var queue: [SessionDelivery] = []
        var recent: [RoutinesStatus.Delivered] = []
    }

    let paths: Paths
    var log: (String) -> Void = { _ in }
    /// The session runs and Claude Code waits for input.
    var ready: () -> Bool = { false }
    /// Types into the session's terminal (after a delay in seconds).
    var type: (Data, Double) -> Void = { _, _ in }
    var settings: () -> AgentSettings
    private(set) var state = State()
    /// After typing: when, and whether Enter was sent a second time already.
    private var sentAt: Date?
    private var resent = false
    private var startMessageDue: Date?
    /// Claude Code's user settings, where `/model` and `/effort` save their value as the new default (aOS puts the
    /// user's own back).
    var claudeSettings = ClaudeUserSettings.standard
    /// The model and effort aOS set with its own commands since the session started (nil: the session's own).
    private(set) var applied = SessionSetup()
    /// Commands still to type before the head of the queue (or to go back to the session's own).
    private var lines: [SetupLine] = []
    /// The command typed last, while its answer is awaited.
    private var command: Command?
    /// The user's defaults to put back once Claude Code saved a command's value over them.
    private var defaults: [Default] = []

    private struct Command {
        var line: SetupLine
        var at: Date
        var output = ""
        var confirmed = false
        var resent = false
    }

    private struct Default {
        var key: String
        var before: String?
        var written: String?
        var until: Date
    }

    init(paths: Paths) {
        self.paths = paths
        let p = paths
        settings = { AgentSettings.load(p) }
        load()
    }

    var stateURL: URL { paths.run.appendingPathComponent("routines-state.json") }
    var inbox: URL { paths.inbox }

    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: stateURL.path), let s = try? d.decode(State.self, from: data) {
            state = s
        }
    }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// The session (re)started: the start message goes in once it has settled.
    func sessionStarted() {
        startMessageDue = Date().addingTimeInterval(60)
        sentAt = nil
        // A new process starts with the session's own model and effort
        applied = SessionSetup()
        lines = []
        command = nil
    }

    /// The session's terminal output (escape sequences removed): the answer to a command aOS typed lets the next
    /// line go in at once.
    func output(_ text: String, now: Date = Date()) {
        guard var c = command else { return }
        c.output = String((c.output + text).suffix(4000))
        command = c
        if SessionSetupPlan.reply(to: c.line.kind, in: c.output) != .none {
            deliver(now: now)
            save()
        }
    }

    /// A routine right now (Run Now in the app or on the iPhone).
    func runNow(_ id: String) {
        guard let r = settings().routines.first(where: { $0.id == id }) else { return }
        enqueue(SessionDelivery(kind: .routine, name: r.name, text: r.prompt, due: Date(), ref: r.id, setup: r.setup))
        save()
    }

    func tick(now: Date = Date()) {
        let s = settings()
        planRoutines(s.routines, now: now)
        let waiting = readInbox(now: now)
        if let due = startMessageDue, now >= due {
            startMessageDue = nil
            let text = s.sessionStartMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { enqueue(SessionDelivery(kind: .start, name: "", text: text, due: now, ref: "start")) }
        }
        deliver(now: now)
        save()
        var status = RoutinesStatus()
        status.next = RoutinePlanner.upcoming(s.routines, after: now)
        status.reminders = waiting
        status.queued = state.queue.count
        status.recent = state.recent
        status.updated = now
        status.write(paths)
    }

    /// Due routines into the queue; new or changed routines start from now; deleted ones are forgotten.
    private func planRoutines(_ routines: [Routine], now: Date) {
        let ids = Set(routines.map(\.id))
        for id in state.lastRun.keys where !ids.contains(id) { state.lastRun[id] = nil; state.schedules[id] = nil }
        for r in routines where state.lastRun[r.id] == nil || state.schedules[r.id] != r.schedule {
            state.lastRun[r.id] = now
            state.schedules[r.id] = r.schedule
        }
        for d in RoutinePlanner.due(routines, lastRun: state.lastRun, now: now) {
            state.lastRun[d.ref] = d.due
            // The same routine twice in the queue (the session was busy for hours): only the newest
            state.queue.removeAll { $0.kind == .routine && $0.ref == d.ref }
            enqueue(d)
        }
    }

    private func enqueue(_ d: SessionDelivery) {
        state.queue.append(d)
        log("session messages: queued \(d.kind.rawValue) \(d.name.isEmpty ? d.ref : "\"\(d.name)\"")")
    }

    /// Messages from the inbox folder: due ones into the queue (the file goes), too late ones dropped, later ones
    /// wait (returned for the status). Unreadable files move to Inbox/Invalid.
    private func readInbox(now: Date) -> [RoutinesStatus.Next] {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var waiting: [RoutinesStatus.Next] = []
        for file in files {
            guard let data = fm.contents(atPath: file.path),
                  let m = try? JSONDecoder().decode(InboxMessage.self, from: data),
                  !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let invalid = inbox.appendingPathComponent("Invalid", isDirectory: true)
                try? fm.createDirectory(at: invalid, withIntermediateDirectories: true)
                try? fm.moveItem(at: file, to: invalid.appendingPathComponent(file.lastPathComponent))
                log("session messages: \(file.lastPathComponent) is not a message, moved to Inbox/Invalid")
                continue
            }
            switch RoutinePlanner.decide(m, now: now) {
            case .wait:
                if let at = m.at { waiting.append(.init(id: m.id, name: String(m.text.prefix(80)), at: at)) }
            case .drop:
                try? fm.removeItem(at: file)
                log("session messages: reminder \(m.id) from \(m.source ?? "?") dropped, more than 30 minutes late")
            case .deliver:
                enqueue(SessionDelivery(kind: m.at == nil ? .note : .reminder, name: m.source ?? "", text: m.text,
                                        due: m.at ?? now, ref: m.id))
                try? fm.removeItem(at: file)
            }
        }
        return waiting.sorted { $0.at < $1.at }
    }

    /// The head of the queue into the session, when Claude Code waits for input.
    private func deliver(now: Date) {
        if let at = sentAt {
            // Claude Code took it once it works or the session ended; else Enter once more after 10 s.
            if !ready() || now.timeIntervalSince(at) > 60 {
                sentAt = nil
            } else if !resent, now.timeIntervalSince(at) > 10 {
                type(Data("\r".utf8), 0)
                resent = true
                log("session messages: no reaction yet, pressed Enter once more")
                return
            } else {
                return
            }
        }
        putBackDefaults(now: now)
        if command != nil, !finishCommand(now: now) { return }
        guard ready() else { return }
        // The model and effort the head of the queue wants (nothing waiting: the session's own again)
        if lines.isEmpty {
            let plan = SessionSetupPlan.lines(want: state.queue.first?.setup ?? SessionSetup(), applied: applied,
                                              sessionEffort: settings().sessionEffort)
            lines = plan.lines
            applied = plan.applied
        }
        if !lines.isEmpty {
            typeCommand(lines.removeFirst(), now: now)
            return
        }
        guard !state.queue.isEmpty else { return }
        let d = state.queue.removeFirst()
        // Bracketed paste: the lines arrive as one message; Enter sends it.
        var bytes = Data("\u{1B}[200~".utf8)
        bytes.append(Data(d.message(now: now).utf8))
        bytes.append(Data("\u{1B}[201~".utf8))
        type(bytes, 0)
        type(Data("\r".utf8), 0.6)
        sentAt = now
        resent = false
        state.recent.insert(.init(kind: d.kind, name: d.name, due: d.due, at: now), at: 0)
        state.recent = Array(state.recent.prefix(20))
        log("session messages: sent \(d.kind.rawValue) \(d.name.isEmpty ? d.ref : "\"\(d.name)\"")")
    }

    /// Types `/model X` or `/effort X` as its own line. Claude Code answers such a command at once, without working
    /// (its registry stays "idle"), so aOS waits for the answer in the terminal output instead.
    private func typeCommand(_ line: SetupLine, now: Date) {
        let key = ClaudeUserSettings.key(line.kind)
        if case .some(let before) = claudeSettings.value(key) {
            let written: String? = line.value == (line.kind == .model ? "default" : "auto") ? nil : line.value
            defaults.append(Default(key: key, before: before, written: written, until: now.addingTimeInterval(30)))
        }
        type(Data(line.text.utf8), 0)
        type(Data("\r".utf8), 0.6)
        command = Command(line: line, at: now)
        log("session messages: typed \(line.text)")
    }

    /// Whether the command typed last is through: answered, or no answer within 20 s (Enter once more after 8 s). Confirms Claude Code's
    /// "Switch model?" (the conversation's cache is warm) once; closes any other question it asks (usage credits, a
    /// hook that wants a person) with Escape.
    private func finishCommand(now: Date) -> Bool {
        guard var c = command else { return true }
        switch SessionSetupPlan.reply(to: c.line.kind, in: c.output) {
        case .done:
            command = nil
            putBackDefaults(now: now)
            return true
        case .confirm where !c.confirmed:
            type(Data("\r".utf8), 0)
            c.confirmed = true
            c.output = ""
            command = c
            log("session messages: confirmed switching the model")
            return false
        case .refuse, .confirm:
            if ready() { type(Data("\u{1B}".utf8), 0) }
            command = nil
            log("session messages: \(c.line.text) asks something aOS doesn't answer, closed it")
            return false
        case .none:
            // The first Enter may have gone to the command menu: once more after 8 s
            if !c.resent, !c.confirmed, now.timeIntervalSince(c.at) > 8, ready() {
                type(Data("\r".utf8), 0)
                c.resent = true
                command = c
                return false
            }
            guard now.timeIntervalSince(c.at) > 20 else { return false }
            command = nil
            log("session messages: no answer to \(c.line.text) within 20 s")
            putBackDefaults(now: now)
            return true
        }
    }

    /// `/model` and `/effort` saved their value as the user's default for new sessions: the user's own goes back
    /// (only while the file still holds what the command wrote, so a change of the user's own stays).
    private func putBackDefaults(now: Date) {
        for d in defaults {
            guard case .some(let current) = claudeSettings.value(d.key), current != d.before,
                  current?.lowercased() == d.written?.lowercased() else { continue }
            if claudeSettings.set(d.key, to: d.before) {
                log("session messages: put the user's default \(d.key) back in Claude Code's settings")
            }
        }
        defaults.removeAll { now > $0.until }
    }
}
