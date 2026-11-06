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

final class BitwardenStaysUnlockedTests: XCTestCase {
    func testNeverLockIgnoresSleepAndRestart() {
        let unlocked = Date(timeIntervalSince1970: 1_000_000)
        let s = BitwardenSession(key: "k", unlocked: unlocked, until: BitwardenVault.until(unlocked: unlocked, hours: 0))
        XCTAssertTrue(s.staysUnlocked)
        XCTAssertTrue(s.isValid(now: unlocked.addingTimeInterval(86_400 * 30), lastSleep: unlocked.addingTimeInterval(60),
                                boot: unlocked.addingTimeInterval(120)))
    }

    func testTimedLockStillLocksOnSleep() {
        let unlocked = Date(timeIntervalSince1970: 1_000_000)
        let s = BitwardenSession(key: "k", unlocked: unlocked, until: BitwardenVault.until(unlocked: unlocked, hours: 8))
        XCTAssertFalse(s.staysUnlocked)
        XCTAssertFalse(s.isValid(now: unlocked.addingTimeInterval(600), lastSleep: unlocked.addingTimeInterval(60), boot: nil))
    }

    func testOldSettingsKeepTheirChoiceAndZeroIsAllowed() throws {
        let s = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"bitwardenLockHours": 0}"#.utf8))
        XCTAssertEqual(s.bitwardenLockHours, 0)
        XCTAssertEqual(AgentSettings().bitwardenLockHours, 0)
    }
}

final class StaySignedInTests: XCTestCase {
    func testPatternsFromWhatPeopleType() {
        XCTAssertEqual(StaySignedIn.pattern(from: "github.com"), "[*.]github.com")
        XCTAssertEqual(StaySignedIn.pattern(from: " https://www.GitHub.com/login?x=1 "), "[*.]github.com")
        XCTAssertEqual(StaySignedIn.pattern(from: "*.tum.de"), "[*.]tum.de")
        XCTAssertEqual(StaySignedIn.pattern(from: "[*.]campus.tum.de"), "[*.]campus.tum.de")
        XCTAssertEqual(StaySignedIn.pattern(from: "localhost:8080"), nil)
        XCTAssertEqual(StaySignedIn.pattern(from: "github"), nil)
        XCTAssertEqual(StaySignedIn.pattern(from: "evil.com, other.com"), nil)
        XCTAssertEqual(StaySignedIn.pattern(from: "192.168.1.1"), nil)
        XCTAssertEqual(StaySignedIn.domain(of: "[*.]github.com"), "github.com")
    }
}

final class ExchangeBlocklistTests: XCTestCase {
    let home = "/Users/max"
    func blocked(_ path: String) -> Bool { Exchange.forbidden(URL(fileURLWithPath: path), home: home) != nil }

    func testSecretsAndAOSDataStayOut() {
        XCTAssertTrue(blocked("/Users/max/Library/Application Support/aOS/Bitwarden/data.json"))
        XCTAssertTrue(blocked("/Users/max/Library/Application Support/AOS/Keys/maintenance"))
        XCTAssertTrue(blocked("/Users/max/.SSH/id_ed25519"))
        XCTAssertTrue(blocked("/Users/max/Library/Application Support/Bitwarden CLI/data.json"))
        XCTAssertTrue(blocked("/Users/max/Library/Application Support/Google/Chrome/Default/Login Data"))
        XCTAssertTrue(blocked("/Users/max/Library/Application Support"))   // holds aOS's data
        XCTAssertTrue(blocked("/Users/max/Library"))
        XCTAssertTrue(blocked("/Users/max"))
        XCTAssertFalse(blocked("/Users/max/Documents/report.pdf"))
        XCTAssertFalse(blocked("/Users/max/Library/Application Support/Some App/export.csv"))
    }
}

final class RunAsTests: XCTestCase {
    func testOwnUserWorksAndAnotherUserIsRefusedWithoutRoot() throws {
        let me = Subprocess.RunAs(uid: getuid(), gid: getgid())
        let r = try Subprocess.runBlocking("/usr/bin/id", ["-u"], environment: [:], runAs: me, timeout: 10)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "\(getuid())")
        if getuid() != 0 {
            // Without root the child can't become another user: it ends before the program runs.
            let nobody = Subprocess.RunAs(uid: 4_294_967_294, gid: 4_294_967_294)
            let refused = try Subprocess.runBlocking("/usr/bin/id", ["-u"], environment: [:], runAs: nobody, timeout: 10)
            XCTAssertEqual(refused.status, 126)
            XCTAssertTrue(refused.stdout.isEmpty)
        }
        // Descriptor 3 (the secret) reaches the program; nothing else above 2 does.
        let fds = try Subprocess.runBlocking("/bin/sh", ["-c", "cat <&3; ls /dev/fd | tr '\\n' ' '"], environment: [:],
                                             secret: Data("s3cret".utf8), runAs: me, timeout: 10)
        let text = String(decoding: fds.stdout, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("s3cret"), text)
    }
}
