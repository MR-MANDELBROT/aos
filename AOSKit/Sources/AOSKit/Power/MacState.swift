import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

/// The Mac's state as the stay-awake logic needs it. All of it is readable by a normal user.
public enum MacState {
    public struct Power: Equatable, Sendable {
        public var onAC: Bool
        public var percent: Int?
    }

    /// AppleClamshellState of IOPMrootDomain. nil when absent (a Mac without a lid) or unreadable.
    public static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        let value = prop.takeRetainedValue()
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// Power source and charge (IOPowerSources). nil when nothing is readable.
    public static func power() -> Power? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        var result = Power(onAC: providing == kIOPSACPowerValue, percent: nil)
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return result }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let type = d[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType { continue }
            if let current = d[kIOPSCurrentCapacityKey] as? Int {
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                result.percent = max > 0 ? Int((Double(current) * 100 / Double(max)).rounded()) : current
            }
        }
        return result
    }

    public static var thermalCritical: Bool { ProcessInfo.processInfo.thermalState == .critical }

    /// Seconds since the last keyboard, mouse or trackpad event of the session.
    public static func idleSeconds() -> Double {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .scrollWheel, .flagsChanged]
        var best = Double.greatestFiniteMagnitude
        for t in types {
            let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
            if s.isFinite && s >= 0 && s < best { best = s }
        }
        return best
    }

    public struct Displays: Equatable, Sendable {
        public var builtinAwake: Bool
        /// Screens other than the built-in one, also asleep ones (at a desk the monitor sleeps, the user is there).
        /// The virtual screen of a screen sharing session doesn't count.
        public var external: Int
    }

    /// Screen sharing's virtual display in "High Performance" mode: vendor 'aapl', model 0x1234, serial 'mvs'. One
    /// can outlive its connection (Cloupi, ~/cloupi/mac/DESIGN.md 41); it never counts as a monitor.
    private static func isSharingDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x6161_706C && CGDisplayModelNumber(id) == 0x1234 && CGDisplaySerialNumber(id) == 0x6D76_7300
    }

    /// nil when CoreGraphics doesn't answer (then nothing freezes).
    public static func displays() -> Displays? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var online: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &online) == .success else { return nil }
        var result = Displays(builtinAwake: false, external: 0)
        for id in ids.prefix(Int(online)) {
            if CGDisplayIsBuiltin(id) != 0 {
                if CGDisplayIsAsleep(id) == 0 { result.builtinAwake = true }
            } else if !isSharingDisplay(id) {
                result.external += 1
            }
        }
        return result
    }

    /// The user's session is being watched through screen sharing (ScreensharingAgent of this user runs). Then the
    /// display isn't switched off (screen sharing wakes it, and switching it off disturbs the connection).
    public static func sessionShared(table: [Int32: ProcessEntry]? = ProcessTable.snapshot()) -> Bool {
        guard let table else { return true }
        let uid = getuid()
        return table.values.contains { $0.uid == uid && $0.name.hasPrefix("Screensharing") }
    }
}

/// Switches the display off with the lid closed. While the helper holds the Mac awake (disablesleep), macOS leaves
/// the built-in display on when the lid closes until the normal display sleep time passes (measured by Cloupi on
/// this Mac, ~/cloupi/mac/DESIGN.md 32): the display glows in the closed Mac and the screen stays unlocked.
public enum LidDisplayPolicy {
    /// Closed for at least this long (not on a short tap of the lid).
    public static let closedDelaySec = 2.0
    /// When something wakes the display again, switch it off again at most this often.
    public static let retrySec = 20.0

    public static func shouldSleepDisplay(lidClosedFor: Double, builtinAwake: Bool, externalDisplays: Int,
                                          sinceLast: Double, sessionShared: Bool) -> Bool {
        lidClosedFor >= closedDelaySec && builtinAwake && externalDisplays == 0 && sinceLast >= retrySec && !sessionShared
    }
}
