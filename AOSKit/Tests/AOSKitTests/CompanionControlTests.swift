@testable import AOSKit
import Darwin
import XCTest

/// The phone's Overview: a signed status and signed actions (CompanionControl).
final class CompanionControlTests: XCTestCase {
    @MainActor
    final class FakeControls: MacControls {
        var sleepResult: MacSleepResult = .sleeping(after: 1.5)
        var sleeps = 0
        var stayAwake: StayAwake?
        var refuseStayAwake: MacControlRefusal?

        func awakeStatus() -> MacAwakeStatus {
            MacAwakeStatus(setting: stayAwake ?? .lidClosed, holding: true, lidClosedMode: false, blocker: nil,
                           helper: "enabled", otherService: false)
        }

        func sleepMac() async -> MacSleepResult {
            sleeps += 1
            return sleepResult
        }

        func setStayAwake(_ mode: StayAwake) -> MacControlRefusal? {
            if let refuseStayAwake { return refuseStayAwake }
            stayAwake = mode
            return nil
        }

        /// Never the real display: the tests run on a Mac someone uses.
        var displays: [Bool] = []
        func setDisplay(on: Bool) async { displays.append(on) }
        var batteryLimit = 10
        func setBatteryLimit(_ percent: Int) -> MacControlRefusal? { batteryLimit = percent; return nil }
        var routines: [Routine] = []
        func updateRoutines(_ change: (inout [Routine]) -> Void) { change(&routines) }
        /// The conversation changes, as the app would make them in its settings.
        var changes: [(String, ConversationChange)] = []
        func changeConversation(_ id: String, _ change: ConversationChange) -> MacControlRefusal? {
            changes.append((id, change))
            return nil
        }
    }

    final class LogBox: @unchecked Sendable { var lines: [String] = [] }

    let phone = TestPhone()

    /// A controller in a folder short enough for its sockets.
    @MainActor
    func controller() throws -> (WorkspaceController, FakeControls, LogBox, Paths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aosc-\(UUID().uuidString.prefix(6))")
        let paths = Paths(root: root)
        try paths.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let c = WorkspaceController(paths: paths, bitwarden: BitwardenVault(paths: paths, store: MemorySessionStore()),
                                    phoneKeys: MemoryPhoneKeys([phone.trusted]))
        let controls = FakeControls()
        c.macControls = controls
        let log = LogBox()
        c.log = { log.lines.append($0) }
        return (c, controls, log, paths)
    }

    func object(_ response: AgentResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
    }

    func request(_ op: String, text: String? = nil) -> AgentRequest {
        var r = AgentRequest(id: 1, op: op)
        r.text = text
        return r
    }

    @MainActor
    func testEveryOpNeedsTheSignature() async throws {
        let (c, controls, _, _) = try controller()
        for op in CompanionControl.ops {
            let text = op == CompanionControl.stayAwake ? "off"
                : CompanionControl.chatOps.contains(op) ? "5f0c1c2e-8b1d-4d0e-9a51-0b8f6f2f7a10" : nil
            let unsigned = await c.handle(request(op, text: text))
            XCTAssertFalse(unsigned.ok, op)
            XCTAssertEqual(unsigned.code, "pair-again", op)
        }
        XCTAssertEqual(controls.sleeps, 0)
        XCTAssertNil(controls.stayAwake)
        XCTAssertTrue(controls.changes.isEmpty)
        // A changed parameter breaks the signature: the text is in the signed data.
        var r = phone.sign(request(CompanionControl.stayAwake, text: "lidOpen"))
        r.text = "off"
        let tampered = await c.handle(r)
        XCTAssertEqual(tampered.code, "invalid")
        XCTAssertNil(controls.stayAwake)
    }

