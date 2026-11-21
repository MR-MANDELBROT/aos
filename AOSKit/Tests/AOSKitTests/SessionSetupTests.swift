@testable import AOSKit
import XCTest

final class SessionSetupTests: XCTestCase {
    func texts(_ lines: [SetupLine]) -> [String] { lines.map(\.text) }

    func testPlan() {
        let none = SessionSetup()
        // Nothing wanted, nothing set: nothing to type
        XCTAssertEqual(SessionSetupPlan.lines(want: none, applied: none, sessionEffort: "").lines, [])
        // A routine with both: model first, then effort
        let both = SessionSetupPlan.lines(want: SessionSetup(model: "sonnet", effort: "low"), applied: none, sessionEffort: "")
        XCTAssertEqual(texts(both.lines), ["/model sonnet", "/effort low"])
        XCTAssertEqual(both.applied, SessionSetup(model: "sonnet", effort: "low"))
        // The same again: nothing
        XCTAssertEqual(SessionSetupPlan.lines(want: both.applied, applied: both.applied, sessionEffort: "").lines, [])
        // Then a reminder (no override): back to the session's own
        let back = SessionSetupPlan.lines(want: none, applied: both.applied, sessionEffort: "")
        XCTAssertEqual(texts(back.lines), ["/model default", "/effort auto"])
        XCTAssertEqual(back.applied, none)
        // The session's effort from the settings is what it goes back to
        XCTAssertEqual(texts(SessionSetupPlan.lines(want: none, applied: SessionSetup(effort: "low"), sessionEffort: "max").lines),
                       ["/effort max"])
        // Only the model changes: the effort stays as it is
        let model = SessionSetupPlan.lines(want: SessionSetup(model: "opus", effort: "low"), applied: both.applied, sessionEffort: "")
        XCTAssertEqual(texts(model.lines), ["/model opus"])
        // Only an effort wanted while a model is set: the model goes back
        let effort = SessionSetupPlan.lines(want: SessionSetup(effort: "low"), applied: both.applied, sessionEffort: "")
        XCTAssertEqual(texts(effort.lines), ["/model default"])
        XCTAssertEqual(effort.applied, SessionSetup(effort: "low"))
        // The effort wanted is the session's own: nothing to type, nothing to undo later
        let own = SessionSetupPlan.lines(want: SessionSetup(effort: "high"), applied: none, sessionEffort: "high")
        XCTAssertEqual(own.lines, [])
        XCTAssertEqual(own.applied, none)
        let ownAgain = SessionSetupPlan.lines(want: SessionSetup(effort: "high"), applied: SessionSetup(effort: "low"), sessionEffort: "high")
        XCTAssertEqual(texts(ownAgain.lines), ["/effort high"])
        XCTAssertEqual(ownAgain.applied, none)
    }

    func testReplies() {
        XCTAssertEqual(SessionSetupPlan.reply(to: .model, in: "> /model sonnet"), .none)
        // Claude Code's renderer may move the cursor instead of printing spaces
        XCTAssertEqual(SessionSetupPlan.reply(to: .model, in: "⎿  Setmodel to sonnet and saved as your default"), .done)
        XCTAssertEqual(SessionSetupPlan.reply(to: .model, in: "Switch model?\nYour next response will be slower and use more tokens\n❯ 1. Yes, switch to Sonnet"), .confirm)
        XCTAssertEqual(SessionSetupPlan.reply(to: .model, in: "Fable uses usage credits and needs a one-time consent"), .refuse)
        XCTAssertEqual(SessionSetupPlan.reply(to: .effort, in: "Set effort level to low (saved as your default for new sessions): Quick"), .done)
        XCTAssertEqual(SessionSetupPlan.reply(to: .effort, in: "Effort level set to auto"), .done)
        XCTAssertEqual(SessionSetupPlan.reply(to: .effort, in: "/effort high"), .none)
    }

