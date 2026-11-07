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
            let unsigned = await c.handle(request(op, text: op == CompanionControl.stayAwake ? "off" : nil))
            XCTAssertFalse(unsigned.ok, op)
            XCTAssertEqual(unsigned.code, "pair-again", op)
        }
        XCTAssertEqual(controls.sleeps, 0)
        XCTAssertNil(controls.stayAwake)
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

    @MainActor
    func testHelloListsWhatThisMacOffers() async throws {
        let (c, _, _, _) = try controller()
        let hello = await c.handle(phone.sign(request("companion.hello")))
        let features = try XCTUnwrap(try object(hello)["features"] as? [String])
        XCTAssertTrue(features.contains("mac.sleep"))
        XCTAssertTrue(features.contains("term"))
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
