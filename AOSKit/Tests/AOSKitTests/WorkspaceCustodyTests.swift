@testable import AOSKit
import Foundation
import XCTest

final class FakeAttacher: DiskAttaching, @unchecked Sendable {
    var attached: [String] = []
    func attach(_ image: URL) throws -> String { attached.append(image.path); return "disk99" }
    func detach(_ name: String, force: Bool) -> Bool { true }
    func attached(_ image: URL) -> [String] { [] }
}

final class FakeGuard: DiskGuarding, @unchecked Sendable {
    var guarded: [Set<String>] = []
    var attaching: [Bool] = []
    var ejects: [String] = []
    func guardDisks(_ names: Set<String>) { guarded.append(names) }
    func setAttaching(_ attaching: Bool) { self.attaching.append(attaching) }
    func allowEject(_ name: String) { ejects.append(name) }
}

final class WorkspaceCustodyTests: XCTestCase {
    var base: URL!
    var home: URL!
    var fakeSSH: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("custody-\(UUID().uuidString)")
        base = root.appendingPathComponent("Library/Application Support/aOS")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Prints its arguments, the askpass variable and what came on stdin.
        fakeSSH = root.appendingPathComponent("fake-ssh")
        try "#!/bin/sh\necho \"ARGS $*\"\necho \"ASKPASS ${SSH_ASKPASS:-none}\"\necho \"HOME $HOME\"\necho \"IN $(cat)\"\n"
            .write(to: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH.path, 0o755)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    func host(attacher: DiskAttaching = FakeAttacher(), guardian: DiskGuarding? = nil) -> WorkspaceCustodyHost {
        let home = self.home!
        return WorkspaceCustodyHost(layout: .init(base: base), account: { nil }, attacher: attacher, diskGuard: guardian,
                                    sshPath: fakeSSH.path, guestUser: "aos", home: { _ in home })
    }

    func call(_ h: WorkspaceCustodyHost, _ r: CustodyRequest) async -> CustodyReply {
        await h.handle(r, caller: getuid(), pid: getpid()).0
    }