    @MainActor
    func testTheStatus() async throws {
        // The controls stay alive (the controller holds them weakly, as it holds the app).
        let (c, controls, _, _) = try controller()
        defer { withExtendedLifetime(controls) {} }
        let response = await c.handle(phone.sign(request(CompanionControl.status)))
        XCTAssertTrue(response.ok, response.text)
        let status = try XCTUnwrap(try object(response)["status"] as? [String: Any])
        let power = try XCTUnwrap(status["power"] as? [String: Any])
        XCTAssertNotNil(power["source"] as? String)
        XCTAssertTrue(["open", "closed", "none"].contains(power["lid"] as? String ?? ""))
        let display = try XCTUnwrap(status["display"] as? [String: Any])
        XCTAssertTrue(["on", "off", "none"].contains(display["state"] as? String ?? ""), "\(display)")
        XCTAssertNotNil(display["external"] as? Int)
        let awake = try XCTUnwrap(status["awake"] as? [String: Any])
        XCTAssertEqual(awake["setting"] as? String, "lidClosed")
        XCTAssertEqual(awake["holding"] as? Bool, true)
        let workspace = try XCTUnwrap(status["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["state"] as? String, "stopped")
        XCTAssertEqual(workspace["setupComplete"] as? Bool, false)
        XCTAssertNotNil(status["session"] as? [String: Any])
        XCTAssertNotNil(status["newChats"] as? [String: Any])
        XCTAssertNotNil((status["bitwarden"] as? [String: Any])?["state"] as? String)
        XCTAssertTrue(c.companion.phoneConnected, "a status counts as the phone being there")
    }

    @MainActor
    func testSleepGoesThroughTheAppAndSaysWhyNot() async throws {
        let (c, controls, log, _) = try controller()
        let ok = await c.handle(phone.sign(request(CompanionControl.sleep)))
        XCTAssertTrue(ok.ok, ok.text)
        XCTAssertEqual(try object(ok)["sleeping"] as? Bool, true)
        XCTAssertEqual(controls.sleeps, 1)
        controls.sleepResult = .refused(.sleepDisabled)
        let refused = await c.handle(phone.sign(request(CompanionControl.sleep)))
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.code, "sleep-disabled")
        XCTAssertTrue(refused.text.contains("pmset disablesleep"))
        XCTAssertTrue(log.lines.contains { $0.contains("asks the Mac to sleep") })
    }

    @MainActor
    func testTheDisplayGoesThroughTheAppAndTheStatusComesBack() async throws {
        let (c, controls, log, _) = try controller()
        let off = await c.handle(phone.sign(request(CompanionControl.displayOff)))
        XCTAssertTrue(off.ok, off.text)
        XCTAssertNotNil((try object(off)["status"] as? [String: Any])?["display"] as? [String: Any])
        let on = await c.handle(phone.sign(request(CompanionControl.displayOn)))
        XCTAssertTrue(on.ok, on.text)
        XCTAssertEqual(controls.displays, [false, true])
        XCTAssertTrue(log.lines.contains { $0.contains("turns the display on") })
        XCTAssertTrue(CompanionControl.features.contains("mac.display-on"))
    }

    @MainActor
    func testStayAwakeTakesOnlyItsChoices() async throws {
        let (c, controls, _, _) = try controller()
        let ok = await c.handle(phone.sign(request(CompanionControl.stayAwake, text: "lidOpen")))
        XCTAssertTrue(ok.ok, ok.text)
        XCTAssertEqual(controls.stayAwake, .lidOpen)
        let nonsense = await c.handle(phone.sign(request(CompanionControl.stayAwake, text: "always")))
        XCTAssertFalse(nonsense.ok)
        XCTAssertEqual(controls.stayAwake, .lidOpen)
        controls.refuseStayAwake = .otherService
        let other = await c.handle(phone.sign(request(CompanionControl.stayAwake, text: "off")))
        XCTAssertEqual(other.code, "other-service")
    }

    @MainActor
    func testTheWorkspaceNeedsItsSetupAndStoppingAStoppedOneIsFine() async throws {
        let (c, _, _, _) = try controller()
        let start = await c.handle(phone.sign(request(CompanionControl.workspaceStart)))
        XCTAssertFalse(start.ok)
        XCTAssertEqual(start.code, "not-set-up")
        let stop = await c.handle(phone.sign(request(CompanionControl.workspaceStop)))
        XCTAssertTrue(stop.ok, stop.text)
    }

    @MainActor
    func testBitwardenLocks() async throws {
        let (c, _, log, _) = try controller()
        let lock = await c.handle(phone.sign(request(CompanionControl.bitwardenLock)))
        XCTAssertTrue(lock.ok, lock.text)
        XCTAssertTrue(log.lines.contains { $0.contains("locks Bitwarden") })
    }

    @MainActor
    func testRestartingTheSessionTellsTheBackgroundProcess() async throws {
        let (c, _, _, paths) = try controller()
        let missing = await c.handle(phone.sign(request(CompanionControl.sessionRestart)))
        XCTAssertEqual(missing.code, "no-session")
        // aos-session's socket: the restart command arrives there.
        let path = paths.run.appendingPathComponent("session.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try TermSocket.address(path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        defer { close(listener); unlink(path) }
        let received = expectation(description: "restart command")
        final class Box: @unchecked Sendable { var bytes: [UInt8] = [] }
        let box = Box()
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.bytes = Array(buffer[0..<n]) }
            close(fd)
            received.fulfill()
        }
        let restart = await c.handle(phone.sign(request(CompanionControl.sessionRestart)))
        XCTAssertTrue(restart.ok, restart.text)
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(String(decoding: box.bytes, as: UTF8.self), "\u{1B}]aos;restart\u{07}")
    }

