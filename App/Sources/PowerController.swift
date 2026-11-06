import AOSKit
import AppKit
import ServiceManagement
import SwiftUI

/// Staying awake, freezing with the lid closed, the display, network care and the iPhone hotspot choice
/// (Docs/DESIGN.md, "Staying awake, freezing and the hotspot"). The decisions come from AOSKit's pure policies
/// (AwakePolicy, FreezePlanner, NetworkCarePolicy); this class reads the Mac's state every two seconds, acts, and
/// publishes what the settings show. Root work goes to the helper (aos-powerd) over XPC.
@MainActor
final class PowerController: ObservableObject {
    enum HotspotApply: Equatable {
        case idle
        case working
        case waitingForHelper
        case done
        case failed(String)
    }

    @Published private(set) var decision = AwakeDecision()
    @Published private(set) var helperStatus: SMAppService.Status = .notRegistered
    @Published private(set) var cloupiPresent = false
    @Published private(set) var frozenApps: [String] = []
    @Published private(set) var wifi: WiFiState?
    @Published private(set) var hotspotApply: HotspotApply = .idle
    @Published private(set) var helperNote: String?
    @Published private(set) var holding = false

    var log: (String) -> Void = { _ in }

    static var daemon: SMAppService { SMAppService.daemon(plistName: PowerHelperService.plistName) }

    private let keepAwake = KeepAwake()
    private let freezer: Freezer
    private let helper = PowerHelperClient()
    private var started = false
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var appNapActivity: NSObjectProtocol?

    private var lastLease = Date.distantPast
    private var leaseWanted = false
    private var lidClosedSince: Date?
    private var lastDisplaySleep = Date.distantPast
    private var wakeGraceUntil = Date.distantPast
    private var lastFreezeCheck = Date.distantPast
    private var lastNetworkTick = Date.distantPast
    private var cloupiLaunchdCheck = Date.distantPast
    private var cloupiByLaunchd = false
    private var lastWall = Date().timeIntervalSince1970
    private var lastUptime = ProcessInfo.processInfo.systemUptime
    private var network = NetworkMemory()
    private var networkBusy = false
    private var preferredNetworks: (at: Date, names: [String])?
    private var helperHotspots: [String]?
    private var pendingHotspot: HotspotJoin?

    /// Freeze only after the lid has been closed (and no input came) for this long.
    static let freezeAfterSeconds: TimeInterval = 20
    /// Look for new apps to freeze this often while frozen.
    static let freezeCheckSeconds: TimeInterval = 10
    /// Network care looks this often.
    static let networkTickSeconds: TimeInterval = 15
    /// After waking up, macOS reports input for a moment that nobody made.
    static let wakeGraceSeconds: TimeInterval = 15

