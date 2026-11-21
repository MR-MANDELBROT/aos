import Foundation
import Testing
@testable import aOS

/// aOS's session's routines as the Mac reports them, and the schedules the iPhone writes.
struct RoutinesTests {
    @Test func theStatusCarriesTheRoutines() throws {
        let json = """
        {"routines":{"items":[
            {"id":"A","name":"Morgen-Briefing","schedule":"0 6 * * *","prompt":"Briefing","enabled":true,"next":"2026-11-10T05:00:00Z"},
            {"id":"B","name":"Wochenplanung","schedule":"30 17 * * 0","prompt":"Planung","enabled":false,"model":"sonnet","effort":"low"},
            {"name":"ohne id"}],
          "reminders":[{"name":"Zahnarzt","at":"2026-11-10T07:05:00Z"}],"queued":1,
          "recent":[{"kind":"routine","name":"Routine-Check","at":"2026-11-09T13:13:00Z"}],"overrides":true}}
        """
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
        let routines = try #require(MacStatus(object).routines)
        #expect(routines.items.map(\.id) == ["A", "B"])
        #expect(routines.items[1].enabled == false)
        #expect(routines.items[1].model == "sonnet")
        #expect(routines.items[1].effort == "low")
        #expect(routines.items[0].model == nil)
        #expect(routines.overrides)
        #expect(routines.next?.id == "A")
        #expect(routines.reminders.first?.name == "Zahnarzt")
        #expect(routines.queued == 1)
        #expect(routines.recent.first?.kind == "routine")
        // An older Mac: no routines
        #expect(MacStatus([:]).routines == nil)
    }

    @Test func aRoutineGoesToTheMacWithoutItsNextTime() throws {
        let item = MacStatus.Routines.Item(id: "A", name: "Check", schedule: "3 10 * * *", prompt: "Mach", enabled: true,
                                           next: Date())
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "schedule", "prompt", "enabled", "model", "effort"])
        // The session's own: empty, so the Mac clears what the routine had
        #expect(object["model"] as? String == "")
        var set = item
        set.model = "sonnet"
        set.effort = "low"
        let setObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        #expect(setObject["model"] as? String == "sonnet")
        #expect(setObject["effort"] as? String == "low")
        #expect(RoutineSetupText.setup(set) != nil)
        #expect(RoutineSetupText.setup(item) == nil)
        #expect(RoutineSetupText.models(including: "claude-opus-5-5").last == "claude-opus-5-5")
        #expect(MacAction.routineSet.rawValue == "routines.set")
    }

    @Test func simpleSchedules() {
        #expect(RoutineSchedule.simple("0 6 * * *") == .init(times: [.init(hour: 6, minute: 0)], weekdays: Set(0...6)))
        #expect(RoutineSchedule.simple("30 17 * * 0")?.weekdays == [0])
        #expect(RoutineSchedule.simple("0 8 * * 1-5")?.weekdays == Set(1...5))
        #expect(RoutineSchedule.simple("0 8 * * 7")?.weekdays == [0])
        #expect(RoutineSchedule.simple("*/15 8 * * *") == nil)
        #expect(RoutineSchedule.simple("0 8 1 * *") == nil)
        // Cloupi's checks as one routine
        let checks = "3 10 * * *; 7 12 * * *; 13 14 * * *; 17 16 * * *; 23 18 * * *"
        #expect(RoutineSchedule.simple(checks)?.times.map(\.hour) == [10, 12, 14, 16, 18])
        #expect(RoutineSchedule.cron(times: [(10, 3), (12, 7)], weekdays: Set(0...6)) == "3 10 * * *; 7 12 * * *")
        #expect(RoutineSchedule.cron(times: [(8, 0), (12, 0)], weekdays: [1, 2]) == "0 8,12 * * 1,2")
        #expect(RoutineSchedule.cron(hour: 17, minute: 30, weekdays: [0]) == "30 17 * * 0")
        #expect(RoutineSchedule.looksValid("*/15 8-18 * * 1-5"))
        #expect(RoutineSchedule.looksValid(checks))
        #expect(!RoutineSchedule.looksValid("jeden Tag"))
    }

    @Test func everyFewHours() {
        #expect(RoutineSchedule.every(hours: 2, from: 10, to: 18, minute: 3, weekdays: Set(0...6)) == "3 10-18/2 * * *")
        #expect(RoutineSchedule.interval("3 10-18/2 * * *") == .init(hours: 2, from: 10, to: 18, minute: 3, weekdays: Set(0...6)))
        #expect(RoutineSchedule.interval("0 * * * 1-5")?.hours == 1)
        #expect(RoutineSchedule.interval("0 6 * * *") == nil)
    }
}
