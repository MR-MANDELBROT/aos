import AOSKit
import Foundation
import SystemConfiguration

// aos-powerd: aOS's privileged helper. A root LaunchDaemon from the app bundle (Contents/Library/LaunchDaemons/
// dev.marquart.aos.powerd.plist, registered by the app with SMAppService.daemon; macOS asks the user to allow it in
// Login Items). It does only what needs root, and only for aOS (code signature, see PowerHelperService):
//   - keep the Mac awake with the lid closed: pmset disablesleep 1, as a lease the app renews every 30 s. On battery
//     this is the only thing that holds a closed MacBook (measured on MacBookPro18,3: every power assertion is
//     ignored). disablesleep survives a reboot, so a marker file is written before it is set, and whoever starts
//     next (this daemon at boot, RunAtLoad) sets it back to 0 if the marker is there.
//   - the iPhone hotspot's join settings (auto-join and "Ask to join hotspots"), applied and read back;
//   - joining a network macOS already knows, restarting airportd, Wi-Fi off and on (network care with the lid closed).
// When Cloupi's wake daemon is on this Mac it owns sleep and Wi-Fi: then this helper refuses everything and never
// touches pmset (Docs/DESIGN.md, "Staying awake, freezing and the hotspot").

let supportFolder = URL(fileURLWithPath: "/Library/Application Support/\(Brand.name)", isDirectory: true)
let holdMarker = supportFolder.appendingPathComponent("powerd-holding")
let wifiMarker = supportFolder.appendingPathComponent("powerd-wifi-off")
let logURL = URL(fileURLWithPath: "/Library/Logs/\(Brand.name)/powerd.log")

func log(_ line: String) {
    let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    FileHandle.standardError.write(Data(text.utf8))
    let fm = FileManager.default
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o755])
    if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 1_000_000 {
        try? fm.removeItem(at: logURL.appendingPathExtension("old"))
        try? fm.moveItem(at: logURL, to: logURL.appendingPathExtension("old"))
    }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
        fm.createFile(atPath: logURL.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o644])
    }
}

/// Runs a system tool; output and status for the log.
@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (ok: Bool, output: String) {
    guard let r = try? Subprocess.runBlocking(path, args, timeout: timeout) else { return (false, "\(path) didn't start") }
    let out = (String(decoding: r.stdout, as: UTF8.self) + String(decoding: r.stderr, as: UTF8.self))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (r.status == 0 && !r.timedOut, out)
}

func sleepDisabled() -> Int? {
    let r = run("/usr/bin/pmset", ["-g"], timeout: 10)
    return r.ok ? HoldPolicy.parseDisableSleep(r.output) : nil
}

func preferredNetworks() -> [String] {
    let r = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", WiFiRadio.interfaceName], timeout: 10)
    return r.ok ? NetworkCarePolicy.parsePreferred(r.output) : []
}

final class PowerDaemon: NSObject, NSXPCListenerDelegate, PowerHelperXPC {
    /// State lives on this queue.
    private let queue = DispatchQueue(label: "dev.marquart.aos.powerd.state")
    /// Long work (applying, joining, recovering), one at a time.
    private let work = DispatchQueue(label: "dev.marquart.aos.powerd.work")
    private let listener = NSXPCListener(machServiceName: PowerHelperService.machService)
    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var leaseUntil: Date?
    private var holding = false
    /// This helper set disablesleep 1 itself (and writes it back to 0 when the hold ends).
    private var ownsHold = false
    private var lastSleepDisabled: Int?
    private var hotspotNames: [String]?
    private var note: String?
    private var busy = false
    private var lastActivity = Date()
    private var lastRecovery: [String: Date] = [:]
    private var lastStartFailure: Date?
    private var ticks = 0

    /// Exit when nothing is held or running for this long; launchd starts the helper again with the next message.
    static let idleExitSeconds: TimeInterval = 120
    /// Recovery steps at most this often (network care asks for them; this is the helper's own brake).
    static let recoveryIntervalSeconds: TimeInterval = 240

