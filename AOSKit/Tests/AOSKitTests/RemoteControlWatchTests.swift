@testable import AOSKit
import XCTest

/// Remote Control that stays gone (RemoteControlWatch.swift): reading the transcript, which losses restart, the brakes.
final class RemoteControlWatchTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_794_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func record(_ content: String, _ date: Date, subtype: String = "informational") -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        let obj: [String: Any] = ["type": "system", "subtype": subtype, "content": content, "timestamp": stamp,
                                  "sessionId": "x"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    let unknown = "Remote Control disconnected — the server no longer reports this session — it may have been deleted from another device or app (code 4090)"
    let archived = "Remote Control disconnected — this session was ended or archived from another device or app (code 4090)"
    let takenOver = "Remote Control disconnected — another connection took over this session (usually another device or Claude Code session) — this device is standing down (code 4090)"
    let oauth = "Remote Control disconnected — OAuth token refresh failed — run /login to re-authenticate"

    func testClassifiesTheReasons() {
        func loss(_ s: String) -> RemoteControlLoss {
            guard case .lost(_, let reason)? = RemoteControlPolicy.event(
                try! JSONSerialization.jsonObject(with: Data(record(s, t0).utf8)) as! [String: Any]) else {
                XCTFail("no loss: \(s)"); return .other
            }
            return RemoteControlLoss(reason: reason)
        }
        XCTAssertEqual(loss(unknown), .unknownToServer)
        XCTAssertEqual(loss(archived), .endedByPerson)
        XCTAssertEqual(loss(takenOver), .takenOver)
        XCTAssertEqual(loss(oauth), .other)
        XCTAssertEqual(loss("Remote Control disconnected — Couldn't reconnect to your Remote Control session. Retry, or start a fresh session without --resume. — run /remote-control to reconnect"), .other)
        let active = try! JSONSerialization.jsonObject(with: Data(record("/remote-control is active · Code in CLI or at https://claude.ai/code/session_x", t0, subtype: "bridge_status").utf8)) as! [String: Any]
        XCTAssertEqual(RemoteControlPolicy.event(active), .active(t0))
        XCTAssertNil(RemoteControlPolicy.event(["type": "system", "content": "Compacted", "timestamp": "2026-11-14T20:00:00Z"]))
    }

    func testRestartsAfterTheGraceAndNotForThePersonsOwnLosses() {
        var h = RemoteControlHealth()
        var asked = false
        let up = { asked = true; return true }
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: oauth), now: at(60), apiUp: up, health: &h),
                       "Claude Code often reconnects by itself")
        XCTAssertFalse(asked, "the network isn't asked while nothing else says yes")
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: oauth), now: at(130), apiUp: { false }, health: &h),
                       "offline: a restart wouldn't help")
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: oauth), now: at(130), apiUp: up, health: &h))
        XCTAssertEqual(h.restarts, 1)
        for reason in [archived, takenOver] {
            var fresh = RemoteControlHealth()
            XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: reason), now: at(3600), apiUp: up, health: &fresh))
        }
        var none = RemoteControlHealth()
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: nil, now: at(3600), apiUp: up, health: &none))
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .active(at(0)), now: at(3600), apiUp: up, health: &none))
    }

    func testBrakes() {
        var h = RemoteControlHealth()
        let up = { true }
        // Each restart's new process loses it again: the 2nd after 10 minutes, the 3rd after 30, then no more.
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: oauth), now: at(120), apiUp: up, health: &h))
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(200), reason: oauth), now: at(400), apiUp: up, health: &h))
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(200), reason: oauth), now: at(720), apiUp: up, health: &h))
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(800), reason: oauth), now: at(1800), apiUp: up, health: &h))
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(800), reason: oauth), now: at(2520), apiUp: up, health: &h))
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(2600), reason: oauth), now: at(9000), apiUp: up, health: &h),
                       "three in a row is the limit")
        // Up for 10 minutes: counting starts again.
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .active(at(9000)), now: at(9700), apiUp: up, health: &h))
        XCTAssertEqual(h.restarts, 0)
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(9800), reason: oauth), now: at(9920), apiUp: up, health: &h))

        // The server no longer knows the session: once (the person may really have deleted it).
        var u = RemoteControlHealth()
        XCTAssertTrue(RemoteControlPolicy.shouldRestart(last: .lost(at(0), reason: unknown), now: at(120), apiUp: up, health: &u))
        XCTAssertFalse(RemoteControlPolicy.shouldRestart(last: .lost(at(200), reason: unknown), now: at(5000), apiUp: up, health: &u))
    }

    func testTailReadsOnlyThisProcessAndOnlyWhatIsNew() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let filler = String(repeating: "x", count: 200)
        var text = record(unknown, at(-500)) + "\n"  // an earlier process
        text += "{\"type\":\"user\",\"message\":{\"content\":\"\(filler)\"}}\n"
        text += record("/remote-control is active · x", at(5), subtype: "bridge_status") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        let tail = RemoteControlTail(since: at(0))
        XCTAssertEqual(tail.poll(id: "a", locate: { _ in file }), .active(at(5)))
        let h = try FileHandle(forWritingTo: file)
        h.seekToEndOfFile()
        h.write(Data((record(oauth, at(60)) + "\n" + "{\"type\":\"system\",\"content\":\"Remote Control disconnected — half").utf8))
        XCTAssertEqual(tail.poll(id: "a", locate: { _ in file }), .lost(at(60), reason: "OAuth token refresh failed — run /login to re-authenticate"))
        h.write(Data(" a line\"}\n".utf8))
        h.write(Data((record("/remote-control is active · y", at(90), subtype: "bridge_status") + "\n").utf8))
        try h.close()
        XCTAssertEqual(tail.poll(id: "a", locate: { _ in file }), .active(at(90)), "reconnected by itself")
        XCTAssertEqual(tail.poll(id: "a", locate: { _ in nil }), .active(at(90)), "a missing file keeps what was read")
    }
}
