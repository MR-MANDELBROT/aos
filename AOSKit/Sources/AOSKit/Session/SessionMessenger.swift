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
    }

    /// A routine right now (Run Now in the app or on the iPhone).
    func runNow(_ id: String) {
        guard let r = settings().routines.first(where: { $0.id == id }) else { return }
        enqueue(SessionDelivery(kind: .routine, name: r.name, text: r.prompt, due: Date(), ref: r.id))
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
        guard !state.queue.isEmpty, ready() else { return }
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
}
