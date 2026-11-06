import CoreWLAN
import Darwin
import Foundation
import ObjectiveC
import SystemConfiguration

// How macOS 27 keeps the two hotspot settings, found on MacBookPro18,3 with macOS 27.0 (26A428) as a normal user
// (Docs/DESIGN.md, "Staying awake, freezing and the hotspot"):
// - Auto-join per network: CoreWiFi's known network profiles, property "AutoJoinDisabled"
//   (CWFNetworkProfilePropertyAutoJoinDisabledKey), stored by airportd in the store "com.apple.wifi.known-networks"
//   (CWFKnownNetworksStoreIdentifier), the file /Library/Preferences/com.apple.wifi.known-networks.plist (root, 0600),
//   entries "wifi.network.ssid.<name>"; the user's own hotspots carry "PersonalHotspot".
// - "Ask to join hotspots": key "AutoHotspotMode" with "AskToJoin", "Automatic" or "Never" in airportd's global
//   configuration (CoreWLAN's globalConfiguration(), SystemConfiguration's com.apple.airport.preferences.plist).
//   CoreWLAN numbers them 1, 2, 3 (schemaStringForAutoHotspotMode).
// Reading both works without any privilege through airportd (names come back hidden without location access, the
// flags don't). Changing them through airportd needs Apple's private entitlements (its handler for "set auto hotspot
// mode" requires com.apple.wifi.auto-hotspot; known networks need com.apple.private.corewifi); only Apple's own apps
// have them. So the helper changes the stores as root and restarts airportd, and the result is read back here.

public enum WiFiPreferences {
    public static let knownNetworksDomain = "com.apple.wifi.known-networks"
    public static let airportPreferencesID = "com.apple.airport.preferences.plist"
    public static let autoJoinDisabledKey = "AutoJoinDisabled"
    public static let personalHotspotKey = "PersonalHotspot"
    public static let osSpecificKey = "__OSSpecific__"
    public static let autoHotspotModeKey = "AutoHotspotMode"
    public static let ssidKeyPrefix = "wifi.network.ssid."

    /// "Ask to join hotspots" as CoreWLAN numbers it.
    public enum HotspotMode: Int, Codable, Sendable, CaseIterable {
        case askToJoin = 1
        case automatic = 2
        case never = 3

        public var schemaString: String {
            switch self {
            case .askToJoin: return "AskToJoin"
            case .automatic: return "Automatic"
            case .never: return "Never"
            }
        }

        public init?(schemaString: String) {
            guard let m = Self.allCases.first(where: { $0.schemaString == schemaString }) else { return nil }
            self = m
        }
    }

    public static func hotspotMode(for join: HotspotJoin) -> HotspotMode { join == .automatic ? .automatic : .never }
    public static func autoJoinDisabled(for join: HotspotJoin) -> Bool { join == .manual }

    public struct HotspotEntry: Equatable, Sendable {
        public var key: String
        public var name: String
        public var autoJoinDisabled: Bool
    }

    private static func flag(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func isPersonalHotspot(_ entry: [String: Any]) -> Bool {
        flag(entry[personalHotspotKey]) ?? flag((entry[osSpecificKey] as? [String: Any])?[personalHotspotKey]) ?? false
    }

    /// The network name of a known-networks entry: its SSID bytes as text, else what follows the key's prefix.
    public static func name(key: String, entry: [String: Any]) -> String {
        if let data = entry["SSID"] as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        return key.hasPrefix(ssidKeyPrefix) ? String(key.dropFirst(ssidKeyPrefix.count)) : key
    }

    /// The user's own Personal Hotspots in the known networks store.
    public static func personalHotspots(in store: [String: Any]) -> [HotspotEntry] {
        store.compactMap { key, value -> HotspotEntry? in
            guard let entry = value as? [String: Any], isPersonalHotspot(entry) else { return nil }
            return HotspotEntry(key: key, name: name(key: key, entry: entry),
                                autoJoinDisabled: flag(entry[autoJoinDisabledKey]) ?? false)
        }.sorted { $0.key < $1.key }
    }

    /// The entries to write so every Personal Hotspot carries `disabled`; entries that already do aren't returned.
    /// The flag sits at the top of an entry; where it also appears in the OS-specific part, that copy follows.
    public static func settingAutoJoin(in store: [String: Any], disabled: Bool) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (key, value) in store {
            guard var entry = value as? [String: Any], isPersonalHotspot(entry) else { continue }
            var changed = false
            if flag(entry[autoJoinDisabledKey]) != disabled {
                entry[autoJoinDisabledKey] = disabled
                changed = true
            }
            if var os = entry[osSpecificKey] as? [String: Any], let current = flag(os[autoJoinDisabledKey]), current != disabled {
                os[autoJoinDisabledKey] = disabled
                entry[osSpecificKey] = os
                changed = true
            }
            if changed { out[key] = entry }
        }
        return out
    }
}

/// The two hotspot settings as macOS reports them now (read through airportd; works for a normal user).
public struct WiFiState: Codable, Equatable, Sendable {
    public var hotspotMode: WiFiPreferences.HotspotMode?
    /// Known networks macOS marks as the user's own Personal Hotspot.
    public var personalHotspots: Int?
    /// Of those, how many have auto-join off.
    public var autoJoinOff: Int?

