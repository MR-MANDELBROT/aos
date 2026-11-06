@testable import AOSKit
import Darwin
import XCTest

// Staying awake, freezing and network care (Docs/DESIGN.md, "Staying awake, freezing and the hotspot").

final class AwakePolicyTests: XCTestCase {
    func facts(_ setting: StayAwake, needed: Bool = true, lid: Bool? = false, onAC: Bool = false, percent: Int? = 60,
               hot: Bool = false, external: Bool = false, cloupi: Bool = false, helper: Bool = true) -> AwakeFacts {
        AwakeFacts(setting: setting, needed: needed, lidClosed: lid, onAC: onAC, batteryPercent: percent,
                   thermalCritical: hot, externalDisplay: external, cloupiPresent: cloupi, helperReady: helper)
    }

    func testOffDoesNothing() {
        XCTAssertEqual(AwakePolicy.decide(facts(.off, lid: true)), AwakeDecision())
    }

    func testCloupiOwnsSleepWhateverTheSetting() {
        for setting in StayAwake.allCases {
            let d = AwakePolicy.decide(facts(setting, lid: true, cloupi: true))
            XCTAssertFalse(d.idleAssertion)
            XCTAssertFalse(d.holdLidClosed)
            XCTAssertFalse(d.lidClosedMode)
            XCTAssertEqual(d.blocker, .cloupi)
        }
    }

    func testLidOpenOnlyPreventsIdleSleep() {
        let d = AwakePolicy.decide(facts(.lidOpen, lid: true))
        XCTAssertTrue(d.idleAssertion)
        XCTAssertFalse(d.holdLidClosed)
        XCTAssertFalse(d.lidClosedMode)
    }

    func testNothingToKeepMeansNormalSleep() {
        let d = AwakePolicy.decide(facts(.lidClosed, needed: false, lid: true))
        XCTAssertEqual(d, AwakeDecision(blocker: .nothingToKeep))
    }

    func testLidClosedHoldsAlreadyWhileOpen() {
        // Set only when the lid closes, the Mac would be asleep before anyone could react.
        let open = AwakePolicy.decide(facts(.lidClosed, lid: false))
        XCTAssertTrue(open.idleAssertion)
        XCTAssertTrue(open.holdLidClosed)
        XCTAssertFalse(open.lidClosedMode)
        let closed = AwakePolicy.decide(facts(.lidClosed, lid: true))
        XCTAssertTrue(closed.holdLidClosed)
        XCTAssertTrue(closed.lidClosedMode)
        XCTAssertNil(closed.blocker)
    }

    func testExternalDisplayOrUnknownLidNeverFreezes() {
        let desk = AwakePolicy.decide(facts(.lidClosed, lid: true, external: true))
        XCTAssertTrue(desk.holdLidClosed)
        XCTAssertFalse(desk.lidClosedMode)
        let unknown = AwakePolicy.decide(facts(.lidClosed, lid: nil))
        XCTAssertTrue(unknown.holdLidClosed)
        XCTAssertFalse(unknown.lidClosedMode)
    }

    func testHelperMissingFallsBackToLidOpen() {
        let d = AwakePolicy.decide(facts(.lidClosed, lid: true, helper: false))
        XCTAssertTrue(d.idleAssertion)
        XCTAssertFalse(d.holdLidClosed)
        XCTAssertFalse(d.lidClosedMode)
        XCTAssertEqual(d.blocker, .helperNotReady)
    }

    func testLowBatteryAndHeatLetTheMacSleep() {
        let low = AwakePolicy.decide(facts(.lidClosed, lid: true, percent: 9))
        XCTAssertFalse(low.holdLidClosed)
        XCTAssertEqual(low.blocker, .lowBattery)
        XCTAssertTrue(AwakePolicy.decide(facts(.lidClosed, lid: true, percent: 10)).holdLidClosed)
        // On the power adapter the charge doesn't matter
        XCTAssertTrue(AwakePolicy.decide(facts(.lidClosed, lid: true, onAC: true, percent: 3)).holdLidClosed)
        // Unknown charge (a desktop Mac) holds
        XCTAssertTrue(AwakePolicy.decide(facts(.lidClosed, lid: true, percent: nil)).holdLidClosed)
        let hot = AwakePolicy.decide(facts(.lidClosed, lid: true, onAC: true, hot: true))
        XCTAssertFalse(hot.holdLidClosed)
        XCTAssertEqual(hot.blocker, .thermal)
    }
}

