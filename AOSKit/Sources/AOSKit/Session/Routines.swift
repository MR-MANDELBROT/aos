import Foundation

/// A prompt aOS sends into its own session on a schedule (Settings > Session > Routines).
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Cron, five fields, local time (`CronSchedule`).
    public var schedule: String
    public var prompt: String
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, schedule: String, prompt: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
    }

    public var cron: CronSchedule? { CronSchedule(schedule) }
}

/// A message for the session that someone else left in aOS's inbox (`<aOS>/inbox/*.json`): a reminder for a time
/// (`at`), or a note to deliver as soon as the session is free. Any program may write one (write a temporary file
/// whose name starts with a dot, then rename it): `{"text": "...", "at": "2026-11-10T08:05:00+01:00", "source": "..."}`.
public struct InboxMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var at: Date?
    public var source: String?

    public init(id: String = UUID().uuidString, text: String, at: Date? = nil, source: String? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, text, at, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try c.decode(String.self, forKey: .text)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        if let s = try c.decodeIfPresent(String.self, forKey: .at) {
            guard let d = Self.parseDate(s) else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "not an ISO 8601 time")
            }
            at = d
        } else {
            at = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(at.map { ISO8601DateFormatter().string(from: $0) }, forKey: .at)
    }

    /// ISO 8601 with or without fractional seconds.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// Something to send into the session: what, why, and when it was due.
public struct SessionDelivery: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case routine, reminder, note, start }
    public var kind: Kind
    public var name: String
    public var text: String
    public var due: Date
    /// The routine's or message's id (routines: to note when it last ran).
    public var ref: String

    public init(kind: Kind, name: String, text: String, due: Date, ref: String) {
        self.kind = kind
        self.name = name
        self.text = text
        self.due = due
        self.ref = ref
    }

    /// What arrives in the session: a header line that says where it comes from, then the text.
    public func message(now: Date) -> String {
        let time = Self.clock.string(from: due)
        let late = now.timeIntervalSince(due) > 5 * 60
        let header: String
        switch kind {
        case .routine:
            header = "[aOS routine \"\(name)\", scheduled \(time)\(late ? ", delivered late after the Mac was asleep or busy" : "")]"
        case .reminder:
            header = "[aOS reminder for \(time)\(name.isEmpty ? "" : " from \(name)")]"
        case .note:
            header = "[aOS note\(name.isEmpty ? "" : " from \(name)")]"
        case .start:
            header = "[aOS: the session just started]"
        }
        return header + "\n" + text
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// When to send what: routines missed while the Mac slept come up to 6 hours late (only the latest time per
/// routine), reminders up to 30 minutes late (later ones are dropped), notes whenever the session is free. A new or
/// changed routine starts from now (nothing from before it existed).
public enum RoutinePlanner {
    public static let routineCatchUp: TimeInterval = 6 * 3600
    public static let reminderLate: TimeInterval = 30 * 60

    /// Routines due now. `lastRun`: per routine id the scheduled time it last went out (or when it was created).
    public static func due(_ routines: [Routine], lastRun: [String: Date], now: Date,
                           calendar: Calendar = .current) -> [SessionDelivery] {
        routines.compactMap { r in
            guard r.enabled, let cron = r.cron, let since = lastRun[r.id],
                  let t = cron.latest(atOrBefore: now, notAfter: routineCatchUp, notBefore: since, calendar: calendar)
            else { return nil }
            return SessionDelivery(kind: .routine, name: r.name, text: r.prompt, due: t, ref: r.id)
        }
    }

    /// What happens to an inbox message now.
    public enum InboxDecision: Equatable { case wait, deliver, drop }

    public static func decide(_ m: InboxMessage, now: Date) -> InboxDecision {
        guard let at = m.at else { return .deliver }
        if at > now { return .wait }
        return now.timeIntervalSince(at) > reminderLate ? .drop : .deliver
    }

    /// The next times each enabled routine runs (for the settings and the iPhone).
    public static func upcoming(_ routines: [Routine], after now: Date, calendar: Calendar = .current) -> [RoutinesStatus.Next] {
        routines.compactMap { r in
            guard r.enabled, let next = r.cron?.next(after: now, calendar: calendar) else { return nil }
            return RoutinesStatus.Next(id: r.id, name: r.name, at: next)
        }.sorted { $0.at < $1.at }
    }
}

/// What the session's scheduler shows the app and the iPhone (run/routines.json).
public struct RoutinesStatus: Codable, Sendable, Equatable {
    public struct Next: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var at: Date
    }
    public struct Delivered: Codable, Sendable, Equatable {
        public var kind: SessionDelivery.Kind
        public var name: String
        public var due: Date
        public var at: Date
    }
    public var next: [Next] = []
    /// Reminders waiting in the inbox (time and the beginning of the text).
    public var reminders: [Next] = []
    /// Waiting to be sent (the session is busy or not running).
    public var queued: Int = 0
    public var recent: [Delivered] = []
    public var updated = Date()

    public init() {}

    public static func url(_ paths: Paths) -> URL { paths.run.appendingPathComponent("routines.json") }

    public static func read(_ paths: Paths) -> RoutinesStatus? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: url(paths).path) else { return nil }
        return try? d.decode(RoutinesStatus.self, from: data)
    }

    public func write(_ paths: Paths) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(self) { try? data.write(to: Self.url(paths), options: .atomic) }
    }
}

/// The session's environment files: `KEY=VALUE` lines (`export` allowed, `#` comments, quotes removed). Values
/// are never logged.
public enum EnvironmentFile {
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  !(key.first?.isNumber ?? true) else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}
