import CoreGraphics
import Foundation
import IOKit.ps

// The iPhone's view of the Mac and aOS (Docs/COMPANION.md, "The Mac from the iPhone"): one signed op to read
// (battery, lid, staying awake, workspace, Claude Code, Bitwarden) and one signed op per action. They come through
// CompanionGate like every phone request (signature, time window, nonce); a parameter travels in `text`, which the
// signature covers (`data`).

/// What the app does for these ops (power and settings live there).
@MainActor
public protocol MacControls: AnyObject {
    /// Staying awake, as the app decides it right now.
    func awakeStatus() -> MacAwakeStatus
    /// Puts the Mac to sleep, or says why not (aOS's own hold with the lid closed is released first).
    func sleepMac() async -> MacSleepResult
    /// Settings > General > Staying awake.
    func setStayAwake(_ mode: StayAwake) -> MacControlRefusal?
    /// The battery level down to which the Mac stays awake with the lid closed (0: no limit).
    func setBatteryLimit(_ percent: Int) -> MacControlRefusal?
    /// Turns the display off or wakes it (`MacDisplayStatus.set(on:)` unless the app does it itself).
    func setDisplay(on: Bool) async
    /// Changes the session's routines in the settings.
    func updateRoutines(_ change: (inout [Routine]) -> Void)
    /// Pins, unpins, skips or allows a Claude Code conversation (the app owns the settings; the keeper follows them).
    func changeConversation(_ id: String, _ change: ConversationChange) -> MacControlRefusal?
}

extension MacControls {
    public func setDisplay(on: Bool) async { await MacDisplayStatus.set(on: on) }
}

public struct MacAwakeStatus: Codable, Equatable, Sendable {
    public var setting: StayAwake
    /// aOS's helper holds the Mac awake for a closed lid now (pmset disablesleep, renewed).
    public var holding: Bool
    /// The lid is closed and aOS keeps the Mac awake (other apps frozen, display off).
    public var lidClosedMode: Bool
    /// Why the setting isn't fully in effect (`AwakeBlocker`).
    public var blocker: String?
    /// The background helper as macOS sees it: enabled, requiresApproval, notRegistered, notFound.
    public var helper: String
    /// Another service keeps the Mac awake and owns sleep (aOS leaves it alone).
    public var otherService: Bool
    /// On battery with the lid closed: awake down to this level (0: no limit), and the levels to choose from.
    public var batteryLimit: Int?
    public var batteryLimits: [Int]?

    public init(setting: StayAwake, holding: Bool, lidClosedMode: Bool, blocker: String?, helper: String,
                otherService: Bool, batteryLimit: Int? = nil, batteryLimits: [Int]? = nil) {
        self.setting = setting
        self.holding = holding
        self.lidClosedMode = lidClosedMode
        self.blocker = blocker
        self.helper = helper
        self.otherService = otherService
        self.batteryLimit = batteryLimit
        self.batteryLimits = batteryLimits
    }
}

/// Why the Mac refused an action from the phone: `code` for the phone (it says it in its language), `message` in
/// English as a fallback.
public struct MacControlRefusal: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let otherService = MacControlRefusal("other-service", "Another service takes care of sleep on this Mac; \(Brand.name) leaves it alone.")
    public static let sleepDisabled = MacControlRefusal("sleep-disabled", "Sleep is switched off on this Mac by another program (pmset disablesleep). \(Brand.name) doesn't change that.")
    public static let holdNotReleased = MacControlRefusal("sleep-held", "\(Brand.name)'s helper didn't let go of the Mac in time. Try again in a moment.")
    public static let notSetUp = MacControlRefusal("not-set-up", "The workspace isn't set up yet. Finish the setup in \(Brand.name) on the Mac.")
    public static let noSession = MacControlRefusal("no-session", "\(Brand.name)'s background process isn't running, so there is no Claude Code session to restart.")
    public static let noKeeper = MacControlRefusal("no-keeper", "\(Brand.name)'s background process doesn't keep conversations reachable right now.")
    public static let keeperTooOld = MacControlRefusal("keeper-old", "\(Brand.name)'s background process on the Mac is from an older version and can't restart a single conversation. It can after the Mac restarts.")
    public static let chatRunning = MacControlRefusal("chat-running", "This conversation runs or is open somewhere. Stop it first, or close it in the Claude app.")
    public static let chatNotFound = MacControlRefusal("not-found", "\(Brand.name) doesn't find this conversation on the Mac.")
    public static let notKept = MacControlRefusal("not-kept", "\(Brand.name) doesn't run this conversation right now, so there is nothing to restart.")
}