final class HoldPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func hold(_ lease: Date?, cloupi: Bool = false, onAC: Bool = false, percent: Int? = 50, hot: Bool = false) -> Bool {
        HoldPolicy.shouldHold(leaseUntil: lease, now: now, cloupiPresent: cloupi, onAC: onAC, batteryPercent: percent,
                              thermalCritical: hot)
    }

    func testLease() {
        XCTAssertFalse(hold(nil))
        XCTAssertFalse(hold(now))
        XCTAssertFalse(hold(now.addingTimeInterval(-1)))
        XCTAssertTrue(hold(now.addingTimeInterval(60)))
    }

    func testNeverAgainstCloupiHeatOrAnEmptyBattery() {
        let lease = now.addingTimeInterval(60)
        XCTAssertFalse(hold(lease, cloupi: true))
        XCTAssertFalse(hold(lease, hot: true))
        XCTAssertFalse(hold(lease, percent: 9))
        XCTAssertTrue(hold(lease, onAC: true, percent: 9))
    }

    func testLeaseIsBounded() {
        XCTAssertEqual(HoldPolicy.clampedLease(-5), 0)
        XCTAssertEqual(HoldPolicy.clampedLease(30), 30)
        XCTAssertEqual(HoldPolicy.clampedLease(10_000), HoldPolicy.maxLeaseSeconds)
    }

    func testParsesPmset() {
        let on = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         sleep                1 (sleep prevented by Claude)
        """
        XCTAssertEqual(HoldPolicy.parseDisableSleep(on), 1)
        XCTAssertEqual(HoldPolicy.parseDisableSleep("Currently in use:\n sleep 1\n displaysleep 20\n"), 0)
    }

    func testCloupiDetection() {
        XCTAssertFalse(CloupiPresence.detect(fileExists: { _ in false }))
        XCTAssertTrue(CloupiPresence.detect(fileExists: { $0 == "/Library/Application Support/cloupi-wake" }))
        XCTAssertTrue(CloupiPresence.detect(fileExists: { $0 == "/Library/LaunchDaemons/de.cloupi.waked.plist" }))
    }

    func testDisplayPolicy() {
        XCTAssertTrue(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 3, builtinAwake: true, externalDisplays: 0,
                                                          sinceLast: 60, sessionShared: false))
        XCTAssertFalse(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 1, builtinAwake: true, externalDisplays: 0,
                                                           sinceLast: 60, sessionShared: false))
        XCTAssertFalse(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 3, builtinAwake: false, externalDisplays: 0,
                                                           sinceLast: 60, sessionShared: false))
        XCTAssertFalse(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 3, builtinAwake: true, externalDisplays: 1,
                                                           sinceLast: 60, sessionShared: false))
        XCTAssertFalse(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 3, builtinAwake: true, externalDisplays: 0,
                                                           sinceLast: 5, sessionShared: false))
        XCTAssertFalse(LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: 3, builtinAwake: true, externalDisplays: 0,
                                                           sinceLast: 60, sessionShared: true))
    }
}

final class PowerSettingsTests: XCTestCase {
    func decode(_ json: String) throws -> AgentSettings {
        try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
    }

    func testOldKeepAwakeIsMigrated() throws {
        XCTAssertEqual(try decode("{\"keepAwake\": false}").stayAwake, .off)
        XCTAssertEqual(try decode("{\"keepAwake\": true}").stayAwake, .lidOpen)
        XCTAssertEqual(try decode("{}").stayAwake, .lidOpen)
        XCTAssertEqual(try decode("{\"keepAwake\": false, \"stayAwake\": \"lidClosed\"}").stayAwake, .lidClosed)
        // A value from a newer version falls back instead of failing the whole file
        XCTAssertEqual(try decode("{\"stayAwake\": \"always\"}").stayAwake, .lidOpen)
    }

    func testHotspotChoice() throws {
        XCTAssertNil(try decode("{}").hotspotJoin)
        XCTAssertEqual(try decode("{\"hotspotJoin\": \"manual\"}").hotspotJoin, .manual)
        XCTAssertNil(try decode("{\"hotspotJoin\": \"sometimes\"}").hotspotJoin)
    }

    func testRoundTripWritesTheNewKeys() throws {
        var s = AgentSettings()
        s.stayAwake = .lidClosed
        s.hotspotJoin = .automatic
        let data = try JSONEncoder().encode(s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"stayAwake\":\"lidClosed\""))
        XCTAssertTrue(text.contains("\"hotspotJoin\":\"automatic\""))
        XCTAssertFalse(text.contains("keepAwake"))
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: data), s)
    }
}

final class FreezePlannerTests: XCTestCase {
    let uid: uid_t = 501
    let me: Int32 = 50

    func p(_ pid: Int32, _ ppid: Int32, _ name: String, uid: uid_t = 501, stopped: Bool = false) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, uid: uid, startSec: Int(pid) * 10, startUsec: 0, name: name, stopped: stopped)
    }

    var table: [Int32: ProcessEntry] {
        let list = [
            p(1, 0, "launchd", uid: 0),
            p(50, 1, "aOS"),
            p(100, 1, "Safari"), p(101, 1, "com.apple.WebKi"), p(102, 100, "helper"),
            p(200, 1, "Music"),
            p(300, 1, "Terminal"), p(301, 300, "login"), p(302, 301, "zsh"), p(303, 302, "claude"),
            p(400, 1, "Editor"), p(401, 400, "zsh"), p(402, 401, "aos-mcp"),
            p(500, 1, "Claude"),
            p(600, 1, "Hidden Bar"),
            p(700, 1, "Mail"), p(701, 700, "rooted", uid: 0),
            p(800, 1, "Notes", stopped: true),
            p(900, 1, "Preview"), p(901, 900, "claude-like"),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
    }

    var apps: [RunningAppInfo] {
        [
            RunningAppInfo(pid: 50, bundleID: "dev.marquart.aos", name: "aOS", regular: true),
            RunningAppInfo(pid: 100, bundleID: "com.apple.Safari", name: "Safari", regular: true),
            RunningAppInfo(pid: 200, bundleID: "com.apple.Music", name: "Music", regular: true),
            RunningAppInfo(pid: 300, bundleID: "com.apple.Terminal", name: "Terminal", regular: true),
            RunningAppInfo(pid: 400, bundleID: "com.example.Editor", name: "Editor", regular: true),
            RunningAppInfo(pid: 500, bundleID: "com.anthropic.claudefordesktop", name: "Claude", regular: true),
            RunningAppInfo(pid: 600, bundleID: "com.dwarvesv.minimalbar", name: "Hidden Bar", regular: false),
            RunningAppInfo(pid: 700, bundleID: "com.apple.mail", name: "Mail", regular: true),
            RunningAppInfo(pid: 800, bundleID: "com.apple.Notes", name: "Notes", regular: true),
            RunningAppInfo(pid: 900, bundleID: "com.apple.Preview", name: "Preview", regular: true),
        ]
    }

    func plan(responsible: [Int32: [Int32]] = [:]) -> [String: [Int32]] {
        let targets = FreezePlanner.plan(apps: apps, table: table, uid: uid, me: me, responsible: responsible)
        return Dictionary(uniqueKeysWithValues: targets.map { ($0.bundleID, $0.processes.map(\.pid).sorted()) })
    }

    func testFreezesRegularAppsWithTheirChildren() {
        let result = plan()
        XCTAssertEqual(result["com.apple.Safari"], [100, 102])
        XCTAssertEqual(result["com.apple.Music"], [200])
        // A root process inside the app's tree isn't the user's: not touched
        XCTAssertEqual(result["com.apple.mail"], [700])
        // A similar name isn't an agent
        XCTAssertEqual(result["com.apple.Preview"], [900, 901])
    }

    func testKeepsAOSClaudeTerminalsAgentsAndMenuBarApps() {
        let result = plan()
        XCTAssertNil(result["dev.marquart.aos"])
        XCTAssertNil(result["com.anthropic.claudefordesktop"])
        XCTAssertNil(result["com.apple.Terminal"], "terminals stay awake")
        XCTAssertNil(result["com.example.Editor"], "an agent (aos-mcp) runs inside")
        XCTAssertNil(result["com.dwarvesv.minimalbar"], "only apps with a Dock icon freeze")
        XCTAssertNil(result["com.apple.Notes"], "already stopped by someone else")
    }

    func testClaudeInsideAnyAppKeepsItAwake() {
        var t = table
        t[202] = p(202, 200, "claude")
        let targets = FreezePlanner.plan(apps: apps, table: t, uid: uid, me: me)
        XCTAssertFalse(targets.contains { $0.bundleID == "com.apple.Music" })
    }

    func testResponsibleProcessesBelongToTheirApp() {
        XCTAssertEqual(plan(responsible: [100: [101]])["com.apple.Safari"], [100, 101, 102])
    }

    func testPatterns() {
        XCTAssertTrue(FreezePlanner.matches("com.jetbrains.intellij", ["com.jetbrains.*"]))
        XCTAssertTrue(FreezePlanner.matches("dev.marquart.aos.guest-helper", FreezePlanner.builtinExclude))
        XCTAssertFalse(FreezePlanner.matches("com.apple.Safari", FreezePlanner.builtinExclude))
        XCTAssertFalse(FreezePlanner.matches("com.jetbrain", ["com.jetbrains.*"]))
    }

    func testDescendants() {
        let parent: [Int32: Int32] = [2: 1, 3: 2, 4: 2, 5: 9, 6: 6]
        XCTAssertEqual(FreezePlanner.descendants(of: [1], parent: parent), [2, 3, 4])
        XCTAssertEqual(FreezePlanner.descendants(of: [6], parent: parent), [])
    }
}

final class FreezerTests: XCTestCase {
    func entry(_ pid: Int32, _ start: Int) -> FrozenProcess {
        FrozenProcess(ProcessEntry(pid: pid, ppid: 1, uid: 501, startSec: start, startUsec: 0, name: "x"), app: "X")
    }

    func testRemainingAfterThaw() {
        let list = [entry(10, 100), entry(11, 110), entry(12, 120), entry(13, 130)]
        let table: [Int32: ProcessEntry] = [
            10: ProcessEntry(pid: 10, ppid: 1, uid: 501, startSec: 100, name: "x"),
            11: ProcessEntry(pid: 11, ppid: 1, uid: 501, startSec: 999, name: "reused"),
            12: ProcessEntry(pid: 12, ppid: 1, uid: 501, startSec: 120, name: "x"),
        ]
        var signalled: [Int32] = []
        let remaining = FrozenRecord.remainingAfterThaw(list, table: table) { pid in
            signalled.append(pid)
            return pid != 12
        }
        // 11 is another process now and 13 is gone: neither is signalled, both leave the record.
        XCTAssertEqual(signalled, [10, 12])
        XCTAssertEqual(remaining.map(\.pid), [12])
        XCTAssertEqual(FrozenRecord.remainingAfterThaw(list, table: nil) { _ in true }.count, 4)
    }

    func testRecordRoundTripAndRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("frozen.json")
        let record = FrozenRecord(owner: ProcessIdentity(pid: 1, startSec: 2, startUsec: 3), processes: [entry(10, 100)])
        XCTAssertTrue(record.write(url))
        XCTAssertEqual(FrozenRecord.read(url), record)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(FrozenRecord(owner: nil, processes: []).write(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOrphansOfALivingOwnerStay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("frozen.json")
        // Owned by this test process: it is alive, so aos-session leaves the record alone.
        XCTAssertTrue(FrozenRecord(owner: ProcessIdentity.current, processes: [entry(999_999, 1)]).write(url))
        XCTAssertNil(Freezer.thawOrphans(recordURL: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Owner gone: the record is worked off (the pid doesn't exist, nothing is signalled) and removed.
        XCTAssertTrue(FrozenRecord(owner: ProcessIdentity(pid: 999_998, startSec: 1, startUsec: 1),
                                   processes: [entry(999_999, 1)]).write(url))
        XCTAssertEqual(Freezer.thawOrphans(recordURL: url), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The real thing on a child of this test: stopped, recorded, continued.
    func testFreezesAndThawsAChildProcess() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, environ), 0)
        defer {
            kill(pid, SIGCONT)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let freezer = Freezer(recordURL: dir.appendingPathComponent("frozen.json"))
        let child = try XCTUnwrap(ProcessTable.snapshot()?[pid])
        XCTAssertFalse(child.stopped)
        XCTAssertEqual(freezer.freeze([FreezeTarget(app: "sleep", bundleID: "test.sleep", processes: [child])]), 1)
        XCTAssertEqual(ProcessTable.snapshot()?[pid]?.stopped, true)
        XCTAssertEqual(FrozenRecord.read(freezer.recordURL)?.processes.map(\.pid), [pid])
        XCTAssertEqual(FrozenRecord.read(freezer.recordURL)?.owner, ProcessIdentity.current)
        // Frozen again: nothing new
        XCTAssertEqual(freezer.freeze([FreezeTarget(app: "sleep", bundleID: "test.sleep", processes: [child])]), 0)
        XCTAssertEqual(freezer.thawAll(reason: "test"), 1)
        XCTAssertEqual(ProcessTable.snapshot()?[pid]?.stopped, false)
        XCTAssertNil(FrozenRecord.read(freezer.recordURL))
    }
}

final class NetworkCarePolicyTests: XCTestCase {
    func memory(offlineFor: Double?, now: Double = 10_000, lastScan: Double = 0) -> NetworkMemory {
        var m = NetworkMemory()
        m.offlineSince = offlineFor.map { now - $0 }
        m.lastScanAt = lastScan
        return m
    }

    func next(_ m: NetworkMemory, now: Double = 10_000, wifiOn: Bool = true, ip: Bool = false) -> NetworkStep {
        NetworkCarePolicy.next(now: now, wifiOn: wifiOn, hasIPv4: ip, memory: m)
    }

    func testNothingWhileOnlineOrWiFiOffOrShortGap() {
        XCTAssertEqual(next(memory(offlineFor: 300), ip: true), .none)
        XCTAssertEqual(next(memory(offlineFor: 300), wifiOn: false), .none)
        XCTAssertEqual(next(memory(offlineFor: nil)), .none)
        XCTAssertEqual(next(memory(offlineFor: 10)), .none)
    }

    func testScansEvery45Seconds() {
        XCTAssertEqual(next(memory(offlineFor: 25)), .scan)
        XCTAssertEqual(next(memory(offlineFor: 60, lastScan: 10_000 - 20)), .none)
        XCTAssertEqual(next(memory(offlineFor: 60, lastScan: 10_000 - 46)), .scan)
    }

    func testRestartsAirportdWhenVisibleNetworksFail() {
        var m = memory(offlineFor: 120, lastScan: 10_000 - 10)
        m.visibleFailures = 2
        XCTAssertEqual(next(m), .restartAirportd)
        m.lastAirportdAt = 10_000 - 30
        XCTAssertEqual(next(m), .none, "settling after a restart")
        m.lastAirportdAt = 10_000 - 300
        XCTAssertEqual(next(m), .none, "at most every 10 minutes")
    }

    func testCyclesWiFiWithGrowingPauses() {
        var m = memory(offlineFor: 300, lastScan: 10_000 - 10)
        XCTAssertEqual(next(m), .cycleWiFi)
        m.lastCycleAt = 10_000 - 120
        m.cyclesInOutage = 1
        XCTAssertEqual(next(m), .none)
        m.lastCycleAt = 10_000 - 601
        XCTAssertEqual(next(m), .cycleWiFi)
        XCTAssertEqual(NetworkCarePolicy.cycleInterval(afterCycles: 0), 600)
        XCTAssertEqual(NetworkCarePolicy.cycleInterval(afterCycles: 2), 1200)
        XCTAssertEqual(NetworkCarePolicy.cycleInterval(afterCycles: 9), 3600)
    }

    func testNoCycleBeforeAnyScan() {
        XCTAssertEqual(next(memory(offlineFor: 400, lastScan: 0)), .scan)
    }

    func testKnownWiFiBeatsTheHotspot() {
        let preferred = ["iPhone von Max", "eduroam", "Home"]
        let hotspots = ["iPhone von Max"]
        let m = NetworkMemory()
        XCTAssertEqual(NetworkCarePolicy.joinTarget(visible: ["iphone von max", "Home"], preferred: preferred,
                                                    hotspots: hotspots, memory: m, now: 0), "Home")
        XCTAssertEqual(NetworkCarePolicy.joinTarget(visible: ["iPhone von Max"], preferred: preferred,
                                                    hotspots: hotspots, memory: m, now: 0), "iPhone von Max")
        XCTAssertNil(NetworkCarePolicy.joinTarget(visible: [], preferred: preferred, hotspots: hotspots, memory: m, now: 0))
    }

    func testFailedNetworksRest() {
        var m = NetworkMemory()
        m.noteJoin("Home", ok: false, visible: true, now: 100)
        XCTAssertEqual(m.visibleFailures, 1)
        XCTAssertTrue(NetworkCarePolicy.resting("home", memory: m, now: 120))
        XCTAssertFalse(NetworkCarePolicy.resting("home", memory: m, now: 146))
        m.noteJoin("Home", ok: false, visible: true, now: 200)
        XCTAssertTrue(NetworkCarePolicy.resting("Home", memory: m, now: 300))
        XCTAssertEqual(NetworkCarePolicy.joinTarget(visible: ["Home", "iPhone"], preferred: ["Home", "iPhone"],
                                                    hotspots: ["iPhone"], memory: m, now: 300), "iPhone")
        m.noteJoin("Home", ok: true, visible: true, now: 400)
        XCTAssertFalse(NetworkCarePolicy.resting("Home", memory: m, now: 401))
        m.noteOnline()
        XCTAssertNil(m.offlineSince)
        XCTAssertEqual(m.visibleFailures, 0)
    }

    func testWakeRestartsTheCount() {
        var m = NetworkMemory()
        m.noteOffline(now: 100)
        m.noteOffline(now: 200)
        XCTAssertEqual(m.offlineSince, 100)
        m.lastScanAt = 150
        m.noteWake(now: 5000)
        XCTAssertEqual(m.offlineSince, 5000)
        XCTAssertEqual(m.lastScanAt, 0)
    }

    func testCandidatesAndHotspotNames() {
        let preferred = ["Home", "iPhone von Max", "eduroam", "Noahs iPhone", "Cafe"]
        XCTAssertEqual(NetworkCarePolicy.hotspotNames(preferred: preferred, fromHelper: nil), ["iPhone von Max", "Noahs iPhone"])
        // The helper knows which ones are the user's own (macOS marks them Personal Hotspot)
        XCTAssertEqual(NetworkCarePolicy.hotspotNames(preferred: preferred, fromHelper: ["Max iPad", "iPhone von Max"]),
                       ["iPhone von Max", "Max iPad"])
        XCTAssertEqual(NetworkCarePolicy.scanCandidates(preferred: preferred, hotspots: ["iPhone von Max"], limit: 3),
                       ["iPhone von Max", "Home", "eduroam"])
    }

    func testParsesNetworksetupAndAddresses() {
        let out = "Preferred networks on en0:\n\tiPhone von Max\n\teduroam\n\t Leading Space\n"
        XCTAssertEqual(NetworkCarePolicy.parsePreferred(out), ["iPhone von Max", "eduroam", " Leading Space"])
        XCTAssertTrue(NetworkCarePolicy.usableIPv4("192.168.1.4"))
        XCTAssertFalse(NetworkCarePolicy.usableIPv4("169.254.3.9"))
        XCTAssertFalse(NetworkCarePolicy.usableIPv4(""))
        XCTAssertTrue(NetworkCarePolicy.isHotspotAddress("172.20.10.13"))
        XCTAssertFalse(NetworkCarePolicy.isHotspotAddress("172.20.10.15"))
        XCTAssertFalse(NetworkCarePolicy.isHotspotAddress("172.20.100.2"))
        // Online through another interface: Ethernet yes; Wi-Fi itself, VPN tunnels, bridges no
        XCTAssertTrue(NetworkCarePolicy.countsAsOtherNetwork("en7", wifi: "en0"))
        XCTAssertFalse(NetworkCarePolicy.countsAsOtherNetwork("en0", wifi: "en0"))
        XCTAssertFalse(NetworkCarePolicy.countsAsOtherNetwork("utun4", wifi: "en0"))
        XCTAssertFalse(NetworkCarePolicy.countsAsOtherNetwork("bridge100", wifi: "en0"))
        XCTAssertFalse(NetworkCarePolicy.countsAsOtherNetwork("", wifi: "en0"))
        XCTAssertTrue(NetworkCarePolicy.validNetworkName("iPhone von Max"))
        XCTAssertFalse(NetworkCarePolicy.validNetworkName(""))
        XCTAssertFalse(NetworkCarePolicy.validNetworkName(String(repeating: "x", count: 33)))
        XCTAssertFalse(NetworkCarePolicy.validNetworkName("a\nb"))
    }
}

final class WiFiPreferencesTests: XCTestCase {
    func testHotspotModeNamesMatchCoreWLAN() {
        // schemaStringForAutoHotspotMode on macOS 27: 1 AskToJoin, 2 Automatic, 3 Never
        XCTAssertEqual(WiFiPreferences.HotspotMode(rawValue: 3)?.schemaString, "Never")
        XCTAssertEqual(WiFiPreferences.HotspotMode(rawValue: 2)?.schemaString, "Automatic")
        XCTAssertEqual(WiFiPreferences.HotspotMode(rawValue: 1)?.schemaString, "AskToJoin")
        XCTAssertEqual(WiFiPreferences.HotspotMode(schemaString: "Never"), .never)
        XCTAssertNil(WiFiPreferences.HotspotMode(schemaString: "never"))
        XCTAssertEqual(WiFiPreferences.hotspotMode(for: .manual), .never)
        XCTAssertEqual(WiFiPreferences.hotspotMode(for: .automatic), .automatic)
        XCTAssertTrue(WiFiPreferences.autoJoinDisabled(for: .manual))
        XCTAssertFalse(WiFiPreferences.autoJoinDisabled(for: .automatic))
    }

    var store: [String: Any] {
        [
            "wifi.network.ssid.iPhone von Max": ["PersonalHotspot": true, "AutoJoinDisabled": false,
                                                 "SSID": Data("iPhone von Max".utf8)],
            "wifi.network.ssid.Max iPad": ["__OSSpecific__": ["PersonalHotspot": true, "AutoJoinDisabled": false]],
            "wifi.network.ssid.Home": ["AutoJoinDisabled": false, "SSID": Data("Home".utf8)],
            "wifi.network.ssid.Old iPhone": ["PersonalHotspot": NSNumber(value: true), "AutoJoinDisabled": NSNumber(value: true)],
            "unrelated": "value",
        ]
    }

    func testFindsTheUsersHotspots() {
        let hotspots = WiFiPreferences.personalHotspots(in: store)
        XCTAssertEqual(hotspots.map(\.name), ["Max iPad", "Old iPhone", "iPhone von Max"])
        XCTAssertEqual(hotspots.map(\.autoJoinDisabled), [false, true, false])
    }

    func testSwitchesAutoJoinOnlyWhereNeeded() throws {
        let off = WiFiPreferences.settingAutoJoin(in: store, disabled: true)
        XCTAssertEqual(Set(off.keys), ["wifi.network.ssid.iPhone von Max", "wifi.network.ssid.Max iPad"])
        XCTAssertEqual(off["wifi.network.ssid.iPhone von Max"]?["AutoJoinDisabled"] as? Bool, true)
        // Everything else in the entry stays
        XCTAssertEqual(off["wifi.network.ssid.iPhone von Max"]?["SSID"] as? Data, Data("iPhone von Max".utf8))
        let ipad = try XCTUnwrap(off["wifi.network.ssid.Max iPad"])
        XCTAssertEqual(ipad["AutoJoinDisabled"] as? Bool, true)
        XCTAssertEqual((ipad["__OSSpecific__"] as? [String: Any])?["AutoJoinDisabled"] as? Bool, true)
        let on = WiFiPreferences.settingAutoJoin(in: store, disabled: false)
        XCTAssertEqual(Set(on.keys), ["wifi.network.ssid.Old iPhone", "wifi.network.ssid.Max iPad"])
    }

    func testStateMatchesTheChoice() {
        let manual = WiFiState(hotspotMode: .never, personalHotspots: 4, autoJoinOff: 4)
        XCTAssertTrue(manual.matches(.manual))
        XCTAssertFalse(manual.matches(.automatic))
        let today = WiFiState(hotspotMode: .never, personalHotspots: 4, autoJoinOff: 0)
        XCTAssertFalse(today.matches(.manual))
        XCTAssertTrue(today.autoJoinMatches(.automatic))
        XCTAssertFalse(today.hotspotMatches(.automatic))
        XCTAssertTrue(WiFiState(hotspotMode: .automatic, personalHotspots: 0, autoJoinOff: 0).matches(.automatic))
        XCTAssertFalse(WiFiState(hotspotMode: .automatic).matches(.automatic), "unknown counts as not done")
    }
}