    // MARK: Chats

    /// Two transcripts in folders of the test's own (never the real ~/.claude): one used an hour ago, one yesterday.
    @MainActor
    func chatsController() throws -> (WorkspaceController, FakeControls, LogBox, Paths, recent: String, older: String) {
        let (c, controls, log, paths) = try controller()
        let projects = paths.root.appendingPathComponent("projects/-Users-x-project")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        c.conversationSources = ClaudeConversations.Sources(projects: paths.root.appendingPathComponent("projects"),
                                                            desktop: paths.root.appendingPathComponent("desktop"))
        var recent = Transcript(in: projects)
        recent.cwd = FileManager.default.homeDirectoryForCurrentUser.path + "/Developer/annex"
        recent.prompt(Date().addingTimeInterval(-3600))
        recent.reply(Date().addingTimeInterval(-3500))
        recent.keeperStart(Date().addingTimeInterval(-60))
        recent.title("Rechnungen")
        try recent.write()
        var older = Transcript(in: projects, entrypoint: "cli")
        older.prompt(Date().addingTimeInterval(-26 * 3600))
        try older.write()
        return (c, controls, log, paths, recent.id, older.id)
    }

    func writeKeeper(_ paths: Paths, _ entries: [KeeperStatus.Entry], commands: [String]? = ["restart"]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let status = KeeperStatus(enabled: true, entries: entries, updated: Date(), commands: commands)
        try encoder.encode(status).write(to: SessionKeeper.statusURL(paths))
    }

    func entry(_ id: String, _ state: KeeperStatus.State, detail: String = "") -> KeeperStatus.Entry {
        KeeperStatus.Entry(id: id, title: "Rechnungen", cwd: "/", pinned: false, state: state, detail: detail, pid: 42,
                           since: Date(), lastActivity: Date())
    }