    public init(hotspotMode: WiFiPreferences.HotspotMode? = nil, personalHotspots: Int? = nil, autoJoinOff: Int? = nil) {
        self.hotspotMode = hotspotMode
        self.personalHotspots = personalHotspots
        self.autoJoinOff = autoJoinOff
    }

    /// Does macOS do what the choice says? (No hotspot known yet counts as fine for auto-join.)
    public func matches(_ join: HotspotJoin) -> Bool {
        hotspotMatches(join) && autoJoinMatches(join)
    }

    public func hotspotMatches(_ join: HotspotJoin) -> Bool { hotspotMode == WiFiPreferences.hotspotMode(for: join) }

    public func autoJoinMatches(_ join: HotspotJoin) -> Bool {
        guard let total = personalHotspots, let off = autoJoinOff else { return false }
        return join == .manual ? off == total : off == 0
    }
}

/// Wi-Fi calls are synchronous XPC calls to airportd without a deadline of their own; if airportd hangs, so does the
/// caller. They run one after another on a queue of their own with a deadline; while one still hangs, the next fails
/// at once instead of queueing up (Cloupi's lesson, ~/cloupi/mac/DESIGN.md 36.3).
public enum WiFiRadio {
    public static let interfaceName = "en0"
    private static let queue = DispatchQueue(label: "dev.marquart.aos.wifi")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var busy = false

    public static func withDeadline<T>(_ seconds: Double, _ work: @escaping () -> T) -> T? {
        lock.lock()
        if busy { lock.unlock(); return nil }
        busy = true
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        queue.async {
            box.set(work())
            lock.lock(); busy = false; lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.get()
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func interface() -> CWInterface? { CWWiFiClient.shared().interface(withName: interfaceName) }

    /// Wi-Fi switched on? nil when airportd doesn't answer in time.
    public static func powerOn(timeout: Double = 4) -> Bool? {
        withDeadline(timeout) { interface()?.powerOn() ?? false }
    }

    /// Which of the names are in range (a scan by name finds networks even when their names are hidden from this
    /// process). nil when the scan fails (Wi-Fi off, airportd busy). Blocks for up to `budget` seconds.
    public static func inRange(_ names: [String], budget: Double = 25) -> Set<String>? {
        withDeadline(budget + 10) { () -> Set<String>? in
            guard let i = interface(), i.powerOn() else { return nil }
            let start = Date()
            var found = Set<String>()
            var anyOK = false
            for name in names {
                if Date().timeIntervalSince(start) > budget { break }
                if let result = try? i.scanForNetworks(withName: name) {
                    anyOK = true
                    if !result.isEmpty { found.insert(name) }
                }
            }
            return anyOK ? found : nil
        } ?? nil
    }

    /// Online some other way (an Ethernet adapter): the system's primary IPv4 interface is a real one other than
    /// Wi-Fi. VPN tunnels and bridges don't count (their addresses stay when the network is gone).
    public static func onlineElsewhere() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "aOS" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return false }
        return NetworkCarePolicy.countsAsOtherNetwork(primary, wifi: interfaceName)
    }

    /// The IPv4 address of en0 ("" without one); a self-assigned 169.254 address counts as none. No XPC.
    public static func ipv4(_ name: String = interfaceName) -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "" }
        defer { freeifaddrs(head) }
        var found = ""
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if NetworkCarePolicy.usableIPv4(ip) { found = ip }
            }
        }
        return found
    }

    // MARK: Reading the hotspot settings (private interfaces, looked up at run time; nothing is changed here)

    /// The current "Ask to join hotspots" and the auto-join flags of the user's hotspots. Blocking; nil parts when
    /// macOS doesn't answer or the interfaces are missing.
    public static func readState(timeout: Double = 8) -> WiFiState? {
        withDeadline(timeout) { readStateNow() }
    }

    private static func readStateNow() -> WiFiState {
        var state = WiFiState()
        typealias GetMode = @convention(c) () -> Int
        if let wlan = dlopen("/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN", RTLD_NOW),
           let symbol = dlsym(wlan, "CWGetAutoHotspotMode") {
            state.hotspotMode = WiFiPreferences.HotspotMode(rawValue: unsafeBitCast(symbol, to: GetMode.self)())
        }
        _ = dlopen("/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi", RTLD_NOW)
        guard let cls = objc_getClass("CWFInterface") as? NSObject.Type else { return state }
        let iface = cls.init()
        let activate = NSSelectorFromString("activate")
        let list = NSSelectorFromString("knownNetworkProfilesWithProperties:")
        guard iface.responds(to: activate), iface.responds(to: list) else { return state }
        iface.perform(activate)
        defer { if iface.responds(to: NSSelectorFromString("invalidate")) { iface.perform(NSSelectorFromString("invalidate")) } }
        let known = iface.perform(list, with: nil)?.takeUnretainedValue()
        let profiles: [NSObject] = (known as? [NSObject]) ?? ((known as? NSSet)?.allObjects as? [NSObject]) ?? []
        var hotspots = 0, off = 0
        for p in profiles where boolValue(p, "isPersonalHotspot") == true {
            hotspots += 1
            if boolValue(p, "isAutoJoinDisabled") == true { off += 1 }
        }
        state.personalHotspots = hotspots
        state.autoJoinOff = off
        return state
    }

    private static func boolValue(_ object: NSObject, _ selectorName: String) -> Bool? {
        typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel), let imp = class_getMethodImplementation(type(of: object), sel) else { return nil }
        return unsafeBitCast(imp, to: GetBool.self)(object, sel)
    }
}