    func testPrepareMakesKeysAndPasswordOnce() async throws {
        let h = host()
        let first = await call(h, CustodyRequest(op: .prepare))
        XCTAssertTrue(first.ok, first.message ?? "")
        XCTAssertEqual(first.hasKeys, true)
        XCTAssertTrue(first.maintenancePublicKey?.hasPrefix("ssh-ed25519 ") == true)
        XCTAssertTrue(first.stopPublicKey?.hasPrefix("ssh-ed25519 ") == true)
        let password = await call(h, CustodyRequest(op: .password)).password
        XCTAssertEqual(password?.count, 32)
        let second = await call(h, CustodyRequest(op: .prepare))
        XCTAssertEqual(second.maintenancePublicKey, first.maintenancePublicKey)
        let r1 = await call(h, CustodyRequest(op: .password))
        XCTAssertEqual(r1.password, password)
        let layout = WorkspaceCustodyHost.Layout(base: base)
        let attributes = try FileManager.default.attributesOfItem(atPath: layout.keys.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let askpass = try String(contentsOf: layout.askpass, encoding: .utf8)
        XCTAssertTrue(askpass.contains(layout.password.path))
    }

    func testImportLegacyKeysAndPin() async throws {
        let h = host()
        let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample aos-maintenance"
        let files: [String: Data] = [
            "maintenance": Data("PRIVATE-M".utf8), "maintenance.pub": Data(pub.utf8),
            "stop": Data("PRIVATE-S".utf8), "stop.pub": Data(pub.utf8),
            "password": Data("bcdefghijklnoprstuvxBCDEFGHIJKLN".utf8),
            "known_hosts": Data("192.168.64.13 ssh-ed25519 AAAAhost\nexample.com ssh-ed25519 AAAAother\n".utf8),
        ]
        let r = await call(h, CustodyRequest(op: .importLegacy, files: files))
        XCTAssertTrue(r.ok, r.message ?? "")
        XCTAssertEqual(r.rotationNeeded, true)
        XCTAssertEqual(r.pinned, true)
        let r2 = await call(h, CustodyRequest(op: .password))
        XCTAssertEqual(r2.password, "bcdefghijklnoprstuvxBCDEFGHIJKLN")
        let known = try String(contentsOf: WorkspaceCustodyHost.Layout(base: base).knownHosts, encoding: .utf8)
        XCTAssertEqual(known, "aos-workspace ssh-ed25519 AAAAhost\n")
        // Only once.
        let again = await call(h, CustodyRequest(op: .importLegacy, files: files))
        XCTAssertFalse(again.ok)
    }

    func testImportPasswordOnly() async {
        let h = host()
        let r = await call(h, CustodyRequest(op: .importLegacy, files: ["password": Data("bcdefghijklnoprstuvxBCDEFGHIJKLN".utf8)]))
        XCTAssertTrue(r.ok, r.message ?? "")
        XCTAssertEqual(r.hasKeys, true)
        XCTAssertEqual(r.rotationNeeded, false)
        let prepared = await call(h, CustodyRequest(op: .prepare))
        XCTAssertTrue(prepared.maintenancePublicKey?.hasPrefix("ssh-ed25519 ") == true)
        let r3 = await call(h, CustodyRequest(op: .password))
        XCTAssertEqual(r3.password, "bcdefghijklnoprstuvxBCDEFGHIJKLN")
    }

    func testRotation() async {
        let h = host()
        let before = await call(h, CustodyRequest(op: .prepare))
        let oldPassword = await call(h, CustodyRequest(op: .password)).password
        let begun = await call(h, CustodyRequest(op: .rotateBegin))
        XCTAssertTrue(begun.ok, begun.message ?? "")
        XCTAssertEqual(begun.password, oldPassword)
        XCTAssertNotEqual(begun.nextMaintenancePublicKey, before.maintenancePublicKey)
        XCTAssertNotEqual(begun.nextPassword, oldPassword)
        // The same pending keys until committed.
        let again = await call(h, CustodyRequest(op: .rotateBegin))
        XCTAssertEqual(again.nextMaintenancePublicKey, begun.nextMaintenancePublicKey)
        XCTAssertEqual(again.nextPassword, begun.nextPassword)
        let r4 = await call(h, CustodyRequest(op: .rotateCommit))
        XCTAssertTrue(r4.ok)
        let after = await call(h, CustodyRequest(op: .prepare))
        XCTAssertEqual(after.maintenancePublicKey, begun.nextMaintenancePublicKey)
        let r5 = await call(h, CustodyRequest(op: .password))
        XCTAssertEqual(r5.password, begun.nextPassword)
        XCTAssertEqual(after.rotating, false)
    }

    func testRotationKeepsPassword() async {
        let h = host()
        _ = await call(h, CustodyRequest(op: .prepare))
        let old = await call(h, CustodyRequest(op: .password)).password
        let begun = await call(h, CustodyRequest(op: .rotateBegin))
        let r6 = await call(h, CustodyRequest(op: .rotateCommit, keepPassword: true))
        XCTAssertTrue(r6.ok)
        let r7 = await call(h, CustodyRequest(op: .password))
        XCTAssertEqual(r7.password, old)
        let r8 = await call(h, CustodyRequest(op: .prepare))
        XCTAssertEqual(r8.maintenancePublicKey, begun.nextMaintenancePublicKey)
    }

    func testSSHArgumentsAreChecked() throws {
        let h = host()
        _ = try h.prepare()
        let ok = try h.sshArguments(CustodyRequest(op: .ssh, host: "192.168.64.2", user: "root", key: .maintenance,
                                                   command: "id -u"), acceptNew: false)
        XCTAssertTrue(ok.contains("HostKeyAlias=aos-workspace"))
        XCTAssertTrue(ok.contains("StrictHostKeyChecking=yes"))
        XCTAssertEqual(Array(ok.suffix(3)), ["--", "192.168.64.2", "id -u"])
        XCTAssertTrue(ok.contains(WorkspaceCustodyHost.Layout(base: base).key("maintenance").path))
        for bad in [CustodyRequest(op: .ssh, host: "-oProxyCommand=x", user: "root", key: .maintenance, command: "true"),
                    CustodyRequest(op: .ssh, host: "example.com", user: "root", key: .maintenance, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.300", user: "root", key: .maintenance, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.2", user: "admin", key: .maintenance, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.2", user: "root", key: .password, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.2", user: "aos", key: .maintenance, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.2", user: "root", key: .next, command: "true"),
                    CustodyRequest(op: .ssh, host: "192.168.64.2", user: "root", key: .maintenance, command: "")] {
            XCTAssertThrowsError(try h.sshArguments(bad, acceptNew: false), "\(bad)")
        }
    }

    func testSSHRunsWithTheKeyAndPins() async throws {
        let h = host()
        _ = await call(h, CustodyRequest(op: .createDisk, gibibytes: 16))
        _ = await call(h, CustodyRequest(op: .prepare))
        let r = await call(h, CustodyRequest(op: .ssh, host: "192.168.64.2", user: "root", key: .maintenance,
                                             command: "id -u", input: Data("hello".utf8)))
        XCTAssertTrue(r.ok, r.message ?? "")
        let out = String(decoding: r.stdout ?? Data(), as: UTF8.self)
        XCTAssertTrue(out.contains("StrictHostKeyChecking=accept-new"), out)
        XCTAssertTrue(out.contains("ASKPASS none"))
        XCTAssertTrue(out.contains("IN hello"))
        let password = await call(h, CustodyRequest(op: .ssh, host: "192.168.64.2", user: "aos", key: .password,
                                                    command: "true"))
        let text = String(decoding: password.stdout ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("ASKPASS \(WorkspaceCustodyHost.Layout(base: base).askpass.path)"), text)
        XCTAssertTrue(text.contains("PubkeyAuthentication=no"))
    }

    func testCreateAndAdoptDisk() async throws {
        let h = host()
        // An earlier aOS's disk in the user's folder.
        let legacy = home.appendingPathComponent("Library/Application Support/\(Brand.name)/VM/disk.img")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("DISK".utf8).write(to: legacy)
        let adopted = await call(h, CustodyRequest(op: .adoptDisk))
        XCTAssertTrue(adopted.ok, adopted.message ?? "")
        XCTAssertEqual(adopted.hasDisk, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let layout = WorkspaceCustodyHost.Layout(base: base)
        XCTAssertEqual(try Data(contentsOf: layout.diskImage), Data("DISK".utf8))
        // Not twice, and a new one only on request.
        let r9 = await call(h, CustodyRequest(op: .adoptDisk))
        XCTAssertFalse(r9.ok)
        let r10 = await call(h, CustodyRequest(op: .createDisk, gibibytes: 16))
        XCTAssertFalse(r10.ok)
        let created = await call(h, CustodyRequest(op: .createDisk, gibibytes: 16, replace: true))
        XCTAssertTrue(created.ok, created.message ?? "")
        let size = try FileManager.default.attributesOfItem(atPath: layout.diskImage.path)[.size] as? UInt64
        XCTAssertEqual(size, 16 << 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.pinOpen.path))
        let r11 = await call(h, CustodyRequest(op: .createDisk, gibibytes: 4, replace: true))
        XCTAssertFalse(r11.ok)
    }

    func testForgetSecretsOnlyWithoutADisk() async throws {
        let h = host()
        _ = await call(h, CustodyRequest(op: .createDisk, gibibytes: 16))
        let before = await call(h, CustodyRequest(op: .prepare))
        let refused = await call(h, CustodyRequest(op: .forgetSecrets))
        XCTAssertFalse(refused.ok)
        _ = await call(h, CustodyRequest(op: .eraseDisk))
        let forgot = await call(h, CustodyRequest(op: .forgetSecrets))
        XCTAssertTrue(forgot.ok, forgot.message ?? "")
        XCTAssertEqual(forgot.hasKeys, false)
        let after = await call(h, CustodyRequest(op: .prepare))
        XCTAssertNotEqual(after.maintenancePublicKey, before.maintenancePublicKey)
    }

    func testAdoptRefusesALink() async throws {
        let h = host()
        let legacy = home.appendingPathComponent("Library/Application Support/\(Brand.name)/VM/disk.img")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = home.appendingPathComponent("secret")
        try Data("x".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: other)
        let r12 = await call(h, CustodyRequest(op: .adoptDisk))
        XCTAssertFalse(r12.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testAttachGuardsTheDisk() async throws {
        let attacher = FakeAttacher()
        let guardian = FakeGuard()
        let h = host(attacher: attacher, guardian: guardian)
        _ = await call(h, CustodyRequest(op: .createDisk, gibibytes: 16))
        // There's no /dev/rdisk99 here: the open fails, but the disk was attached and guarded first.
        let (reply, handle) = await h.handle(CustodyRequest(op: .attachDisk), caller: getuid(), pid: 42)
        XCTAssertFalse(reply.ok)
        XCTAssertNil(handle)
        XCTAssertEqual(attacher.attached.count, 1)
        XCTAssertEqual(guardian.attaching, [true, false])
        XCTAssertEqual(guardian.guarded.last, ["disk99"])
        XCTAssertTrue(h.isAttached)
        h.processEnded(41)
        XCTAssertTrue(h.isAttached)
        h.processEnded(42)
        XCTAssertFalse(h.isAttached)
        XCTAssertEqual(guardian.ejects, ["disk99"])
        XCTAssertEqual(guardian.guarded.last, [])
    }

    func testPinLinesAndAddresses() {
        let lines = WorkspaceCustodyHost.pinLines(fromKnownHosts: """
        192.168.64.5 ssh-ed25519 AAAA1
        192.168.64.6 ssh-ed25519 AAAA1
        192.168.64.6 ecdsa-sha2-nistp256 BBBB
        |1|hashed ssh-ed25519 CCCC
        # comment
        github.com ssh-ed25519 DDDD
        """)
        XCTAssertEqual(lines, ["aos-workspace ssh-ed25519 AAAA1", "aos-workspace ecdsa-sha2-nistp256 BBBB"])
        XCTAssertTrue(WorkspaceCustodyHost.isIPv4("192.168.64.1"))
        XCTAssertFalse(WorkspaceCustodyHost.isIPv4("192.168.64"))
        XCTAssertFalse(WorkspaceCustodyHost.isIPv4("1.2.3.4.5"))
        XCTAssertFalse(WorkspaceCustodyHost.isIPv4("1.2.3.x"))
    }

    func testWholeDiskFromAttachPlist() throws {
        let plist: [String: Any] = ["system-entities": [
            ["dev-entry": "/dev/disk10", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk10s1"], ["dev-entry": "/dev/disk11"],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(HdiutilAttacher.wholeDisk(fromAttachPlist: data), "disk10")
    }

    func testKcpasswordMatchesWhateverThePadding() {
        let password = "bcdefghijklnoprstuvxBCDEFGHIJKLN"
        var file = [UInt8](Kcpassword.encode(password))
        // macOS may fill the padding after the zero byte with other bytes.
        for i in 33..<file.count { file[i] = UInt8.random(in: 0...255) }
        XCTAssertTrue(Kcpassword.matches(Data(file), password: password))
        XCTAssertFalse(Kcpassword.matches(Data(file), password: "bcdefghijklnoprstuvxBCDEFGHIJKLO"))
        XCTAssertFalse(Kcpassword.matches(Data(file.prefix(30)), password: password))
    }

    func testKcpassword() {
        let encoded = Kcpassword.encode("bcdefghijklnoprstuvxBCDEFGHIJKLN")
        XCTAssertEqual(encoded.count % 12, 0)
        XCTAssertGreaterThan(encoded.count, 32)
        let decoded = encoded.enumerated().map { $0.element ^ Kcpassword.key[$0.offset % Kcpassword.key.count] }
        XCTAssertEqual(Array(decoded.prefix(32)), Array("bcdefghijklnoprstuvxBCDEFGHIJKLN".utf8))
        XCTAssertEqual(decoded[32], 0)
        XCTAssertEqual(Kcpassword.encode("12345678901").count, 12)
    }

    func testSecretsComeFromTheHelper() async throws {
        let h = host()
        let client = WorkspaceCustodyClient { request in await h.handle(request, caller: getuid(), pid: getpid()) }
        let paths = Paths(root: base.appendingPathComponent("user"))
        GuestSecrets.custody = client
        defer { GuestSecrets.custody = nil }
        let secrets = GuestSecrets(paths: paths)
        XCTAssertThrowsError(try secrets.adminPassword(createIfMissing: true))
        let loaded = try await secrets.load()
        XCTAssertEqual(try secrets.adminPassword(createIfMissing: false), loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secrets.adminPasswordURL.path))
        let keys = try await secrets.publicKeys()
        XCTAssertTrue(keys.maintenance.hasPrefix("ssh-ed25519 "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secrets.maintenanceKey.path))
    }
}
