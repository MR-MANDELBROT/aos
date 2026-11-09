@testable import AOSKit
import XCTest

final class RoutineTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testCronParsing() {
        XCTAssertNotNil(CronSchedule("0 6 * * *"))
        XCTAssertNotNil(CronSchedule("*/15 8-18 * * 1-5"))
        XCTAssertNotNil(CronSchedule("30 17 * * 0"))
        XCTAssertNotNil(CronSchedule("30 17 * * 7"))
        XCTAssertNil(CronSchedule("60 6 * * *"))
        XCTAssertNil(CronSchedule("0 6 * *"))
        XCTAssertNil(CronSchedule("a b c d e"))
        XCTAssertEqual(CronSchedule("30 17 * * 7")?.weekdays, [0])
    }

    func testMatching() {
        let weekly = CronSchedule("30 17 * * 0")!
        // 2026-11-08 is a Sunday
        XCTAssertTrue(weekly.matches(date("2026-11-08 17:30"), calendar: cal))
        XCTAssertFalse(weekly.matches(date("2026-11-09 17:30"), calendar: cal))
        let steps = CronSchedule("*/15 8-18 * * 1-5")!
        XCTAssertTrue(steps.matches(date("2026-11-09 08:45"), calendar: cal))
        XCTAssertFalse(steps.matches(date("2026-11-09 08:50"), calendar: cal))
        XCTAssertFalse(steps.matches(date("2026-11-08 08:45"), calendar: cal))
    }

    func testLatestAndNext() {
        let daily = CronSchedule("3 10 * * *")!
        XCTAssertEqual(daily.latest(atOrBefore: date("2026-11-09 12:00"), calendar: cal), date("2026-11-09 10:03"))
        // More than 6 hours ago: nothing to catch up
        XCTAssertNil(daily.latest(atOrBefore: date("2026-11-09 17:00"), calendar: cal))
        XCTAssertNil(daily.latest(atOrBefore: date("2026-11-09 12:00"), notBefore: date("2026-11-09 10:03"), calendar: cal))
        XCTAssertEqual(daily.next(after: date("2026-11-09 10:03"), calendar: cal), date("2026-11-10 10:03"))
        XCTAssertEqual(CronSchedule("30 17 * * 0")!.next(after: date("2026-11-09 12:00"), calendar: cal),
                       date("2026-11-15 17:30"))
    }

    func testSimpleForm() {
        let s = CronSchedule("13 14 * * *")!.simple
        XCTAssertEqual(s?.times.first?.hour, 14)
        XCTAssertEqual(s?.times.first?.minute, 13)
        XCTAssertEqual(s?.weekdays, Set(0...6))
        XCTAssertEqual(CronSchedule.text(hour: 17, minute: 30, weekdays: [0]), "30 17 * * 0")
        XCTAssertEqual(CronSchedule.text(hour: 6, minute: 0, weekdays: Set(0...6)), "0 6 * * *")
        XCTAssertNil(CronSchedule("0 6 1 * *")!.simple)
    }

    func testRoutinesDue() {
        let morning = Routine(id: "m", name: "Morgen-Briefing", schedule: "0 6 * * *", prompt: "Briefing")
        let check = Routine(id: "c", name: "Routine-Check", schedule: "3 10 * * *", prompt: "Check")
        let off = Routine(id: "o", name: "Aus", schedule: "0 6 * * *", prompt: "x", enabled: false)
        // The Mac slept from 05:00 to 11:00: both are due once, each with its own time
        let last = ["m": date("2026-11-09 05:00"), "c": date("2026-11-09 05:00"), "o": date("2026-11-09 05:00")]
        let due = RoutinePlanner.due([morning, check, off], lastRun: last, now: date("2026-11-09 11:00"), calendar: cal)
        XCTAssertEqual(due.map(\.ref), ["m", "c"])
        XCTAssertEqual(due.first?.due, date("2026-11-09 06:00"))
        // Already sent: nothing again
        let after = ["m": date("2026-11-09 06:00"), "c": date("2026-11-09 10:03")]
        XCTAssertTrue(RoutinePlanner.due([morning, check], lastRun: after, now: date("2026-11-09 11:00"), calendar: cal).isEmpty)
        // Unknown to the planner (new): nothing
        XCTAssertTrue(RoutinePlanner.due([morning], lastRun: [:], now: date("2026-11-09 11:00"), calendar: cal).isEmpty)
    }

    func testInboxDecisions() throws {
        let now = date("2026-11-10 08:10")
        let json = #"{"text":"Erinnerung","at":"2026-11-10T08:05:00+01:00","source":"erinnerungen"}"#
        let m = try JSONDecoder().decode(InboxMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.source, "erinnerungen")
        XCTAssertEqual(RoutinePlanner.decide(m, now: now), .deliver)
        XCTAssertEqual(RoutinePlanner.decide(m, now: date("2026-11-10 08:00")), .wait)
        XCTAssertEqual(RoutinePlanner.decide(m, now: date("2026-11-10 08:40")), .drop)
        let note = try JSONDecoder().decode(InboxMessage.self, from: Data(#"{"text":"Watchdog: alles gut"}"#.utf8))
        XCTAssertEqual(RoutinePlanner.decide(note, now: now), .deliver)
        XCTAssertThrowsError(try JSONDecoder().decode(InboxMessage.self, from: Data(#"{"text":"x","at":"morgen"}"#.utf8)))
    }

    func testDeliveryHeader() {
        let d = SessionDelivery(kind: .routine, name: "Routine-Check", text: "Lies prompts/routine-check.md",
                                due: date("2026-11-09 10:03"), ref: "c")
        let text = d.message(now: date("2026-11-09 10:03"))
        XCTAssertTrue(text.hasPrefix("[aOS routine \"Routine-Check\", scheduled "))
        XCTAssertTrue(text.hasSuffix("\nLies prompts/routine-check.md"))
        XCTAssertTrue(d.message(now: date("2026-11-09 11:00")).contains("delivered late"))
    }

    func testEnvironmentFile() {
        let text = """
        # Kommentar
        export CLOUPI_AGENT=1
        MCP_TIMEOUT = 180000
        TOKEN="a b c"
        NAME='x'
        1BAD=no
        nonsense
        """
        let env = EnvironmentFile.parse(text)
        XCTAssertEqual(env["CLOUPI_AGENT"], "1")
        XCTAssertEqual(env["MCP_TIMEOUT"], "180000")
        XCTAssertEqual(env["TOKEN"], "a b c")
        XCTAssertEqual(env["NAME"], "x")
        XCTAssertNil(env["1BAD"])
        XCTAssertEqual(env.count, 4)
    }

    func testSettingsRoundTrip() throws {
        var s = AgentSettings()
        s.sessionFolder = "~/cloupi"
        s.sessionEffort = "max"
        s.sessionEnvFiles = ["~/cloupi/config/aos-session.env"]
        s.routines = [Routine(id: "m", name: "Morgen-Briefing", schedule: "0 6 * * *", prompt: "Briefing")]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AgentSettings.self, from: data)
        XCTAssertEqual(back.routines, s.routines)
        XCTAssertEqual(back.sessionEffort, "max")
        XCTAssertEqual(back.sessionFolder, "~/cloupi")
        let odd = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"sessionEffort":"ultra"}"#.utf8))
        XCTAssertEqual(odd.sessionEffort, "")
    }
}

final class SessionMessengerTests: XCTestCase {
    func testQueueAndDeliverOnlyWhenIdle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-messenger-\(UUID().uuidString)")
        let paths = Paths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AgentSettings()
        settings.routines = [Routine(id: "r", name: "Check", schedule: "* * * * *", prompt: "Mach den Check")]
        let m = SessionMessenger(paths: paths)
        m.settings = { settings }
        var idle = false
        var typed: [String] = []
        m.ready = { idle }
        m.type = { data, _ in typed.append(String(decoding: data, as: UTF8.self)) }
        // 5 seconds into a minute, so all later ticks fall into the next minute only
        let t0 = Calendar.current.dateInterval(of: .minute, for: Date())!.start.addingTimeInterval(5)
        m.tick(now: t0)  // the routine is new: it starts from now
        XCTAssertTrue(m.state.queue.isEmpty)
        // A minute later it is due, but Claude Code works: it waits in the queue
        m.tick(now: t0.addingTimeInterval(61))
        XCTAssertEqual(m.state.queue.count, 1)
        XCTAssertTrue(typed.isEmpty)
        // A reminder and a note in the inbox
        try Data(#"{"text":"Erinnerung","at":"2000-01-01T00:00:00Z"}"#.utf8)
            .write(to: paths.inbox.appendingPathComponent("old.json"))
        try Data(#"{"text":"Hinweis vom Watchdog","source":"watchdog"}"#.utf8)
            .write(to: paths.inbox.appendingPathComponent("note.json"))
        try Data("kein json".utf8).write(to: paths.inbox.appendingPathComponent("bad.json"))
        m.tick(now: t0.addingTimeInterval(62))
        XCTAssertEqual(m.state.queue.map(\.kind), [.routine, .note])  // the old reminder was dropped
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.inbox.appendingPathComponent("Invalid/bad.json").path))
        // Idle: the first one goes in as one pasted message, then Enter
        idle = true
        m.tick(now: t0.addingTimeInterval(70))
        XCTAssertEqual(typed.count, 2)
        XCTAssertTrue(typed[0].hasPrefix("\u{1B}[200~[aOS routine \"Check\""))
        XCTAssertTrue(typed[0].contains("Mach den Check"))
        XCTAssertEqual(typed[1], "\r")
        XCTAssertEqual(m.state.queue.count, 1)
        // While it has not been taken (still idle), nothing else goes in; after 10 s Enter once more
        m.tick(now: t0.addingTimeInterval(75))
        XCTAssertEqual(typed.count, 2)
        m.tick(now: t0.addingTimeInterval(81))
        XCTAssertEqual(typed.last, "\r")
        // It works (not idle), then idle again: the note goes in
        idle = false
        m.tick(now: t0.addingTimeInterval(90))
        idle = true
        m.tick(now: t0.addingTimeInterval(100))
        XCTAssertTrue(typed.contains { $0.contains("[aOS note from watchdog]") }, "\(typed) queue \(m.state.queue.map(\.kind))")
        XCTAssertTrue(m.state.queue.isEmpty)
        XCTAssertEqual(RoutinesStatus.read(paths)?.recent.count, 2)
    }
}

final class CronSetTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testCloupisChecksAsOneRoutine() throws {
        let times = [(10, 3), (12, 7), (14, 13), (16, 17), (18, 23)].map { (hour: $0.0, minute: $0.1) }
        let text = CronSet.text(times: times, weekdays: Set(0...6))
        let set = try XCTUnwrap(CronSet(text))
        XCTAssertEqual(set.schedules.count, 5)
        XCTAssertEqual(set.next(after: date("2026-11-09 12:30"), calendar: cal), date("2026-11-09 14:13"))
        XCTAssertEqual(set.latest(atOrBefore: date("2026-11-09 17:00"), calendar: cal), date("2026-11-09 16:17"))
        let simple = try XCTUnwrap(set.simple)
        XCTAssertEqual(simple.times.map { "\($0.hour):\($0.minute)" }, ["10:3", "12:7", "14:13", "16:17", "18:23"])
        XCTAssertEqual(simple.weekdays, Set(0...6))
        // A routine with several times is due once, at the latest one missed
        let r = Routine(id: "c", name: "Routine-Check", schedule: text, prompt: "Check")
        let due = RoutinePlanner.due([r], lastRun: ["c": date("2026-11-09 09:00")], now: date("2026-11-09 13:00"), calendar: cal)
        XCTAssertEqual(due.map(\.due), [date("2026-11-09 12:07")])
    }

    func testSameMinuteGoesTogether() {
        XCTAssertEqual(CronSet.text(times: [(8, 0), (12, 0), (18, 30)].map { (hour: $0.0, minute: $0.1) }, weekdays: [1, 2, 3, 4, 5]),
                       "0 8,12 * * 1,2,3,4,5; 30 18 * * 1,2,3,4,5")
    }

    func testEveryNHours() throws {
        let text = CronSet.every(hours: 2, from: 10, to: 18, minute: 3, weekdays: Set(0...6))
        XCTAssertEqual(text, "3 10-18/2 * * *")
        let set = try XCTUnwrap(CronSet(text))
        XCTAssertEqual(set.next(after: date("2026-11-09 10:03"), calendar: cal), date("2026-11-09 12:03"))
        let i = try XCTUnwrap(set.interval)
        XCTAssertEqual(i.hours, 2); XCTAssertEqual(i.from, 10); XCTAssertEqual(i.to, 18); XCTAssertEqual(i.minute, 3)
        XCTAssertEqual(CronSet("0 * * * *")?.interval?.hours, 1)
        XCTAssertNil(CronSet("0 6 * * *")?.interval)
        XCTAssertNil(CronSet("0 6 * * *; 0 7 * * *")?.interval)
    }

    func testInvalidPartsMakeItInvalid() {
        XCTAssertNil(CronSet("0 6 * * *; kaputt"))
        XCTAssertNil(CronSet(" ; "))
        XCTAssertEqual(CronSet("0 6 * * *;30  7 * * 1")?.text, "0 6 * * *; 30 7 * * 1")
    }
}
