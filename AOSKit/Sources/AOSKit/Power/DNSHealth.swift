import Foundation

/// A stuck DNS cache (Docs/DESIGN.md, "Claude offline although the network is there"), ported from Cloupi's wake
/// daemon (~/cloupi/mac/DESIGN.md 34). Decisions only; the app checks, aos-powerd acts.
///
/// What happened: after a network change or a long time offline, the system's way of resolving names (getaddrinfo,
/// dscacheutil, everything through mDNSResponder) stopped resolving exactly `api.anthropic.com`, at once and without
/// asking the network, while other names resolved. All of Claude Code, its Remote Control and the iPhone's Claude app
/// were offline although the Mac had a network; only a restart of the Mac helped (12.10.2026 for 35 minutes,
/// 13.11.2026 for an hour). Tailscale is the first resolver (accept-dns); since that resolver never changes with the
/// network, mDNSResponder probably never drops its cache.
///
/// So: while the network is up, two failed lookups of the API name in a row flush the cache (dscacheutil -flushcache,
/// HUP to mDNSResponder). If that doesn't help within 2 minutes, mDNSResponder is restarted once. At most two flushes
/// and one restart per episode, then one flush an hour.
public enum DNSHealAction: String, Equatable, Sendable {
    case none
    case flush
    case restartResolver
}

public struct DNSHealthState: Equatable, Sendable {
    /// Failed lookups in a row while the network is up.
    public var failStreak = 0
    /// Since when the current episode runs (nil: all fine).
    public var failingSince: Double?
    public var flushesInEpisode = 0
    public var restartsInEpisode = 0
    /// Checks in a row without a network during an episode.
    public var offlineStreak = 0
    /// Brakes across episodes.
    public var lastFlushAt: Double = 0
    public var lastRestartAt: Double = 0

    public init() {}

    mutating func endEpisode() {
        failStreak = 0
        failingSince = nil
        flushesInEpisode = 0
        restartsInEpisode = 0
        offlineStreak = 0
    }
}

public enum DNSHealthPolicy {
    /// The name Claude Code needs, and a name to tell "the network is down" from "only this name fails".
    public static let apiName = "api.anthropic.com"
    public static let controlName = "www.apple.com"
    /// Seconds between checks.
    public static let checkIntervalSec = 60.0
    /// Failed lookups in a row before the first flush.
    public static let failsBeforeFlush = 2
    /// The first two flushes of an episode at least this far apart, later ones hourly.
    public static let flushIntervalSec = 300.0
    public static let lateFlushIntervalSec = 3600.0
    public static let maxEarlyFlushes = 2
    /// How long the failure has to last after a flush before mDNSResponder restarts.
    public static let restartAfterFlushSec = 120.0
    public static let restartIntervalSec = 1800.0
    public static let maxRestartsPerEpisode = 1
    /// Checks in a row without a network that end an episode. One alone doesn't (after a wake, or because the
    /// flush took the stale entries a network probe lived on).
    public static let offlineChecksToReset = 3

    /// Books one check and decides. `netUp`: the Mac has a network (an address, or the control name resolves).
    /// `apiResolves`: the API name resolves the way Claude Code resolves it.
    public static func note(now: Double, netUp: Bool, apiResolves: Bool, state s: inout DNSHealthState) -> DNSHealAction {
        if apiResolves {
            s.endEpisode()
            return .none
        }
        guard netUp else {
            guard s.failingSince != nil else { return .none }
            s.offlineStreak += 1
            if s.offlineStreak >= offlineChecksToReset { s.endEpisode() }
            return .none
        }
        s.offlineStreak = 0
        s.failStreak += 1
        if s.failingSince == nil { s.failingSince = now }
        guard s.failStreak >= failsBeforeFlush else { return .none }
        if s.restartsInEpisode < maxRestartsPerEpisode && s.flushesInEpisode >= 1
            && now - s.lastFlushAt >= restartAfterFlushSec && now - s.lastRestartAt >= restartIntervalSec {
            s.lastRestartAt = now
            s.restartsInEpisode += 1
            return .restartResolver
        }
        let interval = s.flushesInEpisode < maxEarlyFlushes ? flushIntervalSec : lateFlushIntervalSec
        if now - s.lastFlushAt >= interval {
            s.lastFlushAt = now
            s.flushesInEpisode += 1
            return .flush
        }
        return .none
    }

    /// The output of `dscacheutil -q host -a name <name>`: resolved when it has an address line.
    public static func resolved(_ dscacheutilOutput: String) -> Bool {
        dscacheutilOutput.split(whereSeparator: { $0.isNewline }).contains {
            $0.hasPrefix("ip_address:") || $0.hasPrefix("ipv6_address:")
        }
    }

    /// Resolves `name` the way Claude Code does (the system's way through mDNSResponder), within 6 s.
    public static func systemResolves(_ name: String) async -> Bool {
        guard let r = try? await Subprocess.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", name], timeout: 6),
              !r.timedOut else { return false }
        return resolved(String(decoding: r.stdout, as: UTF8.self))
    }
}