public enum MacSleepResult: Equatable, Sendable {
    /// The Mac goes to sleep in this many seconds (the answer reaches the phone first).
    case sleeping(after: Double)
    case refused(MacControlRefusal)
}

/// Whether the Mac can be put to sleep, read from the facts (pure, tested).
public enum SleepPolicy {
    public enum Step: Equatable, Sendable {
        case sleep
        /// aOS's own hold first (it set disablesleep; releasing it gives sleep back).
        case releaseHold
        case refuse(MacControlRefusal)
    }

    /// `aosHolds`: aOS's helper holds the Mac now. `sleepDisabled`: pmset's SleepDisabled (nil: unreadable).
    /// `otherService`: Cloupi's wake daemon is on this Mac.
    public static func next(aosHolds: Bool, sleepDisabled: Int?, otherService: Bool) -> Step {
        if aosHolds { return .releaseHold }
        if sleepDisabled == 1 { return .refuse(otherService ? .otherService : .sleepDisabled) }
        return .sleep
    }
}

/// Battery and power source, as the phone shows them.
public struct MacPowerStatus: Codable, Equatable, Sendable {
    /// ac, battery, ups, or unknown.
    public var source: String
    public var battery: Int?
    public var charging: Bool?
    /// Minutes until empty (on battery) or full (charging), when macOS knows.
    public var minutes: Int?
    /// open, closed, or none (no lid).
    public var lid: String
    /// nominal, fair, serious, critical.
    public var thermal: String

    public static func read() -> MacPowerStatus {
        var status = MacPowerStatus(source: "unknown", battery: nil, charging: nil, minutes: nil,
                                    lid: MacState.lidClosed().map { $0 ? "closed" : "open" } ?? "none",
                                    thermal: Self.thermalName(ProcessInfo.processInfo.thermalState))
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return status }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        switch providing {
        case kIOPSACPowerValue: status.source = "ac"
        case kIOPSBatteryPowerValue: status.source = "battery"
        case "UPS Power": status.source = "ups"
        default: break
        }
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return status }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let current = d[kIOPSCurrentCapacityKey] as? Int {
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                status.battery = max > 0 ? Int((Double(current) * 100 / Double(max)).rounded()) : current
            }
            status.charging = d[kIOPSIsChargingKey] as? Bool
            let key = status.charging == true ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = d[key] as? Int, minutes > 0 { status.minutes = minutes }
        }
        return status
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }
}

/// Whether a screen of the Mac is lit, as the phone shows it.
public struct MacDisplayStatus: Codable, Equatable, Sendable {
    /// on: at least one screen is lit; off: all are asleep; none: no screen is online (the lid is closed and no monitor
    /// is connected).
    public var state: String
    /// Screens other than the built-in one (screen sharing's virtual one doesn't count).
    public var external: Int

    public init(state: String, external: Int) {
        self.state = state
        self.external = external
    }