    @MainActor
    func testTheChatsAsThePhoneSeesThem() async throws {
        let (c, _, _, paths, recent, older) = try chatsController()
        var s = c.settings
        s.keepReachable = true
        s.skippedConversations = [older]
        try c.updateSettings(s)
        try writeKeeper(paths, [entry(recent, .openElsewhere, detail: KeeperStatus.Detail.inClaudeApp)])
        let response = await c.handle(phone.sign(request(CompanionControl.chatsList)))
        XCTAssertTrue(response.ok, response.text)
        let body = try object(response)
        XCTAssertNotNil(body["status"] as? [String: Any], "every answer carries the status")
        let chats = try XCTUnwrap(body["chats"] as? [String: Any])
        XCTAssertEqual(chats["enabled"] as? Bool, true)
        XCTAssertEqual(chats["restart"] as? Bool, true)
        let list = try XCTUnwrap(chats["list"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["id"] as? String }, [recent, older], "the person's last use first")
        XCTAssertEqual(list[0]["title"] as? String, "Rechnungen")
        XCTAssertEqual(list[0]["folder"] as? String, "~/Developer/annex")
        XCTAssertEqual(list[0]["origin"] as? String, "app")
        XCTAssertEqual(list[0]["state"] as? String, "openElsewhere")
        XCTAssertEqual(list[0]["note"] as? String, "app")
        XCTAssertNil(list[0]["reason"])
        let activity = try XCTUnwrap(ISO8601DateFormatter().date(from: list[0]["activity"] as? String ?? ""))
        XCTAssertEqual(activity.timeIntervalSinceNow, -3500, accuracy: 2, "the answer, not the keeper's start")
        XCTAssertEqual(list[1]["origin"] as? String, "terminal")
        XCTAssertEqual(list[1]["skipped"] as? Bool, true)
        XCTAssertEqual(list[1]["reason"] as? String, "skipped")
        XCTAssertNil(list[1]["state"])
    }

    @MainActor
    func testChangingAChatGoesThroughTheApp() async throws {
        let (c, controls, log, _, recent, _) = try chatsController()
        for (op, change) in [(CompanionControl.chatsPin, ConversationChange.pin), (CompanionControl.chatsUnpin, .unpin),
                             (CompanionControl.chatsSkip, .skip), (CompanionControl.chatsUnskip, .unskip)] {
            let response = await c.handle(phone.sign(request(op, text: recent)))
            XCTAssertTrue(response.ok, response.text)
            XCTAssertNotNil(try object(response)["chats"] as? [String: Any])
            XCTAssertEqual(controls.changes.last?.0, recent)
            XCTAssertEqual(controls.changes.last?.1, change)
        }
        XCTAssertTrue(log.lines.contains { $0.contains("pin") })
        let nonsense = await c.handle(phone.sign(request(CompanionControl.chatsPin, text: "../settings.json")))
        XCTAssertFalse(nonsense.ok)
        XCTAssertEqual(controls.changes.count, 4)
        // The id is signed: another one breaks the signature
        var r = phone.sign(request(CompanionControl.chatsSkip, text: recent))
        r.text = "5f0c1c2e-8b1d-4d0e-9a51-0b8f6f2f7a10"
        let tampered = await c.handle(r)
        XCTAssertEqual(tampered.code, "invalid")
        XCTAssertEqual(controls.changes.count, 4)
    }