    func start() {
        queue.sync { cleanUpEarlierRun() }
        listener.setConnectionCodeSigningRequirement(PowerHelperService.appRequirement)
        listener.delegate = self
        listener.resume()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler { [weak self] in self?.shutdown(signal: sig) }
            s.resume()
            signalSources.append(s)
        }
        log("started (pid \(getpid()))")
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The code signing requirement set on the listener is checked by the system for every message.
        connection.exportedInterface = NSXPCInterface(with: PowerHelperXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: Lease and pmset

    /// Earlier run ended without cleaning up (crash, power loss): its disablesleep and a Wi-Fi left off.
    private func cleanUpEarlierRun() {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        if fm.fileExists(atPath: holdMarker.path) {
            if CloupiPresence.detect() {
                log("marker of an earlier hold found; Cloupi manages sleep now, pmset left alone")
            } else {
                let r = run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
                log("marker of an earlier hold found: disablesleep 0 (\(r.ok ? "done" : "failed: \(r.output)"))")
            }
            try? fm.removeItem(at: holdMarker)
        }
        if fm.fileExists(atPath: wifiMarker.path) {
            let r = run("/usr/sbin/networksetup", ["-setairportpower", WiFiRadio.interfaceName, "on"])
            log("Wi-Fi was left off by an earlier run: switched on (\(r.ok ? "done" : "failed: \(r.output)"))")
            try? fm.removeItem(at: wifiMarker)
        }
    }

    private func tick() {
        ticks += 1
        enforce()
        let leaseOver = leaseUntil.map { $0 <= Date() } ?? true
        if !holding && leaseOver && !busy && Date().timeIntervalSince(lastActivity) > Self.idleExitSeconds {
            log("idle, exiting")
            exit(0)
        }
    }

    private func enforce() {
        let now = Date()
        let cloupi = CloupiPresence.detect()
        let power = MacState.power()
        let want = HoldPolicy.shouldHold(leaseUntil: leaseUntil, now: now, cloupiPresent: cloupi,
                                         onAC: power?.onAC ?? true, batteryPercent: power?.percent,
                                         thermalCritical: MacState.thermalCritical)
        if want && !holding {
            // After a failure, try again only once a minute.
            if let failed = lastStartFailure, now.timeIntervalSince(failed) < 60 { return }
            startHold()
        } else if !want && holding {
            let why = cloupi ? "Cloupi manages sleep now" : (leaseUntil.map { $0 > now } ?? false)
                ? (MacState.thermalCritical ? "too hot" : "battery low") : "lease ended"
            endHold(reason: why, touchPmset: !cloupi)
        } else if holding && ticks % 12 == 0 {
            // Someone set it back (pmset by hand), or whoever had set it before us released it: hold it again.
            lastSleepDisabled = sleepDisabled()
            if lastSleepDisabled == 0 {
                log("disablesleep was reset by someone else, setting it again")
                holding = false
                ownsHold = false
                startHold()
            }
        }
    }

    private func startHold() {
        // Already on (set by someone else): hold without owning it, and leave it as it is afterwards.
        if sleepDisabled() == 1 {
            lastSleepDisabled = 1
            holding = true
            ownsHold = false
            note = nil
            log("disablesleep is already 1 (set by someone else): holding without changing it")
            return
        }
        // The marker comes first: if this process dies right after pmset, the next start undoes it.
        let marker = "{\"since\":\(Int(Date().timeIntervalSince1970)),\"pid\":\(getpid())}"
        guard FileManager.default.createFile(atPath: holdMarker.path, contents: Data(marker.utf8),
                                             attributes: [.posixPermissions: 0o644]) else {
            note = "can't write \(holdMarker.path)"
            lastStartFailure = Date()
            log("hold refused: \(note!)")
            return
        }
        let r = run("/usr/bin/pmset", ["-a", "disablesleep", "1"])
        lastSleepDisabled = sleepDisabled()
        if r.ok && lastSleepDisabled == 1 {
            holding = true
            ownsHold = true
            note = nil
            lastStartFailure = nil
            log("holding the Mac awake with the lid closed (disablesleep 1)")
        } else {
            note = "pmset disablesleep 1 failed: \(r.output)"
            lastStartFailure = Date()
            log(note!)
            _ = run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            try? FileManager.default.removeItem(at: holdMarker)
        }
    }

    /// Sets disablesleep back to 0 only if this helper set it (and Cloupi isn't there).
    private func endHold(reason: String, touchPmset: Bool) {
        if touchPmset && ownsHold {
            let r = run("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            lastSleepDisabled = sleepDisabled()
            log("released (\(reason)): disablesleep 0 \(r.ok ? "" : "failed: \(r.output)")")
        } else {
            log("released (\(reason)), pmset left as it was")
        }
        holding = false
        ownsHold = false
        try? FileManager.default.removeItem(at: holdMarker)
    }

    private func shutdown(signal sig: Int32) {
        if holding { endHold(reason: "helper stopping (signal \(sig))", touchPmset: !CloupiPresence.detect()) }
        if FileManager.default.fileExists(atPath: wifiMarker.path) {
            _ = run("/usr/sbin/networksetup", ["-setairportpower", WiFiRadio.interfaceName, "on"])
            try? FileManager.default.removeItem(at: wifiMarker)
        }
        log("stopped (signal \(sig))")
        exit(0)
    }

    private func currentStatus() -> HelperStatus {
        HelperStatus(holding: holding, leaseUntil: leaseUntil, sleepDisabled: lastSleepDisabled,
                     cloupiPresent: CloupiPresence.detect(), hotspotNames: hotspotNames, note: note)
    }

    // MARK: PowerHelperXPC

    func status(reply: @escaping (Data) -> Void) {
        queue.async {
            self.lastActivity = Date()
            if self.lastSleepDisabled == nil { self.lastSleepDisabled = sleepDisabled() }
            if self.hotspotNames == nil { self.hotspotNames = self.readHotspotNames() }
            reply(HelperReply(ok: true, status: self.currentStatus()).data)
        }
    }

    func hold(seconds: Int, reply: @escaping (Data) -> Void) {
        queue.async {
            self.lastActivity = Date()
            if CloupiPresence.detect() {
                self.leaseUntil = nil
                self.enforce()
                reply(HelperReply(ok: false, message: "Cloupi manages sleep on this Mac", status: self.currentStatus()).data)
                return
            }
            let s = HoldPolicy.clampedLease(seconds)
            self.leaseUntil = s > 0 ? Date().addingTimeInterval(TimeInterval(s)) : nil
            self.enforce()
            var message = self.note ?? ""
            if s > 0 && !self.holding && message.isEmpty {
                message = MacState.thermalCritical ? "the Mac is too hot" : "the battery is almost empty"
            }
            reply(HelperReply(ok: s == 0 || self.holding, message: message, status: self.currentStatus()).data)
        }
    }

    /// "automatic" or "manual": the choice for the closed lid; the user's own settings are noted first (once) so
    /// "restore" can write them back when the lid opens. "restore" without a note does nothing.
    func applyHotspotJoin(_ mode: String, reply: @escaping (Data) -> Void) {
        if mode == "restore" {
            longWork(reply) { self.restoreOriginal() }
            return
        }
        guard let join = HotspotJoin(rawValue: mode) else {
            reply(HelperReply(ok: false, message: "unknown choice").data)
            return
        }
        longWork(reply) {
            if let problem = self.noteOriginal() { return HelperReply(ok: false, message: problem) }
            return self.apply(join)
        }
    }

    func join(network: String, reply: @escaping (Data) -> Void) {
        guard NetworkCarePolicy.validNetworkName(network) else {
            reply(HelperReply(ok: false, message: "invalid network name").data)
            return
        }
        longWork(reply) { self.joinKnown(network) }
    }

    func recover(_ step: String, reply: @escaping (Data) -> Void) {
        guard let step = PowerHelperService.Recovery(rawValue: step) else {
            reply(HelperReply(ok: false, message: "unknown step").data)
            return
        }
        let allowed: Bool = queue.sync {
            if let last = lastRecovery[step.rawValue], Date().timeIntervalSince(last) < Self.recoveryIntervalSeconds { return false }
            lastRecovery[step.rawValue] = Date()
            return true
        }
        guard allowed else {
            reply(HelperReply(ok: false, message: "too soon after the last \(step.rawValue)").data)
            return
        }
        longWork(reply) {
            switch step {
            case .restartAirportd: return self.restartAirportd(reason: "network care")
            case .cycleWiFi: return self.cycleWiFi()
            }
        }
    }

    /// Runs `body` on the work queue, one at a time; refuses while Cloupi is there or other work runs.
    private func longWork(_ reply: @escaping (Data) -> Void, _ body: @escaping () -> HelperReply) {
        queue.async {
            self.lastActivity = Date()
            if CloupiPresence.detect() {
                reply(HelperReply(ok: false, message: "Cloupi manages Wi-Fi on this Mac").data)
                return
            }
            if self.busy {
                reply(HelperReply(ok: false, message: "busy").data)
                return
            }
            self.busy = true
            self.work.async {
                let result = body()
                self.queue.async {
                    self.busy = false
                    self.lastActivity = Date()
                    var r = result
                    r.status = self.currentStatus()
                    reply(r.data)
                }
            }
        }
    }

    // MARK: Hotspot settings

    /// The user's own hotspot settings while aOS's lid-closed choice is in effect (root only).
    static let originalFile = supportFolder.appendingPathComponent("hotspot-before-lid.json")

    private func readHotspotModeString() -> String? {
        guard let prefs = SCPreferencesCreate(nil, "aos-powerd" as CFString, WiFiPreferences.airportPreferencesID as CFString)
        else { return nil }
        return SCPreferencesGetValue(prefs, WiFiPreferences.autoHotspotModeKey as CFString) as? String
    }

    /// Notes the user's settings unless a note exists already (the lid closed again before it was restored).
    private func noteOriginal() -> String? {
        if FileManager.default.fileExists(atPath: Self.originalFile.path) { return nil }
        guard let store = knownNetworks() else { return "macOS didn't let the helper read the known networks" }
        let original = WiFiPreferences.original(in: store, hotspotMode: readHotspotModeString())
        do {
            try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(original).write(to: Self.originalFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.originalFile.path)
        } catch {
            return "couldn't note the current hotspot settings: \(error.localizedDescription)"
        }
        log("noted the user's hotspot settings (\(original.autoJoinDisabled.count) hotspots, Ask to join hotspots \(original.hotspotMode ?? "not set"))")
        return nil
    }

    /// Writes the noted settings back (the lid opened) and removes the note.
    private func restoreOriginal() -> HelperReply {
        guard let data = try? Data(contentsOf: Self.originalFile),
              let original = try? JSONDecoder().decode(WiFiPreferences.Original.self, from: data) else {
            return HelperReply(ok: true, message: "nothing to restore", wifi: WiFiRadio.readState())
        }
        var problems: [String] = []
        var changed = false
        if let store = knownNetworks() {
            let changes = WiFiPreferences.restoringAutoJoin(in: store, original: original)
            if !changes.isEmpty {
                let domain = WiFiPreferences.knownNetworksDomain as CFString
                for (key, entry) in changes {
                    CFPreferencesSetValue(key as CFString, entry as CFDictionary, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
                }
                if !CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) {
                    problems.append("the known networks couldn't be written")
                }
                changed = true
            }
        } else {
            problems.append("macOS didn't let the helper read the known networks")
        }
        if readHotspotModeString() != original.hotspotMode {
            if let saved = original.hotspotMode, let mode = WiFiPreferences.HotspotMode(schemaString: saved) {
                if !writeHotspotMode(mode) { problems.append("Ask to join hotspots couldn't be written") }
            } else if !removeHotspotMode() {
                problems.append("Ask to join hotspots couldn't be reset")
            }
            changed = true
        }
        if changed { _ = restartAirportd(reason: "the lid opened, the user's hotspot settings again") }
        if problems.isEmpty { try? FileManager.default.removeItem(at: Self.originalFile) }
        log("restored the user's hotspot settings" + (problems.isEmpty ? "" : ": " + problems.joined(separator: "; ")))
        return HelperReply(ok: problems.isEmpty, message: problems.joined(separator: "; "), wifi: WiFiRadio.readState())
    }

    private func removeHotspotMode() -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "aos-powerd" as CFString, WiFiPreferences.airportPreferencesID as CFString),
              SCPreferencesLock(prefs, true) else { return false }
        defer { SCPreferencesUnlock(prefs) }
        let key = WiFiPreferences.autoHotspotModeKey as CFString
        if SCPreferencesGetValue(prefs, key) == nil { return true }
        guard SCPreferencesRemoveValue(prefs, key) else { return false }
        return SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs)
    }

    private func knownNetworks() -> [String: Any]? {
        let domain = WiFiPreferences.knownNetworksDomain as CFString
        if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty,
           let values = CFPreferencesCopyMultiple(keys as CFArray, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String: Any],
           !values.isEmpty {
            return values
        }
        // The file itself, in case the preferences daemon doesn't serve it.
        let file = URL(fileURLWithPath: "/Library/Preferences/\(WiFiPreferences.knownNetworksDomain).plist")
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist
    }

    private func readHotspotNames() -> [String]? {
        guard let store = knownNetworks() else { return nil }
        return WiFiPreferences.personalHotspots(in: store).map(\.name)
    }

    private func writeAutoJoin(_ disabled: Bool, store: [String: Any]) -> (changed: Int, ok: Bool) {
        let changes = WiFiPreferences.settingAutoJoin(in: store, disabled: disabled)
        guard !changes.isEmpty else { return (0, true) }
        let domain = WiFiPreferences.knownNetworksDomain as CFString
        for (key, entry) in changes {
            CFPreferencesSetValue(key as CFString, entry as CFDictionary, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        }
        return (changes.count, CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost))
    }

    /// "Ask to join hotspots": a key of airportd's global configuration (SystemConfiguration's airport preferences),
    /// written the way airportd's own `prefs` verb writes its keys.
    private func writeHotspotMode(_ mode: WiFiPreferences.HotspotMode) -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "aos-powerd" as CFString, WiFiPreferences.airportPreferencesID as CFString),
              SCPreferencesLock(prefs, true) else { return false }
        defer { SCPreferencesUnlock(prefs) }
        let key = WiFiPreferences.autoHotspotModeKey as CFString
        if (SCPreferencesGetValue(prefs, key) as? String) == mode.schemaString { return true }
        guard SCPreferencesSetValue(prefs, key, mode.schemaString as CFString) else { return false }
        return SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs)
    }

    private func apply(_ join: HotspotJoin) -> HelperReply {
        let disabled = WiFiPreferences.autoJoinDisabled(for: join)
        let mode = WiFiPreferences.hotspotMode(for: join)
        log("applying hotspot choice \(join.rawValue): auto-join \(disabled ? "off" : "on"), Ask to join hotspots \(mode.schemaString)")
        let before = WiFiRadio.readState()
        if let before, before.matches(join) {
            log("already in effect")
            return HelperReply(ok: true, message: "already in effect", wifi: before)
        }
        let store = knownNetworks()
        if let store { queue.sync { hotspotNames = WiFiPreferences.personalHotspots(in: store).map(\.name) } }
        var problems: [String] = []
        var wrote = 0
        if let store {
            let r = writeAutoJoin(disabled, store: store)
            wrote = r.changed
            if !r.ok { problems.append("the known networks couldn't be written") }
        } else {
            problems.append("macOS didn't let the helper read the known networks")
        }
        if !writeHotspotMode(mode) { problems.append("Ask to join hotspots couldn't be written") }
        log("wrote \(wrote) known networks" + (problems.isEmpty ? "" : "; " + problems.joined(separator: "; ")))
        // airportd reads both when it starts.
        _ = restartAirportd(reason: "hotspot choice")
        var after = waitForState(join, seconds: 15)
        if after?.matches(join) != true, let store {
            // Once more, and this time airportd ends without its own exit path (it can't write old values back).
            _ = writeAutoJoin(disabled, store: store)
            _ = writeHotspotMode(mode)
            let r = run("/bin/launchctl", ["kill", "SIGKILL", "system/com.apple.airportd"])
            log("second try, airportd ended with SIGKILL (\(r.ok ? "done" : r.output))")
            after = waitForState(join, seconds: 15)
        }
        let ok = after?.matches(join) == true
        let summary = describe(after)
        log("result: \(ok ? "in effect" : "not in effect"): \(summary)")
        return HelperReply(ok: ok, message: ok ? "" : (problems + ["macOS reports: \(summary)"]).joined(separator: "; "),
                           wifi: after)
    }

    private func waitForState(_ join: HotspotJoin, seconds: Int) -> WiFiState? {
        var state: WiFiState?
        for _ in 0..<(seconds / 3) {
            Thread.sleep(forTimeInterval: 3)
            state = WiFiRadio.readState()
            if state?.matches(join) == true { break }
        }
        return state
    }

    private func describe(_ s: WiFiState?) -> String {
        guard let s else { return "no answer from airportd" }
        let mode = s.hotspotMode?.schemaString ?? "unknown"
        let hotspots = s.personalHotspots.map { "\($0) hotspots, auto-join off for \(s.autoJoinOff ?? 0)" } ?? "hotspots unknown"
        return "Ask to join hotspots \(mode), \(hotspots)"
    }

    // MARK: Network

    private func joinKnown(_ name: String) -> HelperReply {
        guard preferredNetworks().contains(name) else {
            return HelperReply(ok: false, message: "not a network this Mac knows")
        }
        let r = run("/usr/sbin/networksetup", ["-setairportnetwork", WiFiRadio.interfaceName, name], timeout: 25)
        // networksetup sometimes reports "Failed to join" and the Mac is connected two seconds later (Cloupi saw it
        // on this Mac): the address decides.
        for _ in 0..<10 {
            let ip = WiFiRadio.ipv4()
            if !ip.isEmpty {
                log("joined \(name) (\(NetworkCarePolicy.isHotspotAddress(ip) ? "hotspot address" : "address \(ip)"))")
                return HelperReply(ok: true, message: ip)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        let out = r.output.isEmpty ? "no address" : String(r.output.prefix(120))
        log("joining \(name) failed: \(out)")
        return HelperReply(ok: false, message: out)
    }

    private func restartAirportd(reason: String) -> HelperReply {
        let r = run("/bin/launchctl", ["kickstart", "-k", "system/com.apple.airportd"])
        log("restarted airportd (\(reason)): \(r.ok ? "done" : r.output)")
        // Wake it up again so it surely runs before anyone asks.
        Thread.sleep(forTimeInterval: 2)
        _ = WiFiRadio.powerOn()
        return HelperReply(ok: r.ok, message: r.ok ? "" : r.output)
    }

    private func cycleWiFi() -> HelperReply {
        guard WiFiRadio.powerOn() == true else { return HelperReply(ok: false, message: "Wi-Fi is off") }
        guard FileManager.default.createFile(atPath: wifiMarker.path, contents: Data(), attributes: [.posixPermissions: 0o644]) else {
            return HelperReply(ok: false, message: "can't write the marker")
        }
        _ = run("/usr/sbin/networksetup", ["-setairportpower", WiFiRadio.interfaceName, "off"])
        Thread.sleep(forTimeInterval: 3)
        _ = run("/usr/sbin/networksetup", ["-setairportpower", WiFiRadio.interfaceName, "on"])
        var on = false
        for _ in 0..<5 {
            let r = run("/usr/sbin/networksetup", ["-getairportpower", WiFiRadio.interfaceName], timeout: 8)
            if r.output.contains(": On") { on = true; break }
            Thread.sleep(forTimeInterval: 1)
            _ = run("/usr/sbin/networksetup", ["-setairportpower", WiFiRadio.interfaceName, "on"])
        }
        if on { try? FileManager.default.removeItem(at: wifiMarker) }
        log("Wi-Fi off and on (network care): \(on ? "on again" : "still off, marker kept")")
        return HelperReply(ok: on, message: on ? "" : "Wi-Fi didn't come back on")
    }
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("aos-powerd runs as root, started by launchd (SMAppService.daemon).\n".utf8))
    exit(1)
}
let daemon = PowerDaemon()
daemon.start()
dispatchMain()
