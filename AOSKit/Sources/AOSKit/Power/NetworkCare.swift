import Foundation

// Looking after the network while the lid is closed (Docs/DESIGN.md, "Staying awake, freezing and the hotspot").
// Ported in a lighter form from Cloupi's network recovery (~/cloupi/mac/DESIGN.md 31, 36, 37): the Mac keeps
// searching while it is offline and joins what it finds. A known Wi-Fi network beats the iPhone hotspot; the hotspot
// is joined only while it broadcasts, which it does once the user switched it on (a dormant iPhone hotspot sends no
// network name, and macOS may not wake it with the screen locked: "AutoHotspot not allowed during dark wake").
// Names of networks are hidden from processes without location access (root included), but a scan for a given
// name still finds it, and macOS's list of preferred networks has the names (verified as a normal user).

/// What happens next while offline.
public enum NetworkStep: String, Equatable, Sendable {
    case none
    /// Look for known networks by name and join the best one in range.
    case scan
    /// airportd keeps refusing a network it can see (its deny list): restarting it clears the list.
    case restartAirportd
    /// Nothing turns up for a while: Wi-Fi off and on resets macOS's own auto-join back-off.
    case cycleWiFi
}

/// What network care remembers between ticks. Times are seconds since 1970.
public struct NetworkMemory: Equatable, Sendable {
    /// Since when the Mac has had no usable address (nil: online).
    public var offlineSince: Double?
    public var lastScanAt: Double = 0
    /// Joins that failed although the scan saw the network, in this outage.
    public var visibleFailures = 0
    /// Per network (lowercased name): when its last join failed and how often in a row.
    public var failedAt: [String: Double] = [:]
    public var failures: [String: Int] = [:]
    /// Brakes over outages.
    public var lastAirportdAt: Double = 0
    public var lastCycleAt: Double = 0
    public var cyclesInOutage = 0

    public init() {}

    public mutating func noteOnline() {
        offlineSince = nil
        lastScanAt = 0
        visibleFailures = 0
        cyclesInOutage = 0
        failedAt = [:]
        failures = [:]
    }

    public mutating func noteOffline(now: Double) {
        if offlineSince == nil { offlineSince = now }
    }

    /// Waking up starts the count again (sleep isn't an outage).
    public mutating func noteWake(now: Double) {
        if offlineSince != nil { offlineSince = now }
        lastScanAt = 0
    }

    public mutating func noteJoin(_ name: String, ok: Bool, visible: Bool, now: Double) {
        let key = name.lowercased()
        if ok {
            failedAt[key] = nil
            failures[key] = nil
        } else {
            failedAt[key] = now
            failures[key, default: 0] += 1
            if visible { visibleFailures += 1 }
        }
    }
}

public enum NetworkCarePolicy {
    /// A short gap heals itself (roaming, a router restart).
    public static let firstLookAfterSec = 20.0
    /// A scan for known names costs a few seconds of radio; 45 s finds a hotspot that was just switched on in
    /// under a minute (Cloupi 37).
    public static let scanIntervalSec = 45.0
    /// After airportd's restart or Wi-Fi off and on, macOS gets this long to reconnect by itself.
    public static let settleSec = 60.0
    public static let airportdAfterVisibleFailures = 2
    public static let airportdIntervalSec = 600.0
    /// Wi-Fi off and on after 4 minutes without a network, then after 10, 20, 40, at most 60 minutes.
    public static let cycleAfterSec = 240.0
    public static let cycleBaseIntervalSec = 600.0
    public static let cycleMaxIntervalSec = 3600.0
    /// How many known networks a scan looks for (the hotspots first, then macOS's order).
    public static let scanLimit = 12

    public static func cycleInterval(afterCycles n: Int) -> Double {
        guard n > 0 else { return cycleBaseIntervalSec }
        return min(cycleMaxIntervalSec, cycleBaseIntervalSec * pow(2, Double(min(n - 1, 8))))
    }

    /// The next step. Nothing while Wi-Fi is off (the user's decision) or the Mac has an address.
    public static func next(now: Double, wifiOn: Bool, hasIPv4: Bool, memory m: NetworkMemory) -> NetworkStep {
        guard wifiOn, !hasIPv4, let since = m.offlineSince else { return .none }
        let off = now - since
        guard off >= firstLookAfterSec else { return .none }
        if now - max(m.lastAirportdAt, m.lastCycleAt) < settleSec { return .none }
        if m.visibleFailures >= airportdAfterVisibleFailures && now - m.lastAirportdAt >= airportdIntervalSec {
            return .restartAirportd
        }
        if off >= cycleAfterSec && m.lastScanAt > 0
            && now - m.lastCycleAt >= cycleInterval(afterCycles: m.cyclesInOutage) {
            return .cycleWiFi
        }
        if now - m.lastScanAt >= scanIntervalSec { return .scan }
        return .none
    }