    @MainActor
    func testRestartingAChatTellsTheKeeper() async throws {
        let (c, _, log, paths, recent, older) = try chatsController()
        var s = c.settings
        s.keepReachable = true
        try c.updateSettings(s)
        let restart = { (id: String) in await c.handle(self.phone.sign(self.request(CompanionControl.chatsRestart, text: id))) }
        var answer = await restart(recent)
        XCTAssertEqual(answer.code, "no-keeper", "no keeper status")
        try writeKeeper(paths, [entry(recent, .running), entry(older, .openElsewhere)], commands: nil)
        answer = await restart(recent)
        XCTAssertEqual(answer.code, "keeper-old", "a keeper from before can't")
        try writeKeeper(paths, [entry(recent, .running), entry(older, .openElsewhere)])
        answer = await restart(older)
        XCTAssertEqual(answer.code, "not-kept", "open elsewhere: nothing of aOS's runs")
        answer = await restart(recent)
        XCTAssertEqual(answer.code, "no-keeper", "aos-session's socket isn't there")

        // aos-session's socket: the keeper's command arrives there.
        let path = paths.run.appendingPathComponent("session.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try TermSocket.address(path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        defer { close(listener); unlink(path) }
        let received = expectation(description: "keeper command")
        final class Box: @unchecked Sendable { var bytes: [UInt8] = [] }
        let box = Box()
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 128)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { box.bytes = Array(buffer[0..<n]) }
            close(fd)
            received.fulfill()
        }
        answer = await restart(recent)
        XCTAssertTrue(answer.ok, answer.text)
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(SessionSupervisor.keeperRestart(in: Data(box.bytes)), recent)
        XCTAssertTrue(log.lines.contains { $0.contains("restarts the kept conversation") })
    }

    @MainActor
    func testRoutinesFromThePhone() async throws {
        let (c, controls, _, _) = try controller()
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","name":" Routine-Check ","schedule":"3  10 * * *","prompt":"Lies prompts/routine-check.md","enabled":true}"#
        let saved = await c.handle(phone.sign(request(CompanionControl.routineSet, text: json)))
        XCTAssertTrue(saved.ok, saved.text)
        XCTAssertEqual(controls.routines.first?.name, "Routine-Check")
        XCTAssertEqual(controls.routines.first?.schedule, "3 10 * * *")
        // Changed under the same id: replaced, not added
        let changed = json.replacingOccurrences(of: "3  10", with: "13 14")
        _ = await c.handle(phone.sign(request(CompanionControl.routineSet, text: changed)))
        XCTAssertEqual(controls.routines.count, 1)
        XCTAssertEqual(controls.routines.first?.schedule, "13 14 * * *")
        // Not a schedule, no name, not JSON: refused
        for bad in [json.replacingOccurrences(of: "3  10 * * *", with: "jeden Tag"),
                    json.replacingOccurrences(of: " Routine-Check ", with: " "), "kein json"] {
            let r = await c.handle(phone.sign(request(CompanionControl.routineSet, text: bad)))
            XCTAssertFalse(r.ok, bad)
        }
        XCTAssertEqual(controls.routines.count, 1)
        let unknown = await c.handle(phone.sign(request(CompanionControl.routineRun, text: UUID().uuidString)))
        XCTAssertFalse(unknown.ok)
        let deleted = await c.handle(phone.sign(request(CompanionControl.routineDelete, text: id)))
        XCTAssertTrue(deleted.ok, deleted.text)
        XCTAssertTrue(controls.routines.isEmpty)
        let status = try XCTUnwrap(try object(deleted)["status"] as? [String: Any])
        XCTAssertNotNil((status["routines"] as? [String: Any])?["items"] as? [Any])
    }

    @MainActor
    func testHelloListsWhatThisMacOffers() async throws {
        let (c, _, _, _) = try controller()
        let hello = await c.handle(phone.sign(request("companion.hello")))
        let features = try XCTUnwrap(try object(hello)["features"] as? [String])
        XCTAssertTrue(features.contains("mac.sleep"))
        XCTAssertTrue(features.contains("term"))
        XCTAssertTrue(features.contains("chats.list"))
        XCTAssertTrue(features.contains("chats.restart"))
        XCTAssertFalse(features.contains { $0.hasPrefix("companion.") })
    }

    func testSleepPolicy() {
        XCTAssertEqual(SleepPolicy.next(aosHolds: true, sleepDisabled: 1, otherService: false), .releaseHold)
        XCTAssertEqual(SleepPolicy.next(aosHolds: false, sleepDisabled: 0, otherService: false), .sleep)
        XCTAssertEqual(SleepPolicy.next(aosHolds: false, sleepDisabled: nil, otherService: false), .sleep)
        XCTAssertEqual(SleepPolicy.next(aosHolds: false, sleepDisabled: 1, otherService: false), .refuse(.sleepDisabled))
        XCTAssertEqual(SleepPolicy.next(aosHolds: false, sleepDisabled: 1, otherService: true), .refuse(.otherService))
        XCTAssertEqual(SleepPolicy.next(aosHolds: false, sleepDisabled: 0, otherService: true), .sleep)
    }

    func testWorkspaceStatesForThePhone() {
        XCTAssertEqual(CompanionControl.workspaceState(.running, leased: true), "open")
        XCTAssertEqual(CompanionControl.workspaceState(.running, leased: false), "running")
        XCTAssertEqual(CompanionControl.workspaceState(.suspending, leased: false), "closing")
        XCTAssertEqual(CompanionControl.workspaceState(.paused, leased: false), "stopped")
        XCTAssertEqual(CompanionControl.workspaceState(.error, leased: false), "failed")
    }
}
