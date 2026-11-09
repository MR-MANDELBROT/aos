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