    /// A network whose join just failed rests: 45 s, then 3 min, then 10 min (it may be on macOS's deny list).
    public static func resting(_ name: String, memory m: NetworkMemory, now: Double) -> Bool {
        let key = name.lowercased()
        guard let at = m.failedAt[key] else { return false }
        let n = m.failures[key] ?? 1
        let pause: Double = n <= 1 ? 45 : (n == 2 ? 180 : 600)
        return now - at < pause && now >= at
    }

    /// The names to look for: the user's hotspots first, then the known networks in macOS's order.
    public static func scanCandidates(preferred: [String], hotspots: [String], limit: Int = scanLimit) -> [String] {
        var out: [String] = []
        func add(_ n: String) {
            guard out.count < limit, !n.isEmpty, !out.contains(where: { $0.lowercased() == n.lowercased() }) else { return }
            out.append(n)
        }
        hotspots.forEach(add)
        preferred.forEach(add)
        return out
    }

    /// What to join after a scan: the first known Wi-Fi network in range in macOS's order, else a hotspot in range.
    /// Networks that rest after a failed join are left out.
    public static func joinTarget(visible: Set<String>, preferred: [String], hotspots: [String],
                                  memory m: NetworkMemory, now: Double) -> String? {
        let seen = Set(visible.map { $0.lowercased() })
        let hotspotSet = Set(hotspots.map { $0.lowercased() })
        for name in preferred where !hotspotSet.contains(name.lowercased()) && seen.contains(name.lowercased()) {
            if !resting(name, memory: m, now: now) { return name }
        }
        for name in hotspots where seen.contains(name.lowercased()) {
            if !resting(name, memory: m, now: now) { return name }
        }
        return nil
    }

    /// The user's hotspots: what the helper read from macOS's known networks (marked Personal Hotspot), else the
    /// preferred networks named like an iPhone or iPad.
    public static func hotspotNames(preferred: [String], fromHelper: [String]?) -> [String] {
        if let names = fromHelper, !names.isEmpty {
            // In macOS's order where possible
            let known = preferred.filter { p in names.contains { $0.lowercased() == p.lowercased() } }
            return known + names.filter { n in !known.contains { $0.lowercased() == n.lowercased() } }
        }
        return preferred.filter(looksLikeHotspot)
    }

    public static func looksLikeHotspot(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("iphone") || n.contains("ipad")
    }

    /// `networksetup -listpreferredwirelessnetworks en0`: a header line, then one tab-indented name per line.
    public static func parsePreferred(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("\t") else { return nil }
            let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : String(line.dropFirst())
        }
    }

    /// A usable IPv4 address: not empty and not self-assigned (169.254.x.x, DHCP failed).
    public static func usableIPv4(_ text: String) -> Bool {
        let ip = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !ip.isEmpty && !ip.hasPrefix("169.254.")
    }

    /// iPhone hotspots hand out 172.20.10.2 to .14 (.1 is the iPhone).
    public static func isHotspotAddress(_ ip: String) -> Bool {
        let s = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "172.20.10."
        guard s.hasPrefix(prefix), let last = Int(s.dropFirst(prefix.count)) else { return false }
        return (1...14).contains(last)
    }

    /// The primary interface is a real network other than Wi-Fi (Ethernet, a phone over USB), not a VPN tunnel,
    /// a bridge (the workspace's NAT) or loopback.
    public static func countsAsOtherNetwork(_ primary: String, wifi: String) -> Bool {
        guard !primary.isEmpty, primary != wifi else { return false }
        return !["utun", "ipsec", "ppp", "bridge", "lo", "gif", "stf", "awdl", "llw", "anpi", "ap"]
            .contains { primary.hasPrefix($0) }
    }

    /// A network name aOS passes on to networksetup: 1 to 32 bytes, no control characters.
    public static func validNetworkName(_ name: String) -> Bool {
        let bytes = name.utf8.count
        return bytes >= 1 && bytes <= 32 && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