    func testRoutineFields() throws {
        // Settings from before: no model, no effort
        let old = try JSONDecoder().decode(Routine.self, from: Data(#"{"id":"a","name":"x","schedule":"0 6 * * *","prompt":"p","enabled":true}"#.utf8))
        XCTAssertNil(old.model)
        XCTAssertNil(old.effort)
        XCTAssertNil(old.setup.model)
        let r = Routine(id: "b", name: "x", schedule: "0 6 * * *", prompt: "p", model: "sonnet[1m]", effort: "")
        XCTAssertNil(r.effort)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains("sonnet[1m]"))
        XCTAssertFalse(json.contains("effort"))
        XCTAssertTrue(Routine.isSafeModel("claude-opus-5-5"))
        XCTAssertTrue(Routine.isSafeModel("us.anthropic.claude-sonnet-5:0"))
        for bad in ["", "sonnet high", "sonnet\n/effort max", "\u{1B}[A", "-x", String(repeating: "a", count: 101), "sönnet"] {
            XCTAssertFalse(Routine.isSafeModel(bad), bad)
        }
        // A queued delivery from before keeps decoding
        let d = try JSONDecoder().decode(SessionDelivery.self, from: Data(#"{"kind":"note","name":"","text":"t","due":0,"ref":"n"}"#.utf8))
        XCTAssertNil(d.setup)
    }

    func testRoutineFromPhone() {
        let id = UUID().uuidString
        func json(_ extra: String) -> String {
            #"{"id":"\#(id)","name":"Check","schedule":"0 6 * * *","prompt":"p","enabled":true\#(extra)}"#
        }
        let r = CompanionControl.routine(fromPhone: json(#","model":"sonnet","effort":"HIGH""#))
        XCTAssertEqual(r?.model, "sonnet")
        XCTAssertEqual(r?.effort, "high")
        // Empty: the session's own
        let cleared = CompanionControl.routine(fromPhone: json(#","model":"","effort":"""#), existing: [r!])
        XCTAssertNil(cleared?.model)
        XCTAssertNil(cleared?.effort)
        // A phone that doesn't know the fields: the routine keeps them
        let older = CompanionControl.routine(fromPhone: json(""), existing: [r!])
        XCTAssertEqual(older?.model, "sonnet")
        XCTAssertEqual(older?.effort, "high")
        // Refused: an unknown effort, a model that would type more than a name
        XCTAssertNil(CompanionControl.routine(fromPhone: json(#","effort":"ultra""#)))
        XCTAssertNil(CompanionControl.routine(fromPhone: json(#","model":"sonnet\r/effort max""#)))
        XCTAssertNil(CompanionControl.routine(fromPhone: json(#","model":"opus now""#)))
    }

    func testUserSettingsEdits() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-claude-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = "{\n  \"attribution\": {\n    \"model\": \"keep\"\n  },\n  \"model\": \"opus[1m]\",\n  \"hooks\": {}\n}\n"
        try Data(original.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let s = ClaudeUserSettings(url: file)
        XCTAssertEqual(s.value("model"), .some("opus[1m]"))
        XCTAssertEqual(s.value("effortLevel"), .some(nil))
        // Changed, removed (last key too), added: only that line, the rest as it was
        XCTAssertTrue(s.set("model", to: "sonnet"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.replacingOccurrences(of: "opus[1m]", with: "sonnet"))
        XCTAssertTrue(s.set("model", to: nil))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\n  \"attribution\": {\n    \"model\": \"keep\"\n  },\n  \"hooks\": {}\n}\n")
        XCTAssertTrue(s.set("model", to: "opus[1m]"))
        XCTAssertEqual(s.value("model"), .some("opus[1m]"))
        XCTAssertTrue(s.set("hooks", to: "x"))  // not a one-line value: the whole object is written again
        XCTAssertEqual((s.read()?["attribution"] as? [String: String])?["model"], "keep")
        XCTAssertTrue(s.set("hooks", to: nil))
        XCTAssertTrue(s.set("effortLevel", to: nil))
        XCTAssertEqual(s.value("effortLevel"), .some(nil))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int), 0o600)
        // No file, or not JSON: left alone
        let missing = ClaudeUserSettings(url: file.appendingPathExtension("missing"))
        XCTAssertNil(missing.value("model"))
        XCTAssertFalse(missing.set("model", to: "x"))
        XCTAssertEqual(ClaudeUserSettings.edit("{}", key: "model", value: "a"), "{\n  \"model\": \"a\"\n}\n")
    }

    /// A routine with a model and an effort: the commands go in one by one, each once Claude Code answered, then the
    /// prompt; the user's defaults that the commands saved go back; afterwards, the session's own again.
    func testMessengerTypesCommandsThenPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-setup-\(UUID().uuidString)")
        let paths = Paths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude-settings.json")
        try Data("{\n  \"model\": \"opus[1m]\",\n  \"theme\": \"dark\"\n}\n".utf8).write(to: file)
        let claude = ClaudeUserSettings(url: file)
        var settings = AgentSettings()
        settings.sessionEffort = "high"
        settings.routines = [Routine(id: "r", name: "Check", schedule: "0 6 * * *", prompt: "Mach den Check",
                                     model: "sonnet", effort: "low")]
        let m = SessionMessenger(paths: paths)
        m.settings = { settings }
        m.claudeSettings = claude
        var idle = true
        var typed: [String] = []
        m.ready = { idle }
        m.type = { data, _ in typed.append(String(decoding: data, as: UTF8.self)) }
        let t0 = Date()
        m.runNow("r")
        m.tick(now: t0)
        XCTAssertEqual(typed, ["/model sonnet", "\r"])
        // Claude Code switches and saves the model as the user's default; aOS puts the user's own back and goes on
        claude.set("model", to: "sonnet")
        m.output("Set model to sonnet and saved as your default for new sessions", now: t0.addingTimeInterval(2))
        XCTAssertEqual(claude.value("model"), .some("opus[1m]"))
        XCTAssertEqual(Array(typed.suffix(2)), ["/effort low", "\r"])
        // No answer yet: nothing more
        m.tick(now: t0.addingTimeInterval(5))
        XCTAssertEqual(typed.count, 4)
        claude.set("effortLevel", to: "low")
        m.output("Set effort level to low (saved as your default for new sessions)", now: t0.addingTimeInterval(6))
        XCTAssertEqual(claude.value("effortLevel"), .some(nil))
        XCTAssertTrue(typed.last == "\r" && typed[typed.count - 2].contains("Mach den Check"), "\(typed)")
        XCTAssertEqual(m.applied, SessionSetup(model: "sonnet", effort: "low"))
        // It works, then is idle again with nothing waiting: back to the session's own
        idle = false
        m.tick(now: t0.addingTimeInterval(10))
        idle = true
        typed = []
        m.tick(now: t0.addingTimeInterval(20))
        XCTAssertEqual(typed, ["/model default", "\r"])
        m.output("Set model to Default (Opus)", now: t0.addingTimeInterval(21))
        XCTAssertEqual(Array(typed.suffix(2)), ["/effort high", "\r"])
        m.tick(now: t0.addingTimeInterval(45))  // no answer within 20 s: goes on anyway
        XCTAssertEqual(m.applied, SessionSetup())
        typed = []
        m.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(typed, [])
        // Warm cache: Claude Code asks whether to switch; aOS confirms once
        m.runNow("r")
        m.tick(now: t0.addingTimeInterval(70))
        XCTAssertEqual(typed, ["/model sonnet", "\r"])
        m.output("Switch model?  Your next response will be slower and use more tokens", now: t0.addingTimeInterval(71))
        XCTAssertEqual(typed.last, "\r")
        XCTAssertEqual(typed.count, 3)
        // A restart: the session runs with its own values again, nothing to undo
        m.sessionStarted()
        XCTAssertEqual(m.applied, SessionSetup())
        XCTAssertEqual(claude.value("model"), .some("opus[1m]"))
    }
}
