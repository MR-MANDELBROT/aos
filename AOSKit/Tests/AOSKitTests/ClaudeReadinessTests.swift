import XCTest
@testable import AOSKit

final class ClaudeReadinessTests: XCTestCase {
    func write(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func testTrustInheritedFromAParentFolder() throws {
        let file = try write(["projects": ["/Users/max": ["hasTrustDialogAccepted": true],
                                           "/Users/max/Library/x": ["hasTrustDialogAccepted": false]],
                              "remoteDialogSeen": true])
        let r = ClaudeCode.readiness(folder: URL(fileURLWithPath: "/Users/max/Library/x"), configFile: file)
        XCTAssertTrue(r.trusted)
        XCTAssertTrue(r.remoteControl)
    }

    func testNothingAnsweredYet() throws {
        let file = try write(["projects": ["/Users/max/other": ["hasTrustDialogAccepted": true]]])
        let r = ClaudeCode.readiness(folder: URL(fileURLWithPath: "/Users/max/Library/x"), configFile: file)
        XCTAssertFalse(r.trusted)
        XCTAssertFalse(r.remoteControl)
    }

    func testMissingFile() {
        let r = ClaudeCode.readiness(folder: URL(fileURLWithPath: "/tmp"), configFile: URL(fileURLWithPath: "/nonexistent/claude.json"))
        XCTAssertFalse(r.trusted || r.remoteControl)
    }
}

final class HotspotOriginalTests: XCTestCase {
    let store: [String: Any] = [
        "wifi.network.ssid.Max iPhone": ["PersonalHotspot": true, "AutoJoinDisabled": false,
                                         "__OSSpecific__": ["AutoJoinDisabled": false]],
        "wifi.network.ssid.Old Phone": ["PersonalHotspot": true],
        "wifi.network.ssid.Home": ["AutoJoinDisabled": false],
    ]

    func testOriginalKeepsOnlyHotspotsAndMissingFlags() {
        let o = WiFiPreferences.original(in: store, hotspotMode: "AskToJoin")
        XCTAssertEqual(o.autoJoinDisabled.count, 2)
        XCTAssertEqual(o.autoJoinDisabled["wifi.network.ssid.Max iPhone"], .some(false))
        XCTAssertEqual(o.autoJoinDisabled["wifi.network.ssid.Old Phone"], .some(nil))
        XCTAssertEqual(o.hotspotMode, "AskToJoin")
    }

    func testRestoreWritesBackWhatChanged() {
        let o = WiFiPreferences.original(in: store, hotspotMode: nil)
        // aOS turned auto-join off for the closed lid
        var changed = store
        for (k, e) in WiFiPreferences.settingAutoJoin(in: store, disabled: true) { changed[k] = e }
        let back = WiFiPreferences.restoringAutoJoin(in: changed, original: o)
        XCTAssertEqual(Set(back.keys), ["wifi.network.ssid.Max iPhone", "wifi.network.ssid.Old Phone"])
        let max = back["wifi.network.ssid.Max iPhone"]!
        XCTAssertEqual(max["AutoJoinDisabled"] as? Bool, false)
        XCTAssertEqual((max["__OSSpecific__"] as? [String: Any])?["AutoJoinDisabled"] as? Bool, false)
        XCTAssertTrue(WiFiPreferences.restoringAutoJoin(in: store, original: o).isEmpty)
    }

    func testOriginalRoundTripsThroughJSON() throws {
        let o = WiFiPreferences.original(in: store, hotspotMode: nil)
        let back = try JSONDecoder().decode(WiFiPreferences.Original.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back, o)
    }
}

final class DialogCheckTests: XCTestCase {
    /// The guest runs it with /bin/sh (root's shell over SSH): it must at least parse.
    func testDialogCheckParses() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", Provisioner.dialogCheck]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertTrue(Provisioner.dialogCheck.contains(Provisioner.coreAuthAgent))
    }
}
