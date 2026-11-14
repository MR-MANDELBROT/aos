@testable import AOSKit
import XCTest

/// A stuck DNS cache (DNSHealth.swift): when to flush, when to restart mDNSResponder, when an episode ends.
final class DNSHealthTests: XCTestCase {
    /// Seconds since a moment in November 2026 (the brakes compare with times since 1970).
    func step(_ s: inout DNSHealthState, _ t: Double, net: Bool = true, api: Bool = false) -> DNSHealAction {
        DNSHealthPolicy.note(now: 1_794_000_000 + t, netUp: net, apiResolves: api, state: &s)
    }

    func testFlushesAfterTwoFailuresThenRestartsOnce() {
        var s = DNSHealthState()
        XCTAssertEqual(step(&s, 1000), .none, "one failure can be a hiccup")
        XCTAssertEqual(step(&s, 1060), .flush)
        XCTAssertEqual(step(&s, 1120), .none, "too soon after the flush for the restart")
        XCTAssertEqual(step(&s, 1180), .restartResolver, "2 minutes after the flush")
        XCTAssertEqual(step(&s, 1240), .none)
        XCTAssertEqual(step(&s, 1360), .flush, "the second flush 5 minutes after the first")
        XCTAssertEqual(step(&s, 1420), .none, "only one restart per episode")
        XCTAssertEqual(step(&s, 1660), .none, "later flushes only hourly")
        XCTAssertEqual(step(&s, 1360 + 3600), .flush)
        XCTAssertEqual(s.flushesInEpisode, 3)
        XCTAssertEqual(s.restartsInEpisode, 1)
    }

    func testResolvingAgainEndsTheEpisode() {
        var s = DNSHealthState()
        _ = step(&s, 0); _ = step(&s, 60)
        XCTAssertNotNil(s.failingSince)
        XCTAssertEqual(step(&s, 120, api: true), .none)
        XCTAssertNil(s.failingSince)
        XCTAssertEqual(s.flushesInEpisode, 0)
        // A new episode starts from scratch, but flushes keep their distance across episodes.
        XCTAssertEqual(step(&s, 180), .none)
        XCTAssertEqual(step(&s, 240), .none, "the last flush was only 3 minutes ago")
        XCTAssertEqual(step(&s, 400), .flush)
    }

    func testOfflineDoesNothingAndEndsAnEpisodeOnlyAfterThreeChecks() {
        var s = DNSHealthState()
        XCTAssertEqual(step(&s, 0, net: false), .none)
        XCTAssertNil(s.failingSince, "no network, no episode: nothing to repair")
        _ = step(&s, 60); _ = step(&s, 120)
        XCTAssertEqual(step(&s, 180, net: false), .none)
        XCTAssertNotNil(s.failingSince, "one offline check (after a wake, after the flush) doesn't end it")
        _ = step(&s, 240, net: false); _ = step(&s, 300, net: false)
        XCTAssertEqual(step(&s, 360, net: false), .none)
        XCTAssertNil(s.failingSince, "three in a row do")
    }

    func testReadsDscacheutil() {
        XCTAssertTrue(DNSHealthPolicy.resolved("name: api.anthropic.com\nip_address: 160.79.104.10\n"))
        XCTAssertTrue(DNSHealthPolicy.resolved("name: api.anthropic.com\nipv6_address: 2607:6bc0::10\n"))
        XCTAssertFalse(DNSHealthPolicy.resolved(""))
        XCTAssertFalse(DNSHealthPolicy.resolved("name: api.anthropic.com\n"))
    }

    func testResolvesARealName() async {
        // This Mac resolves itself; a name under .invalid never resolves.
        let ok = await DNSHealthPolicy.systemResolves("localhost")
        let bad = await DNSHealthPolicy.systemResolves("aos-test.invalid")
        XCTAssertTrue(ok)
        XCTAssertFalse(bad)
    }

    func testTellsWhyAHostIsUnreachable() {
        XCTAssertEqual(Network.probe(host: "aos-test.invalid", port: 443, timeout: 2), .noName)
        XCTAssertEqual(Network.probe(host: "127.0.0.1", port: 1, timeout: 2), .noConnection)
    }
}