    /// What `CGDisplayIsAsleep` says about every online screen.
    public static func read() -> MacDisplayStatus {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var online: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &online) == .success else { return MacDisplayStatus(state: "off", external: 0) }
        var lit = 0, external = 0, counted = 0
        for id in ids.prefix(Int(online)) {
            // Screen sharing's virtual display ("High Performance" mode) is no screen of the Mac.
            if MacState.isSharingDisplay(id) { continue }
            counted += 1
            if CGDisplayIsBuiltin(id) == 0 { external += 1 }
            if CGDisplayIsAsleep(id) == 0 { lit += 1 }
        }
        return MacDisplayStatus(state: lit > 0 ? "on" : (counted == 0 ? "none" : "off"), external: external)
    }

    /// Off: `pmset displaysleepnow`. On: `caffeinate -u` declares user activity, which wakes a sleeping display
    /// (a closed lid keeps the built-in one dark). Waits a moment, so the status read afterwards shows the change.
    public static func set(on: Bool) async {
        if on {
            _ = try? await Subprocess.run("/usr/bin/caffeinate", ["-u", "-t", "2"], timeout: 10)
        } else {
            _ = try? await Subprocess.run("/usr/bin/pmset", ["displaysleepnow"], timeout: 10)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

public enum CompanionControl {
    /// The ops (as the app gets them from aos-companion: "companion." and the phone's op).
    public static let status = "companion.mac.status"
    public static let sleep = "companion.mac.sleep"
    public static let displayOff = "companion.mac.display-off"
    public static let displayOn = "companion.mac.display-on"
    public static let stayAwake = "companion.mac.stay-awake"
    public static let batteryLimit = "companion.mac.battery-limit"
    public static let workspaceStart = "companion.workspace.start"
    public static let workspaceStop = "companion.workspace.stop"
    public static let bitwardenLock = "companion.bitwarden.lock"
    public static let sessionRestart = "companion.session.restart"
    /// The session's routines: add or change one (JSON in `text`), delete one, send one now (its id in `text`).
    public static let routineSet = "companion.routines.set"
    public static let routineDelete = "companion.routines.delete"
    public static let routineRun = "companion.routines.run"

    /// A routine from the phone, checked: a name, a message, a valid schedule, sensible lengths.
    public static func routine(fromPhone text: String?) -> Routine? {
        guard let data = text?.data(using: .utf8), var r = try? JSONDecoder().decode(Routine.self, from: data) else { return nil }
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.prompt = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.name.isEmpty, r.name.count <= 80, !r.prompt.isEmpty, r.prompt.count <= 8000,
              let cron = CronSet(r.schedule), cron.schedules.count <= 24, UUID(uuidString: r.id) != nil else { return nil }
        r.schedule = cron.text
        return r
    }

    /// The chats (CompanionChats.swift): the list, and pin, unpin, skip, unskip, restart one (its id in `text`).
    public static let chatsList = "companion.chats.list"
    public static let chatsPin = "companion.chats.pin"
    public static let chatsUnpin = "companion.chats.unpin"
    public static let chatsSkip = "companion.chats.skip"
    public static let chatsUnskip = "companion.chats.unskip"
    public static let chatsRestart = "companion.chats.restart"
    /// Start it now (pins it, the keeper starts it), stop it (never keep it), delete it (its transcript to the Trash).
    public static let chatsStart = "companion.chats.start"
    public static let chatsStop = "companion.chats.stop"
    public static let chatsDelete = "companion.chats.delete"
    public static let chatOps: Set<String> = [chatsList, chatsPin, chatsUnpin, chatsSkip, chatsUnskip, chatsRestart,
                                              chatsStart, chatsStop, chatsDelete]

    public static let ops: Set<String> = Set([status, sleep, displayOff, displayOn, stayAwake, batteryLimit, workspaceStart,
                                              workspaceStop, bitwardenLock, sessionRestart, routineSet, routineDelete,
                                              routineRun]).union(chatOps)

    /// What this Mac offers the phone beyond the first version (`hello` lists it): these ops and the terminal
    /// sessions (`aos-companion term`).
    public static let features = ops.map { String($0.dropFirst("companion.".count)) }.sorted() + ["term"]

    /// The name the phone sees for the workspace's state.
    static func workspaceState(_ phase: VMHost.Phase, leased: Bool) -> String {
        switch phase {
        case .running: return leased ? "open" : "running"
        case .starting, .installing: return "starting"
        case .stopping, .suspending, .pausing: return "closing"
        case .stopped, .paused: return "stopped"
        case .error: return "failed"
        }
    }

    static func bitwardenState(_ phase: BitwardenVault.Phase) -> String {
        switch phase {
        case .unlocked: return "unlocked"
        case .locked, .unlocking: return "locked"
        case .signedOut, .noTool, .installing, .signingIn: return "signedOut"
        case .needsHelper: return "needsHelper"
        case .unknown: return "unknown"
        }
    }
}

extension CompanionControl {
    /// Installing apps on the iPhone, as the phone shows it (nil while the feature is off): the tunnel's state, since
    /// when it holds and on which network, and the latest installs.
    static func apps(settings: AgentSettings, status: DeviceStatus?, iso: ISO8601DateFormatter,
                     alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> [String: Any]? {
        guard settings.iphoneApps else { return nil }
        guard let status, status.isFresh(alive: alive) else { return ["state": "stopped", "jobs": [Any]()] }
        var apps: [String: Any] = ["state": status.state.rawValue]
        if let since = status.since, status.isConnected { apps["since"] = iso.string(from: since) }
        if let network = status.network, status.isConnected { apps["network"] = network }
        if let name = status.device?.name { apps["device"] = name }
        if let last = status.history.last { apps["previousSeconds"] = last.seconds }
        apps["jobs"] = status.jobs.prefix(10).map { job -> [String: Any] in
            var o: [String: Any] = ["id": job.id, "name": job.name, "bundleId": job.bundleId, "state": job.state.rawValue,
                                    "created": iso.string(from: job.created)]
            if let v = job.version { o["version"] = v }
            if let v = job.source { o["source"] = v }
            if let v = job.finished { o["finished"] = iso.string(from: v) }
            if let v = job.seconds { o["seconds"] = v }
            if let v = job.network { o["network"] = v }
            if let v = job.message, job.state == .failed { o["message"] = v }
            return o
        }
        return apps
    }
}

extension WorkspaceController {
    /// The Mac and aOS as the phone shows them.
    func macStatus() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var result: [String: Any] = [:]
        if let power = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(MacPowerStatus.read())) {
            result["power"] = power
        }
        if let display = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(MacDisplayStatus.read())) {
            result["display"] = display
        }
        if let awake = macControls?.awakeStatus(), let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(awake)) {
            result["awake"] = object
        }
        var workspace: [String: Any] = ["state": CompanionControl.workspaceState(host.phase, leased: lease != nil),
                                        "setupComplete": setupComplete]
        if let lease {
            workspace["purpose"] = lease.purpose
            workspace["until"] = iso.string(from: lease.until)
        }
        if let error = host.lastError, host.phase == .error { workspace["error"] = error }
        result["workspace"] = workspace
        var session: [String: Any] = ["enabled": settings.sessionEnabled]
        if let s = SessionSupervisor.readStatus(paths: paths) {
            session["state"] = s.state.rawValue
            session["since"] = iso.string(from: s.since)
            if !s.detail.isEmpty { session["detail"] = s.detail }
        }
        result["session"] = session
        var chats: [String: Any] = ["enabled": settings.newChats]
        if let r = RemoteServerStatus.read(paths) {
            chats["state"] = r.state.rawValue
            if !r.detail.isEmpty { chats["detail"] = r.detail }
        }
        result["newChats"] = chats
        if let k = KeeperStatus.read(paths) {
            result["kept"] = ["enabled": k.enabled && settings.keepReachable,
                              "running": k.entries.filter { $0.state == .running }.count]
        }
        // The session's routines (with their messages, the phone edits them), reminders waiting, what went in lately
        let routinesStatus = RoutinesStatus.read(paths)
        let now = Date()
        var routines: [String: Any] = [
            "items": settings.routines.map { r -> [String: Any] in
                var item: [String: Any] = ["id": r.id, "name": r.name, "schedule": r.schedule, "prompt": r.prompt,
                                           "enabled": r.enabled]
                if r.enabled, let next = r.cron?.next(after: now) { item["next"] = iso.string(from: next) }
                return item
            },
            "queued": routinesStatus?.queued ?? 0,
        ]
        if let rs = routinesStatus {
            routines["reminders"] = rs.reminders.prefix(10).map { ["name": $0.name, "at": iso.string(from: $0.at)] }
            routines["recent"] = rs.recent.prefix(5).map { ["kind": $0.kind.rawValue, "name": $0.name, "at": iso.string(from: $0.at)] }
        }
        result["routines"] = routines
        if let apps = CompanionControl.apps(settings: settings, status: DeviceStatus.load(paths), iso: iso) {
            result["apps"] = apps
        }
        var vault: [String: Any] = ["state": CompanionControl.bitwardenState(bitwarden.phase)]
        if bitwarden.phase == .unlocked, let until = bitwarden.lockedAt, until != .distantFuture {
            vault["until"] = iso.string(from: until)
        }
        result["bitwarden"] = vault
        return result
    }

    /// The phone's signed ops for the Overview (after CompanionGate admitted them).
    func handleControl(_ r: AgentRequest) async -> AgentResponse {
        func refused(_ refusal: MacControlRefusal) -> AgentResponse {
            AgentResponse(id: r.id, ok: false, text: refusal.message, code: refusal.code)
        }
        func done(_ extra: [String: Any] = [:]) -> AgentResponse {
            var object = extra
            object["status"] = macStatus()
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return AgentResponse(id: r.id, ok: true, text: String(decoding: data, as: UTF8.self))
        }
        companion.seen(device: r.device)
        let from = r.device ?? "the iPhone"
        switch r.op {
        case CompanionControl.status:
            return done()

        case _ where CompanionControl.chatOps.contains(r.op):
            return await handleChats(r, from: from)

        case CompanionControl.sleep:
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            log("\(from) asks the Mac to sleep")
            switch await controls.sleepMac() {
            case .sleeping(let after): return done(["sleeping": true, "after": after])
            case .refused(let refusal):
                log("sleep from \(from) refused: \(refusal.code)")
                return refused(refusal)
            }

        case CompanionControl.displayOff, CompanionControl.displayOn:
            let on = r.op == CompanionControl.displayOn
            log("\(from) turns the display \(on ? "on" : "off")")
            // The status that goes back already shows the change.
            if let controls = macControls { await controls.setDisplay(on: on) } else { await MacDisplayStatus.set(on: on) }
            return done()

        case CompanionControl.stayAwake:
            guard let mode = StayAwake(rawValue: r.text ?? "") else { return .failure(r.id, "Not a choice: \(r.text ?? "")") }
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            if let refusal = controls.setStayAwake(mode) { return refused(refusal) }
            log("\(from) set staying awake to \(mode.rawValue)")
            return done()

        case CompanionControl.batteryLimit:
            guard let percent = Int(r.text ?? ""), AgentSettings.stayAwakeMinBatteryChoices.contains(percent) else {
                return .failure(r.id, "Not a choice: \(r.text ?? "")")
            }
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            if let refusal = controls.setBatteryLimit(percent) { return refused(refusal) }
            log("\(from) set the battery limit for staying awake to \(percent == 0 ? "none" : "\(percent) %")")
            return done()

        case CompanionControl.workspaceStart:
            guard setupComplete else { return refused(.notSetUp) }
            if !host.isRunning, host.phase != .starting {
                log("\(from) starts the workspace")
                Task { @MainActor [weak self] in
                    do {
                        _ = try await self?.bootAndPrepare(reason: "opened from \(from)")
                    } catch {
                        self?.log("starting the workspace from \(from) failed: \(error.localizedDescription)")
                    }
                }
            }
            return done()

        case CompanionControl.workspaceStop:
            if host.isRunning || host.phase == .starting {
                log("\(from) closes the workspace\(lease.map { " (it was open for \"\($0.purpose)\")" } ?? "")")
                Task { @MainActor [weak self] in _ = await self?.close() }
            }
            return done()

        case CompanionControl.bitwardenLock:
            log("\(from) locks Bitwarden")
            await bitwarden.lock(reason: "locked from \(from)")
            return done()

        case CompanionControl.routineSet:
            guard let routine = CompanionControl.routine(fromPhone: r.text) else {
                return .failure(r.id, "Not a routine: it needs a name, a message and a valid schedule.")
            }
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            controls.updateRoutines { list in
                if let i = list.firstIndex(where: { $0.id == routine.id }) { list[i] = routine } else { list.append(routine) }
            }
            log("\(from) saved the routine \"\(routine.name)\"")
            return done()

        case CompanionControl.routineDelete:
            guard let id = r.text, !id.isEmpty else { return .failure(r.id, "Which routine?") }
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            controls.updateRoutines { $0.removeAll { $0.id == id } }
            log("\(from) deleted a routine")
            return done()

        case CompanionControl.routineRun:
            guard let id = r.text, let routine = settings.routines.first(where: { $0.id == id }) else {
                return .failure(r.id, "This routine doesn't exist (any more).")
            }
            guard SessionCommand.run(routine: id).send(paths: paths) else { return refused(.noSession) }
            log("\(from) runs the routine \"\(routine.name)\" now")
            return done()

        case CompanionControl.sessionRestart:
            let socket = paths.run.appendingPathComponent("session.sock")
            guard let client = try? RawSocket(path: socket) else { return refused(.noSession) }
            client.send(Data("\u{1B}]aos;restart\u{07}".utf8))
            client.close()
            log("\(from) restarts the Claude Code session")
            return done()

        default:
            return .failure(r.id, "unknown companion operation \(r.op)")
        }
    }
}
