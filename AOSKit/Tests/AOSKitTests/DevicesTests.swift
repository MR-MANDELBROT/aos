@testable import AOSKit
import XCTest

/// Installing apps on the iPhone: the worker's report, signing choices, jobs, the tools and the phone's view.
final class DevicesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The worker's report

    /// What App/Resources/aos-devices-worker.py writes (its field names and date format).
    let workerReport = """
    {
     "version": 1, "pid": 4242, "state": "connected", "message": "",
     "device": {"udid": "00008140-00111D6801EB001C", "name": "iPhone von Max", "ios": "27.2",
                "address": "100.111.57.16", "addressName": "iphone173-1"},
     "since": "2026-11-11T00:07:06Z", "network": "cellular", "lastHeartbeat": "2026-11-11T00:30:00Z",
     "history": [{"from": "2026-11-10T22:00:00Z", "seconds": 4210, "reason": "no answer"}],
     "jobs": [{"id": "A", "name": "Tunnel Test", "bundleId": "dev.marquart.tunneltest", "version": "1.0 (2)",
               "source": "Claude Code", "state": "done", "created": "2026-11-11T00:25:00Z",
               "finished": "2026-11-11T00:25:15Z", "seconds": 3.0, "network": "cellular"},
              {"id": "B", "name": "Broken", "bundleId": "dev.x.broken", "state": "failed",
               "created": "2026-11-11T00:20:00Z", "message": "ApplicationVerificationFailed"},
              {"id": "C", "name": "Later", "bundleId": "dev.x.later", "state": "queued", "created": "2026-11-11T00:26:00Z"}],
     "updated": "2026-11-11T00:30:01Z"
    }
    """

    func testDecodesTheWorkersReport() throws {
        let status = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(workerReport.utf8))
        XCTAssertEqual(status.state, .connected)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.device?.name, "iPhone von Max")
        XCTAssertEqual(status.device?.address, "100.111.57.16")
        XCTAssertEqual(status.network, "cellular")
        XCTAssertEqual(status.history.first?.seconds, 4210)
        XCTAssertEqual(status.jobs.map(\.state), [.done, .failed, .queued])
        XCTAssertEqual(status.jobs[0].seconds, 3.0)
        XCTAssertEqual(status.jobs[1].message, "ApplicationVerificationFailed")
        XCTAssertEqual(status.since, ISO8601DateFormatter().date(from: "2026-11-11T00:07:06Z"))
    }

    func testUnknownStatesDontBreakTheReport() throws {
        let json = #"{"state": "somethingNew", "jobs": [{"id": "X", "name": "N", "bundleId": "b", "state": "weird", "created": "2026-11-11T00:00:00Z"}]}"#
        let status = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.jobs.first?.state, .unknown)
        XCTAssertFalse(status.isFresh(alive: { _ in true }), "no pid: not a running worker")
    }

    func testOfflineIsATunnelThatWaits() throws {
        let report = workerReport.replacingOccurrences(of: #""network": "cellular", "lastHeartbeat""#,
                                                       with: #""network": "offline", "lastHeartbeat""#)
        let status = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(report.utf8))
        XCTAssertTrue(status.isConnected, "the tunnel is still up")
        XCTAssertTrue(status.isOffline)
        let cellular = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(workerReport.utf8))
        XCTAssertFalse(cellular.isOffline)
    }

    func testFreshOnlyWhileTheWorkerLives() throws {
        let status = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(workerReport.utf8))
        XCTAssertTrue(status.isFresh(alive: { $0 == 4242 }))
        XCTAssertFalse(status.isFresh(alive: { _ in false }))
    }

    // MARK: Signing

    func profile(_ appID: String, devices: [String] = ["UDID-1"], expires days: Double = 300,
                 certs: [String] = ["AAAA"], keychain: Bool = true, name: String? = nil) -> ProvisioningProfile {
        ProvisioningProfile(url: URL(fileURLWithPath: "/tmp/\(appID).mobileprovision"), name: name ?? appID,
                            uuid: UUID().uuidString, teamID: "TEAM", applicationIdentifier: appID,
                            expiration: Date().addingTimeInterval(days * 86400), devices: devices, allDevices: false,
                            platforms: ["iOS"], getTaskAllow: true, hasKeychainGroups: keychain,
                            certificateFingerprints: certs)
    }

    func testProfilesCoverTheirBundleIDs() {
        XCTAssertTrue(profile("TEAM.*").covers(bundleID: "anything.at.all"))
        XCTAssertTrue(profile("TEAM.dev.marquart.*").covers(bundleID: "dev.marquart.tunneltest"))
        XCTAssertFalse(profile("TEAM.dev.marquart.*").covers(bundleID: "dev.other.app"))
        XCTAssertTrue(profile("TEAM.dev.marquart.aos").covers(bundleID: "dev.marquart.aos"))
        XCTAssertFalse(profile("TEAM.dev.marquart.aos").covers(bundleID: "dev.marquart.aos.widgets"))
        XCTAssertFalse(profile("OTHER.*").covers(bundleID: "dev.marquart.aos"))
        XCTAssertTrue(profile("TEAM.*", devices: ["udid-1"]).covers(device: "UDID-1"))
        XCTAssertFalse(profile("TEAM.*", devices: ["UDID-2"]).covers(device: "UDID-1"))
    }

    func testChoosesAnExactProfileBeforeAWildcardAndSkipsExpiredOnes() throws {
        let identity = SigningIdentity(fingerprint: "AAAA", name: "Apple Development: Test")
        let signer = IOSAppSigner(profiles: [profile("TEAM.*", expires: 500), profile("TEAM.dev.x.app", expires: 100),
                                             profile("TEAM.dev.x.app", expires: -1, name: "expired")],
                                  identities: [identity])
        let (chosen, who) = try signer.choose(bundleID: "dev.x.app", udid: "UDID-1")
        XCTAssertEqual(chosen.applicationIdentifier, "TEAM.dev.x.app")
        XCTAssertNotEqual(chosen.name, "expired")
        XCTAssertEqual(who, identity)
        let (other, _) = try signer.choose(bundleID: "dev.y.app", udid: "UDID-1")
        XCTAssertEqual(other.applicationIdentifier, "TEAM.*")
    }

    func testSaysWhyItCantSign() {
        let signer = IOSAppSigner(profiles: [profile("TEAM.*", devices: ["UDID-2"])],
                                  identities: [SigningIdentity(fingerprint: "AAAA", name: "x")])
        XCTAssertThrowsError(try signer.choose(bundleID: "dev.x", udid: "UDID-1")) { error in
            XCTAssertEqual(error as? IOSAppSigner.SignError, .noProfile(bundleID: "dev.x", udid: "UDID-1"))
        }
        let noKey = IOSAppSigner(profiles: [profile("TEAM.*", certs: ["BBBB"], name: "Team")],
                                 identities: [SigningIdentity(fingerprint: "AAAA", name: "x")])
        XCTAssertThrowsError(try noKey.choose(bundleID: "dev.x", udid: "UDID-1")) { error in
            XCTAssertEqual(error as? IOSAppSigner.SignError, .noIdentity(profile: "Team"))
        }
    }

    func testEntitlementsOfADevelopmentBuild() {
        let e = IOSAppSigner.entitlements(bundleID: "dev.x.app", profile: profile("TEAM.*"))
        XCTAssertEqual(e["application-identifier"] as? String, "TEAM.dev.x.app")
        XCTAssertEqual(e["com.apple.developer.team-identifier"] as? String, "TEAM")
        XCTAssertEqual(e["get-task-allow"] as? Bool, true)
        XCTAssertEqual(e["keychain-access-groups"] as? [String], ["TEAM.dev.x.app"])
        let plain = IOSAppSigner.entitlements(bundleID: "dev.x.app", profile: profile("TEAM.*", keychain: false))
        XCTAssertNil(plain["keychain-access-groups"])
    }

    func testReadsTheKeychainsIdentities() {
        let text = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Maximilian Marquart (9XZJXLA367)"
          2) 89abcdef0123456789abcdef0123456789abcdef "Developer ID Application: Maximilian Marquart (S3725YB7V6)"
             2 valid identities found
        """
        let ids = SigningIdentity.parse(text)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0].name, "Apple Development: Maximilian Marquart (9XZJXLA367)")
        XCTAssertEqual(ids[1].fingerprint, "89ABCDEF0123456789ABCDEF0123456789ABCDEF")
    }

    func testRefusesSimulatorBuildsAndFoldersWithoutAnApp() throws {
        let app = root.appendingPathComponent("Sim.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.x.sim", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try IOSAppBundle.read(app)) { XCTAssertEqual($0 as? IOSAppSigner.SignError, .simulatorBuild) }
        XCTAssertThrowsError(try IOSAppBundle.read(root)) {
            XCTAssertEqual($0 as? IOSAppSigner.SignError, .notAnApp(root.lastPathComponent))
        }
        let device = root.appendingPathComponent("Device.app")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let deviceInfo: [String: Any] = ["CFBundleIdentifier": "dev.x.app", "CFBundleDisplayName": "X",
                                         "CFBundleShortVersionString": "1.2", "CFBundleVersion": "7",
                                         "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        try PropertyListSerialization.data(fromPropertyList: deviceInfo, format: .xml, options: 0)
            .write(to: device.appendingPathComponent("Info.plist"))
        let bundle = try IOSAppBundle.read(device)
        XCTAssertEqual(bundle.name, "X")
        XCTAssertEqual(bundle.version, "1.2 (7)")
    }

    // MARK: Jobs and the tools

    func testPairedDevicesFromThePairingRecords() throws {
        let folder = root.appendingPathComponent(".pymobiledevice3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["remote_00008140-AAA.plist", "00008140-AAA.plist", "remote_00008150-BBB.plist", "other.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(DeviceInstaller.pairedDevices(home: root), ["00008140-AAA", "00008150-BBB"])
    }

    func testNothingIsQueuedWhileTheFeatureIsOff() async throws {
        let paths = Paths(root: root)
        try paths.prepare()
        do {
            _ = try await DeviceInstaller(paths: paths).submit(path: "/nonexistent.app", source: "test")
            XCTFail("must refuse")
        } catch let error as DeviceInstaller.InstallError {
            guard case .off = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(DeviceInstaller(paths: paths).statusText().contains("off"))
    }

    func testJobsRoundTripThroughTheirFiles() throws {
        let paths = Paths(root: root)
        try paths.prepare()
        let installer = DeviceInstaller(paths: paths)
        let job = DeviceJob(app: "/x/App.app", name: "App", bundleId: "dev.x.app", version: "1.0 (1)", source: "Claude Code")
        try installer.write(job)
        let read = try XCTUnwrap(installer.job(job.id))
        XCTAssertEqual(read.state, .queued)
        XCTAssertEqual(read.bundleId, "dev.x.app")
        XCTAssertEqual(Int(read.created.timeIntervalSince1970), Int(job.created.timeIntervalSince1970))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.deviceJobs.appendingPathComponent("\(job.id).json").path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testTheAgentToolsAreListed() {
        let names = MCPTools.definitions.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("iphone_install"))
        XCTAssertTrue(names.contains("iphone_status"))
        XCTAssertEqual(MCPTools.operations["iphone_install"], "iphone_install")
        XCTAssertTrue(MCPTools.instructions.contains("-allowProvisioningUpdates"))
    }

    func testSettingsKeepTheHeartbeatInRange() throws {
        let s = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"iphoneApps": true, "iphoneHeartbeat": 1}"#.utf8))
        XCTAssertTrue(s.iphoneApps)
        XCTAssertEqual(s.iphoneHeartbeat, 10)
        XCTAssertEqual(AgentSettings().iphoneHeartbeat, 30)
        XCTAssertFalse(AgentSettings().iphoneApps)
    }

    // MARK: The environment

    func testTheEnvironmentIsReadyOnlyForTheShippedRequirements() throws {
        let paths = Paths(root: root)
        let requirements = root.appendingPathComponent("req.txt")
        try "pymobiledevice3==1\n".write(to: requirements, atomically: true, encoding: .utf8)
        XCTAssertFalse(DeviceRuntime.isReady(paths, requirements: requirements))
        let bin = DeviceRuntime.python(paths)
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try DeviceRuntime.digest(of: requirements).write(to: DeviceRuntime.marker(paths), atomically: true, encoding: .utf8)
        XCTAssertTrue(DeviceRuntime.isReady(paths, requirements: requirements))
        try "pymobiledevice3==2\n".write(to: requirements, atomically: true, encoding: .utf8)
        XCTAssertFalse(DeviceRuntime.isReady(paths, requirements: requirements), "new requirements: set up again")
    }

    func testResourcesNextToTheProgram() {
        let exe = URL(fileURLWithPath: "/Applications/aOS.app/Contents/MacOS/aos-devices")
        XCTAssertEqual(DeviceRuntime.appResources(executable: exe).path, "/Applications/aOS.app/Contents/Resources")
    }

    // MARK: The phone's view

    func testThePhoneSeesTheTunnelAndTheInstalls() throws {
        let status = try DeviceStatus.decoder().decode(DeviceStatus.self, from: Data(workerReport.utf8))
        var settings = AgentSettings()
        XCTAssertNil(CompanionControl.apps(settings: settings, status: status, iso: ISO8601DateFormatter()))
        settings.iphoneApps = true
        let apps = try XCTUnwrap(CompanionControl.apps(settings: settings, status: status, iso: ISO8601DateFormatter(),
                                                       alive: { _ in true }))
        XCTAssertEqual(apps["state"] as? String, "connected")
        XCTAssertEqual(apps["network"] as? String, "cellular")
        XCTAssertEqual(apps["device"] as? String, "iPhone von Max")
        XCTAssertEqual(apps["previousSeconds"] as? Int, 4210)
        let jobs = try XCTUnwrap(apps["jobs"] as? [[String: Any]])
        XCTAssertEqual(jobs.count, 3)
        XCTAssertEqual(jobs[1]["message"] as? String, "ApplicationVerificationFailed")
        XCTAssertNil(jobs[0]["message"])
        let stopped = try XCTUnwrap(CompanionControl.apps(settings: settings, status: status, iso: ISO8601DateFormatter(),
                                                          alive: { _ in false }))
        XCTAssertEqual(stopped["state"] as? String, "stopped")
    }
}
