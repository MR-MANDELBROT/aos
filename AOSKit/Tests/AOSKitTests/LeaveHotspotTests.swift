@testable import AOSKit
import XCTest

final class LeaveHotspotTests: XCTestCase {
    func testCandidatesSkipHotspots() {
        let preferred = ["Max iPhone", "FRITZ!Box 7590", "eduroam", "Cafe"]
        XCTAssertEqual(NetworkCarePolicy.leaveCandidates(preferred: preferred, hotspots: ["Max iPhone"]),
                       ["FRITZ!Box 7590", "eduroam", "Cafe"])
        // Named like an iPhone counts as a hotspot even if the helper didn't list it
        XCTAssertEqual(NetworkCarePolicy.leaveCandidates(preferred: ["Lenas iPhone", "Home"], hotspots: []), ["Home"])
    }

    func testTargetIsTheFirstStrongKnownNetwork() {
        let candidates = ["Home", "eduroam", "Cafe"]
        var m = NetworkMemory()
        XCTAssertEqual(NetworkCarePolicy.leaveTarget(signal: ["eduroam": -60, "Cafe": -50], candidates: candidates,
                                                     memory: m, now: 1000), "eduroam")
        // Too weak: stay on the hotspot
        XCTAssertNil(NetworkCarePolicy.leaveTarget(signal: ["Home": -85], candidates: candidates, memory: m, now: 1000))
        // A network whose join just failed rests
        m.noteJoin("Home", ok: false, visible: true, now: 990)
        XCTAssertEqual(NetworkCarePolicy.leaveTarget(signal: ["Home": -55, "Cafe": -70], candidates: candidates,
                                                     memory: m, now: 1000), "Cafe")
    }

    func testSettingDefaultsOn() throws {
        let s = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(s.leaveHotspot)
    }
}
