import Foundation

/// A cron schedule with five fields (minute, hour, day of month, month, day of week) in the Mac's local time, the
/// format of Cloupi's `config/crons.json`: lists (`1,15`), ranges (`1-5`), steps (`*/10`, `8-18/2`) and `*`. Day of
/// week 0 and 7 are Sunday. As in cron, when both day of month and day of week are restricted, either one matches.
public struct CronSchedule: Equatable, Sendable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let days: Set<Int>
    public let months: Set<Int>
    public let weekdays: Set<Int>
    let daysRestricted: Bool
    let weekdaysRestricted: Bool
    public let text: String

    public init?(_ text: String) {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
              let minutes = Self.parse(fields[0], 0...59),
              let hours = Self.parse(fields[1], 0...23),
              let days = Self.parse(fields[2], 1...31),
              let months = Self.parse(fields[3], 1...12),
              let weekdays = Self.parse(fields[4], 0...7) else { return nil }
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        // 7 is Sunday too
        self.weekdays = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        daysRestricted = fields[2] != "*"
        weekdaysRestricted = fields[4] != "*"
        self.text = fields.joined(separator: " ")
    }

    /// A field: `*`, numbers, ranges and steps, separated by commas. Nil when anything is out of range.
    static func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2, let base = pieces.first, !base.isEmpty else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else { return nil }
                step = s
            }
            var lo = range.lowerBound, hi = range.upperBound
            if base != "*" {
                let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count <= 2, let a = Int(bounds[0]) else { return nil }
                lo = a
                hi = a
                if bounds.count == 2 {
                    guard let b = Int(bounds[1]) else { return nil }
                    hi = b
                } else if pieces.count == 2 {
                    hi = range.upperBound  // "5/15": from 5 on
                }
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else { return nil }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// Whether the schedule fires in the minute of `date`.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        guard let minute = c.minute, let hour = c.hour, let day = c.day, let month = c.month,
              let weekday = c.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayOK = days.contains(day)
        let weekdayOK = weekdays.contains(weekday - 1)  // Calendar: 1 is Sunday
        if daysRestricted && weekdaysRestricted { return dayOK || weekdayOK }
        return dayOK && weekdayOK
    }

    /// The latest minute at or before `date` (and after `notBefore`) the schedule fires in, at most `window` back.
    public func latest(atOrBefore date: Date, notAfter window: TimeInterval = 6 * 3600, notBefore: Date? = nil,
                       calendar: Calendar = .current) -> Date? {
        guard let start = calendar.dateInterval(of: .minute, for: date)?.start else { return nil }
        let steps = Int(window / 60)
        for i in 0...steps {
            let t = start.addingTimeInterval(-Double(i) * 60)
            if let notBefore, t <= notBefore { return nil }
            if matches(t, calendar: calendar) { return t }
        }
        return nil
    }

    /// The next minute after `date` the schedule fires in (searched up to 400 days ahead).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard var t = calendar.dateInterval(of: .minute, for: date)?.start else { return nil }
        t = t.addingTimeInterval(60)
        // Jump whole days that can't match, then minutes within a day
        for _ in 0..<(400 * 24 * 60) {
            let c = calendar.dateComponents([.minute, .hour], from: t)
            if !hours.contains(c.hour ?? -1) {
                // to the next full hour
                t = calendar.dateInterval(of: .hour, for: t)?.end ?? t.addingTimeInterval(3600)
                continue
            }
            if matches(t, calendar: calendar) { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    /// The schedule as simple as it is: a daily time, times on some weekdays, or nil for anything else.
    public var simple: (times: [(hour: Int, minute: Int)], weekdays: Set<Int>)? {
        guard !daysRestricted, months.count == 12, minutes.count == 1, hours.count <= 6 else { return nil }
        let minute = minutes.first!
        return (hours.sorted().map { ($0, minute) }, weekdaysRestricted ? weekdays : Set(0...6))
    }

    /// Cron text for times on weekdays (0 is Sunday); all seven days give `*`.
    public static func text(hour: Int, minute: Int, weekdays: Set<Int>) -> String {
        let days = weekdays.isEmpty || weekdays.count == 7 ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
        return "\(minute) \(hour) * * \(days)"
    }
}

/// One or more cron schedules, separated by ";" (a routine at several times whose minutes differ, like Cloupi's
/// checks at 10:03, 12:07 and 14:13): it fires when any of them does.
public struct CronSet: Equatable, Sendable {
    public let schedules: [CronSchedule]

    public init?(_ text: String) {
        let parts = text.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var list: [CronSchedule] = []
        for p in parts {
            guard let c = CronSchedule(p) else { return nil }
            list.append(c)
        }
        schedules = list
    }

    /// The normalized text (each schedule as five fields, "; " between them).
    public var text: String { schedules.map(\.text).joined(separator: "; ") }

    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        schedules.contains { $0.matches(date, calendar: calendar) }
    }

    public func latest(atOrBefore date: Date, notAfter window: TimeInterval = 6 * 3600, notBefore: Date? = nil,
                       calendar: Calendar = .current) -> Date? {
        schedules.compactMap { $0.latest(atOrBefore: date, notAfter: window, notBefore: notBefore, calendar: calendar) }.max()
    }

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        schedules.compactMap { $0.next(after: date, calendar: calendar) }.min()
    }

    /// Times on the same weekdays (each schedule a daily time or several hours at one minute), else nil.
    public var simple: (times: [(hour: Int, minute: Int)], weekdays: Set<Int>)? {
        var times: [(hour: Int, minute: Int)] = []
        var days: Set<Int>?
        for c in schedules {
            guard let s = c.simple else { return nil }
            if let days, days != s.weekdays { return nil }
            days = s.weekdays
            times += s.times
        }
        guard let days else { return nil }
        let sorted = times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        var unique: [(hour: Int, minute: Int)] = []
        for t in sorted where !unique.contains(where: { $0.hour == t.hour && $0.minute == t.minute }) { unique.append(t) }
        return (unique, days)
    }

    /// Cron text for times on weekdays: one schedule per minute value (hours that share a minute go together).
    public static func text(times: [(hour: Int, minute: Int)], weekdays: Set<Int>) -> String {
        let days = weekdays.isEmpty || weekdays.count == 7 ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
        var byMinute: [Int: [Int]] = [:]
        for t in times { byMinute[t.minute, default: []].append(t.hour) }
        return byMinute.keys.sorted().map { m in
            let hours = Array(Set(byMinute[m]!)).sorted().map(String.init).joined(separator: ",")
            return "\(m) \(hours) * * \(days)"
        }.joined(separator: "; ")
    }

    /// Every `hours` hours from `from` to `to` (inclusive) at minute `minute`, on weekdays.
    public static func every(hours: Int, from: Int, to: Int, minute: Int, weekdays: Set<Int>) -> String {
        let days = weekdays.isEmpty || weekdays.count == 7 ? "*" : weekdays.sorted().map(String.init).joined(separator: ",")
        let range = from == 0 && to == 23 ? "*" : "\(from)-\(to)"
        return "\(minute) \(range)\(hours > 1 ? "/\(hours)" : "") * * \(days)"
    }

    /// An interval schedule as `every` writes it: (hours, from, to, minute, weekdays), else nil.
    public var interval: (hours: Int, from: Int, to: Int, minute: Int, weekdays: Set<Int>)? {
        guard schedules.count == 1, let c = schedules.first, c.minutes.count == 1 else { return nil }
        let fields = c.text.split(separator: " ")
        guard fields.count == 5, fields[2] == "*", fields[3] == "*" else { return nil }
        let hourField = String(fields[1])
        let parts = hourField.split(separator: "/")
        let step = parts.count == 2 ? Int(parts[1]) ?? 0 : 1
        guard step >= 1, parts.count <= 2 else { return nil }
        var from = 0, to = 23
        if parts[0] != "*" {
            let b = parts[0].split(separator: "-").compactMap { Int($0) }
            guard b.count == 2 else { return nil }
            from = b[0]; to = b[1]
        }
        guard step > 1 || parts[0] == "*" else { return nil }
        return (step, from, to, c.minutes.first!, c.weekdays.count == 7 ? Set(0...6) : c.weekdays)
    }
}