    init(paths: Paths) {
        freezer = Freezer(recordURL: FrozenRecord.url(paths))
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        freezer.log = { [weak self] line in self?.log(line) }
        FreezerCrashGuard.install()
        // Whatever an earlier run left frozen continues now.
        freezer.thawAll(reason: "\(Brand.name) started")
        cloupiByLaunchd = CloupiPresence.detectWithLaunchd()
        cloupiLaunchdCheck = Date()
        cloupiPresent = cloupiByLaunchd
        refreshHelperStatus()
        // Termination signals: continue the frozen apps and quit in order (the workspace closes too).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.freezer.thawAll(reason: "signal \(sig)")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.noteWake()
                self?.updateAgain()
            }
        })
        // The lid opened (the screens wake): continue the frozen apps at once, not at the next tick.
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAgain() }
        })
    }

    private var lastInputs: (settings: AgentSettings, needed: Bool)?

    private func updateAgain() {
        if let last = lastInputs { update(settings: last.settings, needed: last.needed) }
    }

    /// Before quitting: continue everything, release the hold.
    func shutdown() async {
        freezer.thawAll(reason: "\(Brand.name) quits")
        frozenApps = []
        if leaseWanted || holding {
            // Quick: if the helper doesn't answer, its lease ends on its own within three minutes.
            _ = await helper.hold(seconds: 0, timeout: 3)
            leaseWanted = false
            holding = false
        }
        helper.disconnect()
    }

    private func noteWake() {
        wakeGraceUntil = Date().addingTimeInterval(Self.wakeGraceSeconds)
        network.noteWake(now: Date().timeIntervalSince1970)
    }

    // MARK: The tick (AppModel.refresh, every 2 s)

    func update(settings: AgentSettings, needed: Bool) {
        guard started else { return }
        lastInputs = (settings, needed)
        let now = Date()
        // A wake from sleep, also a dark wake: the wall clock jumped, the system's uptime didn't.
        let wall = now.timeIntervalSince1970
        let up = ProcessInfo.processInfo.systemUptime
        if (wall - lastWall) - (up - lastUptime) > 5 { noteWake() }
        lastWall = wall
        lastUptime = up

        if now.timeIntervalSince(cloupiLaunchdCheck) > 300 {
            cloupiLaunchdCheck = now
            cloupiByLaunchd = CloupiPresence.detectWithLaunchd()
        }
        let cloupi = cloupiByLaunchd || CloupiPresence.detect()
        if cloupi != cloupiPresent { cloupiPresent = cloupi }

        let lid = MacState.lidClosed()
        let power = MacState.power()
        let displays = MacState.displays()
        let facts = AwakeFacts(setting: settings.stayAwake, needed: needed, lidClosed: lid, onAC: power?.onAC ?? true,
                               batteryPercent: power?.percent, thermalCritical: MacState.thermalCritical,
                               externalDisplay: (displays?.external ?? 1) > 0, cloupiPresent: cloupi,
                               helperReady: helperStatus == .enabled)
        let d = AwakePolicy.decide(facts)
        if d != decision { decision = d }

        keepAwake.set(d.idleAssertion)
        // Timers must keep their pace while the lid is closed (no App Nap), or the lid opening would be noticed late.
        setAppNapPrevented(settings.stayAwake == .lidClosed && d.holdLidClosed)
        updateLease(d.holdLidClosed, now: now)
        // Only once the helper confirmed the hold: otherwise the Mac sleeps with the lid closed anyway.
        let lidClosedMode = d.lidClosedMode && holding
        updateFreezer(lidClosedMode, now: now)
        if lidClosedMode {
            sleepDisplayIfNeeded(displays, now: now)
            networkTick(now: now)
        } else if network.offlineSince != nil {
            network = NetworkMemory()
        }
        if helperStatus == .enabled, let join = pendingHotspot {
            pendingHotspot = nil
            applyHotspot(join)
        }
    }

    private func setAppNapPrevented(_ on: Bool) {
        if on, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Keeps the Mac awake with the lid closed and continues frozen apps when it opens")
        } else if !on, let a = appNapActivity {
            ProcessInfo.processInfo.endActivity(a)
            appNapActivity = nil
        }
    }

    // MARK: The helper

    func refreshHelperStatus() {
        let s = Self.daemon.status
        if s != helperStatus { helperStatus = s }
    }

    /// Registers the helper with macOS if it isn't yet; macOS then asks the user to allow it in Login Items.
    func ensureHelperRegistered() {
        let service = Self.daemon
        switch service.status {
        case .enabled, .requiresApproval:
            break
        default:
            do {
                try service.register()
                log("background helper registered")
            } catch {
                log("background helper: \(error.localizedDescription)")
                helperNote = error.localizedDescription
            }
        }
        refreshHelperStatus()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The lease: renewed every 30 s while wanted; released at once when not.
    private func updateLease(_ want: Bool, now: Date) {
        if want {
            leaseWanted = true
            guard now.timeIntervalSince(lastLease) >= HoldPolicy.renewSeconds else { return }
            lastLease = now
            Task {
                let r = await helper.hold(seconds: HoldPolicy.maxLeaseSeconds)
                guard self.leaseWanted else { return }
                self.holding = r.status?.holding ?? false
                let note: String? = r.ok || r.message.isEmpty ? nil : r.message
                if note != self.helperNote { self.helperNote = note }
                if let names = r.status?.hotspotNames { self.helperHotspots = names }
            }
        } else if leaseWanted {
            leaseWanted = false
            lastLease = .distantPast
            Task {
                _ = await helper.hold(seconds: 0)
                if !self.leaseWanted { self.holding = false }
            }
        }
    }

    // MARK: Freezing

    private func updateFreezer(_ lidClosedMode: Bool, now: Date) {
        guard lidClosedMode else {
            lidClosedSince = nil
            if !freezer.frozen.isEmpty {
                freezer.thawAll(reason: "lid open, a screen connected or the setting changed")
                frozenApps = freezer.frozenApps
            }
            return
        }
        let since = lidClosedSince ?? now
        lidClosedSince = since
        let idle = MacState.idleSeconds()
        // Someone types or clicks (a keyboard at the closed Mac): everything continues.
        if idle < 3 && now > wakeGraceUntil {
            if !freezer.frozen.isEmpty {
                freezer.thawAll(reason: "input")
                frozenApps = freezer.frozenApps
            }
            lidClosedSince = now
            return
        }
        guard now.timeIntervalSince(since) >= Self.freezeAfterSeconds, idle >= Self.freezeAfterSeconds,
              now.timeIntervalSince(lastFreezeCheck) >= Self.freezeCheckSeconds else { return }
        lastFreezeCheck = now
        guard let table = ProcessTable.snapshot() else { return }
        let uid = getuid()
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningAppInfo? in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id,
                                  regular: app.activationPolicy == .regular)
        }
        let targets = FreezePlanner.plan(apps: apps, table: table, uid: uid, me: getpid(),
                                         responsible: ProcessTable.responsibleMap(table, uid: uid),
                                         isAgent: ProcessTable.isAgent)
        freezer.freeze(targets)
        if freezer.frozenApps != frozenApps { frozenApps = freezer.frozenApps }
    }

    // MARK: Display

    private func sleepDisplayIfNeeded(_ displays: MacState.Displays?, now: Date) {
        guard let d = displays, let since = lidClosedSince,
              LidDisplayPolicy.shouldSleepDisplay(lidClosedFor: now.timeIntervalSince(since), builtinAwake: d.builtinAwake,
                                                  externalDisplays: d.external,
                                                  sinceLast: now.timeIntervalSince(lastDisplaySleep), sessionShared: false)
        else { return }
        lastDisplaySleep = now
        // Not while someone watches this Mac through screen sharing (the iPhone app, for example).
        guard !MacState.sessionShared() else { return }
        log("lid closed, display was on: switching it off")
        Task.detached(priority: .utility) {
            _ = try? await Subprocess.run("/usr/bin/pmset", ["displaysleepnow"], timeout: 10)
        }
    }

    // MARK: Network care (lid closed)

    private enum NetworkOutcome: Sendable {
        case nothing
        case scanned(found: Int)
        case joined(String, ok: Bool, message: String)
        case airportd(ok: Bool)
        case cycled(ok: Bool)
    }

    private func networkTick(now: Date) {
        guard now.timeIntervalSince(lastNetworkTick) >= Self.networkTickSeconds, !networkBusy else { return }
        lastNetworkTick = now
        let t = now.timeIntervalSince1970
        let ip = WiFiRadio.ipv4()
        if !ip.isEmpty || WiFiRadio.onlineElsewhere() {
            if let since = network.offlineSince { log("network back after \(Int(t - since)) s") }
            network.noteOnline()
            return
        }
        network.noteOffline(now: t)
        networkBusy = true
        let memory = network
        let fromHelper = helperHotspots
        let cachedPreferred = preferredNetworks.flatMap { now.timeIntervalSince($0.at) < 600 ? $0.names : nil }
        let helper = self.helper
        Task.detached(priority: .utility) {
            let wifiOn = WiFiRadio.powerOn() ?? false
            let step = NetworkCarePolicy.next(now: t, wifiOn: wifiOn, hasIPv4: false, memory: memory)
            var preferred = cachedPreferred
            var outcome = NetworkOutcome.nothing
            switch step {
            case .none:
                break
            case .scan:
                if preferred == nil {
                    let r = try? await Subprocess.run("/usr/sbin/networksetup",
                                                      ["-listpreferredwirelessnetworks", WiFiRadio.interfaceName], timeout: 10)
                    preferred = r.map { NetworkCarePolicy.parsePreferred(String(decoding: $0.stdout, as: UTF8.self)) }
                }
                let known = preferred ?? []
                let hotspots = NetworkCarePolicy.hotspotNames(preferred: known, fromHelper: fromHelper)
                let candidates = NetworkCarePolicy.scanCandidates(preferred: known, hotspots: hotspots)
                let visible = WiFiRadio.inRange(candidates) ?? []
                if let target = NetworkCarePolicy.joinTarget(visible: visible, preferred: known, hotspots: hotspots,
                                                             memory: memory, now: t) {
                    let r = await helper.join(network: target)
                    outcome = .joined(target, ok: r.ok, message: r.message)
                } else {
                    outcome = .scanned(found: visible.count)
                }
            case .restartAirportd:
                outcome = .airportd(ok: await helper.recover(.restartAirportd).ok)
            case .cycleWiFi:
                outcome = .cycled(ok: await helper.recover(.cycleWiFi).ok)
            }
            let finalPreferred = preferred
            let finalOutcome = outcome
            await MainActor.run { [weak self] in
                self?.finishNetworkTick(finalOutcome, at: t, step: step, preferred: finalPreferred,
                                        refreshed: cachedPreferred == nil)
            }
        }
    }

    private func finishNetworkTick(_ outcome: NetworkOutcome, at t: Double, step: NetworkStep, preferred: [String]?,
                                   refreshed: Bool) {
        networkBusy = false
        if refreshed, let preferred { preferredNetworks = (Date(), preferred) }
        if step == .scan { network.lastScanAt = t }
        switch outcome {
        case .nothing, .scanned:
            break
        case .joined(let name, let ok, let message):
            network.noteJoin(name, ok: ok, visible: true, now: t)
            log(ok ? "network care: joined \(name)" : "network care: joining \(name) failed (\(message))")
            if ok { network.noteOnline() }
        case .airportd(let ok):
            network.lastAirportdAt = t
            network.visibleFailures = 0
            log("network care: restarted Wi-Fi's service (airportd)\(ok ? "" : ", failed")")
        case .cycled(let ok):
            network.lastCycleAt = t
            network.cyclesInOutage += 1
            log("network care: Wi-Fi off and on\(ok ? "" : ", failed")")
        }
    }

    // MARK: The iPhone hotspot

    /// What macOS reports now (read as this user through airportd; nothing changes).
    func refreshWiFiState() {
        Task.detached(priority: .utility) {
            let state = WiFiRadio.readState()
            await MainActor.run { [weak self] in
                if let state { self?.wifi = state }
            }
        }
    }

    /// Applies the user's choice to macOS through the helper and reads the result back.
    func applyHotspot(_ join: HotspotJoin) {
        guard !cloupiPresent else { return }
        ensureHelperRegistered()
        guard helperStatus == .enabled else {
            pendingHotspot = join
            hotspotApply = .waitingForHelper
            return
        }
        hotspotApply = .working
        let helper = self.helper
        Task {
            let r = await helper.apply(join)
            if let w = r.wifi { self.wifi = w }
            if let names = r.status?.hotspotNames { self.helperHotspots = names }
            self.hotspotApply = r.ok ? .done : .failed(r.message.isEmpty ? String(localized: "macOS didn't take the change.") : r.message)
            self.log("hotspot choice \(join.rawValue): \(r.ok ? "in effect" : "not in effect (\(r.message))")")
            self.refreshWiFiState()
        }
    }

    /// The Wi-Fi pane of System Settings (the fallback when the change didn't take).
    func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
