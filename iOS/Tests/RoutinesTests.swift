import Foundation
import Testing
@testable import aOS

/// aOS's session's routines as the Mac reports them, and the schedules the iPhone writes.
struct RoutinesTests {
    @Test func theStatusCarriesTheRoutines() throws {
        let json = """
        {"routines":{"items":[
            {"id":"A","name":"Morgen-Briefing","schedule":"0 6 * * *","prompt":"Briefing","enabled":true,"next":"2026-11-10T05:00:00Z"},
            {"id":"B","name":"Wochenplanung","schedule":"30 17 * * 0","prompt":"Planung","enabled":false},
            {"name":"ohne id"}],
          "reminders":[{"name":"Zahnarzt","at":"2026-11-10T07:05:00Z"}],"queued":1,
          "recent":[{"kind":"routine","name":"Routine-Check","at":"2026-11-09T13:13:00Z"}]}}
        """
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
        let routines = try #require(MacStatus(object).routines)
        #expect(routines.items.map(\.id) == ["A", "B"])
        #expect(routines.items[1].enabled == false)
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
        #expect(Set(object.keys) == ["id", "name", "schedule", "prompt", "enabled"])
        #expect(MacAction.routineSet.rawValue == "routines.set")
    }

    @Test func simpleSchedules() {
        #expect(RoutineSchedule.simple("0 6 * * *") == .init(hour: 6, minute: 0, weekdays: Set(0...6)))
        #expect(RoutineSchedule.simple("30 17 * * 0") == .init(hour: 17, minute: 30, weekdays: [0]))
        #expect(RoutineSchedule.simple("0 8 * * 1-5")?.weekdays == Set(1...5))
        #expect(RoutineSchedule.simple("0 8 * * 7")?.weekdays == [0])
        #expect(RoutineSchedule.simple("*/15 8 * * *") == nil)
        #expect(RoutineSchedule.simple("0 8 1 * *") == nil)
        #expect(RoutineSchedule.cron(hour: 17, minute: 30, weekdays: [0]) == "30 17 * * 0")
        #expect(RoutineSchedule.cron(hour: 6, minute: 0, weekdays: Set(0...6)) == "0 6 * * *")
        #expect(RoutineSchedule.looksValid("*/15 8-18 * * 1-5"))
        #expect(!RoutineSchedule.looksValid("jeden Tag"))
    }
}
