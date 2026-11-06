import Foundation

/// What the app knows when it decides how to keep the Mac awake (read every two seconds).
public struct AwakeFacts: Equatable, Sendable {
    public var setting: StayAwake
    /// Something must stay reachable: aOS's own session, kept conversations, or the workspace is in use.
    public var needed: Bool
    /// nil: unknown (a Mac without a lid, or unreadable). Counts as open: nothing freezes on a guess.
    public var lidClosed: Bool?
    public var onAC: Bool
    public var batteryPercent: Int?
    /// ProcessInfo.thermalState is critical.
    public var thermalCritical: Bool
    /// A screen other than the built-in one is connected: closed lid at a desk, the user is working.
    public var externalDisplay: Bool
    /// Cloupi's wake daemon runs on this Mac: it owns sleep and Wi-Fi, aOS touches neither.
    public var cloupiPresent: Bool
    /// aOS's background helper is registered and allowed (SMAppService status enabled).
    public var helperReady: Bool

    public init(setting: StayAwake, needed: Bool, lidClosed: Bool?, onAC: Bool, batteryPercent: Int?,
                thermalCritical: Bool = false, externalDisplay: Bool = false, cloupiPresent: Bool = false,
                helperReady: Bool) {
        self.setting = setting
        self.needed = needed
        self.lidClosed = lidClosed
        self.onAC = onAC
        self.batteryPercent = batteryPercent
        self.thermalCritical = thermalCritical
        self.externalDisplay = externalDisplay
        self.cloupiPresent = cloupiPresent
        self.helperReady = helperReady
    }
}

/// Why the chosen setting isn't (fully) in effect right now.
public enum AwakeBlocker: String, Equatable, Sendable {
    /// Cloupi manages sleep and Wi-Fi on this Mac.
    case cloupi
    /// Nothing must stay reachable right now (no session, no kept conversations, no workspace).
    case nothingToKeep
    /// "Also with the lid closed" needs the background helper, which isn't registered or allowed yet.
    case helperNotReady
    /// On battery below `AwakePolicy.minBatteryPercent`: the Mac may sleep, so the battery doesn't run flat.
    case lowBattery
    /// The Mac is too hot (in a bag): it may sleep.
    case thermal
}

public struct AwakeDecision: Equatable, Sendable {
    /// The app holds PreventUserIdleSystemSleep (the Mac doesn't fall asleep by itself while open).
    public var idleAssertion = false
    /// The helper keeps the Mac awake with the lid closed (pmset disablesleep), as a lease the app renews. Held
    /// already while the lid is open: set only when it closes, the Mac would be asleep before anyone could react.
    public var holdLidClosed = false
    /// The lid is closed and the Mac is held: freeze the other apps, switch the display off, look after the network.
    public var lidClosedMode = false
    public var blocker: AwakeBlocker?

    public init(idleAssertion: Bool = false, holdLidClosed: Bool = false, lidClosedMode: Bool = false,
                blocker: AwakeBlocker? = nil) {
        self.idleAssertion = idleAssertion
        self.holdLidClosed = holdLidClosed
        self.lidClosedMode = lidClosedMode
        self.blocker = blocker
    }
}

/// The app's side: pure, tested in AwakePolicyTests.
public enum AwakePolicy {
    /// Below this, on battery, the lid-closed hold rests (the Mac sleeps as usual), like Cloupi's "Wach bleiben".
    public static let minBatteryPercent = 10

    public static func decide(_ f: AwakeFacts) -> AwakeDecision {
        // Cloupi's own daemon holds and releases the Mac (pmset) and repairs Wi-Fi; two owners would fight.
        if f.cloupiPresent { return AwakeDecision(blocker: .cloupi) }
        if f.setting == .off { return AwakeDecision() }
        guard f.needed else { return AwakeDecision(blocker: .nothingToKeep) }
        var d = AwakeDecision(idleAssertion: true)
        guard f.setting == .lidClosed else { return d }
        if !f.helperReady {
            d.blocker = .helperNotReady
        } else if !f.onAC, let p = f.batteryPercent, p < minBatteryPercent {
            d.blocker = .lowBattery
        } else if f.thermalCritical {
            d.blocker = .thermal
        } else {
            d.holdLidClosed = true
            d.lidClosedMode = f.lidClosed == true && !f.externalDisplay
        }
        return d
    }
}

/// The helper's side of the lid-closed hold (pmset disablesleep), pure, tested in AwakePolicyTests. The helper
/// re-checks it every few seconds, so a lease the app stops renewing (quit, crash) ends on its own.
public enum HoldPolicy {
    /// A lease is at most this long; the app renews it every 30 s.
    public static let maxLeaseSeconds = 180
    /// How often the app renews.
    public static let renewSeconds: TimeInterval = 30

    public static func clampedLease(_ seconds: Int) -> Int { min(max(seconds, 0), maxLeaseSeconds) }

    public static func shouldHold(leaseUntil: Date?, now: Date, cloupiPresent: Bool, onAC: Bool,
                                  batteryPercent: Int?, thermalCritical: Bool) -> Bool {
        guard let until = leaseUntil, until > now, !cloupiPresent, !thermalCritical else { return false }
        if !onAC, let p = batteryPercent, p < AwakePolicy.minBatteryPercent { return false }
        return true
    }

    /// `pmset -g` lists "SleepDisabled 1" only while it is on; no line means 0.
    public static func parseDisableSleep(_ pmsetOutput: String) -> Int {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled", let v = Int(parts[1]) { return v }
        }
        return 0
    }
}

/// Is Cloupi's wake daemon (de.cloupi.waked) on this Mac? It manages pmset and Wi-Fi the same way; when it is there,
/// aOS neither keeps the Mac awake nor touches Wi-Fi, and shows "Managed by Cloupi". Only looks; never reads its
/// files or talks to its services.
public enum CloupiPresence {
    public static let daemonLabel = "de.cloupi.waked"
    public static let stateFolder = "/Library/Application Support/cloupi-wake"
    public static let daemonPlist = "/Library/LaunchDaemons/de.cloupi.waked.plist"

    /// Cheap: two file system checks, safe to call every few seconds.
    public static func detect(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(stateFolder) || fileExists(daemonPlist)
    }

    /// Also asks launchd whether the job is loaded (a process start; call it rarely).
    public static func detectWithLaunchd() -> Bool {
        if detect() { return true }
        let r = try? Subprocess.runBlocking("/bin/launchctl", ["print", "system/\(daemonLabel)"], timeout: 5)
        return r?.status == 0
    }
}
