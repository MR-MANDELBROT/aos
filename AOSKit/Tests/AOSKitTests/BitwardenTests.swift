@testable import AOSKit
import XCTest

/// A folder with the stand-in for Bitwarden's `bw` (Fixtures/fake-bw), its scenario and its state.
final class FakeBitwarden {
    let folder: URL
    let executable: String
    var cli: BitwardenCLI { BitwardenCLI(executable: executable, dataDirectory: folder) }

    init(scenario: [String: Any], state: [String: Any] = ["state": "unauthenticated"]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aos-bw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("fake-bw")
        let target = folder.appendingPathComponent("bw")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        executable = target.path
        try write("scenario.json", scenario)
        try write("state.json", state)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func write(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent(name))
    }

    func state() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("state.json").path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Every command line the stand-in was started with.
    var commandLines: String {
        String(decoding: FileManager.default.contents(atPath: folder.appendingPathComponent("argv.log").path) ?? Data(),
               as: UTF8.self)
    }

    /// A session key that was put on a command line (never should be).
    var leaks: String {
        String(decoding: FileManager.default.contents(atPath: folder.appendingPathComponent("leaks.log").path) ?? Data(),
               as: UTF8.self)
    }

    static let password = "correct horse battery"
    static let campus = "11111111-1111-4111-8111-111111111111"
    static let login = "22222222-2222-4222-8222-222222222222"
    static let whole = "33333333-3333-4333-8333-333333333333"
    static let bank = "44444444-4444-4444-8444-444444444444"

    static func item(_ id: String, _ name: String, user: String, uris: [String], password: String, totp: String? = nil,
                     reprompt: Int = 0, type: Int = 1, deleted: Bool = false) -> [String: Any] {
        ["object": "item", "id": id, "organizationId": NSNull(), "folderId": NSNull(), "type": type,
         "reprompt": reprompt, "name": name, "notes": NSNull(), "favorite": false,
         "login": ["uris": uris.map { ["match": NSNull(), "uri": $0] }, "username": user, "password": password,
                   "totp": totp.map { $0 as Any } ?? NSNull(), "passwordRevisionDate": NSNull()],
         "collectionIds": [], "revisionDate": "2026-10-01T10:00:00.000Z",
         "deletedDate": deleted ? "2026-10-02T10:00:00.000Z" as Any : NSNull()]
    }

    static let items: [[String: Any]] = [
        item(campus, "TUMonline", user: "ge12abc", uris: ["https://campus.tum.de/tumonline"], password: "campus-pw"),
        item(login, "TUM Login", user: "ge12abc", uris: ["login.tum.de"], password: "login-pw"),
        item(whole, "TUM", user: "max@tum.de", uris: ["androidapp://de.tum", "tum.de"], password: "tum-pw",
             totp: "otpauth://totp/TUM?secret=GEZDGNBVGY3TQOJQ"),
        item(bank, "Bank", user: "max", uris: ["https://campus.tum.de"], password: "bank-pw", reprompt: 1),
        item("55555555-5555-4555-8555-555555555555", "Old", user: "old", uris: ["campus.tum.de"], password: "x",
             deleted: true),
        item("66666666-6666-4666-8666-666666666666", "A note", user: "", uris: [], password: "", type: 2),
    ]

    static func scenario(_ extra: [String: Any] = [:]) -> [String: Any] {
        var s: [String: Any] = ["email": "max@example.com", "password": password, "items": items,
                                "totp": [whole: "424242"]]
        for (k, v) in extra { s[k] = v }
        return s
    }
}

/// Steps of a sign-in, as they came.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [BitwardenLoginConversation.Step] = []
    func append(_ step: BitwardenLoginConversation.Step) { lock.withLock { list.append(step) } }
    var steps: [BitwardenLoginConversation.Step] { lock.withLock { list } }
    var questions: [BitwardenLoginConversation.Step] { steps.filter { $0 != .working } }
}

final class BitwardenCLITests: XCTestCase {
    func testStatusAndServer() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario())
        var status = try await fake.cli.status()
        XCTAssertEqual(status.state, .unauthenticated)
        XCTAssertNil(status.email)
        XCTAssertEqual(BitwardenServer(serverURL: status.serverURL), .us)
        try await fake.cli.setServer(.eu)
        status = try await fake.cli.status()
        XCTAssertEqual(status.serverURL, "https://vault.bitwarden.eu")
        XCTAssertEqual(BitwardenServer(serverURL: status.serverURL), .eu)
        try await fake.cli.setServer(.us)
        let value1 = try await fake.cli.status().serverURL
        XCTAssertNil(value1)
        let version = await fake.cli.version()
        XCTAssertEqual(version, "2026.10.1")
    }

    func testServers() {
        XCTAssertEqual(BitwardenServer(serverURL: nil), .us)
        XCTAssertEqual(BitwardenServer(serverURL: "https://vault.bitwarden.com"), .us)
        XCTAssertEqual(BitwardenServer(serverURL: "https://vault.bitwarden.eu"), .eu)
        XCTAssertEqual(BitwardenServer(serverURL: "https://pw.example.org"), .selfHosted("https://pw.example.org"))
        XCTAssertEqual(BitwardenServer.selfHosted(address: "pw.example.org/"), .selfHosted("https://pw.example.org"))
        XCTAssertEqual(BitwardenServer.selfHosted(address: "https://vault.bitwarden.eu"), .eu)
        XCTAssertNil(BitwardenServer.selfHosted(address: "http://pw.example.org"))
        XCTAssertNil(BitwardenServer.selfHosted(address: "--apikey"))
        XCTAssertNil(BitwardenServer.selfHosted(address: "pw example.org"))
        XCTAssertEqual(BitwardenServer.eu.configValue, "https://vault.bitwarden.eu")
        XCTAssertEqual(BitwardenServer.us.configValue, "bitwarden.com")
    }

    func testLoginWithoutQuestions() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario())
        let conversation = try fake.cli.startLogin(email: "max@example.com", password: FakeBitwarden.password)
        let log = StepLog()
        conversation.onStep = { log.append($0) }
        let key = try await conversation.run()
        XCTAssertTrue(BitwardenCLI.isSessionKey(key))
        XCTAssertEqual(log.questions, [])
        let value2 = try await fake.cli.status(session: key).state
        XCTAssertEqual(value2, .unlocked)
        let value3 = try await fake.cli.status().state
        XCTAssertEqual(value3, .locked)  // without the key: locked
        XCTAssertFalse(fake.commandLines.contains(FakeBitwarden.password))
        XCTAssertFalse(fake.commandLines.contains(key))
        XCTAssertEqual(fake.leaks, "")
    }

    func testLoginWithTwoStepMethodsAndANewDevice() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario([
            "twostep": ["Authenticator App", "Email", "Yubico OTP Security Key"],
            "codes": ["Authenticator App": "000000", "Email": "135790"],
            "newdevice": true, "newdeviceCode": "246810",
        ]))
        let conversation = try fake.cli.startLogin(email: "max@example.com", password: FakeBitwarden.password)
        let log = StepLog()
        conversation.onStep = { [weak conversation] step in
            log.append(step)
            switch step {
            case .chooseMethod: conversation?.choose(1)
            case .twoStepCode: conversation?.answer("135790")
            case .newDeviceCode: conversation?.answer(" 246810\n")  // line breaks never reach the terminal
            default: break
            }
        }
        let key = try await conversation.run()
        XCTAssertTrue(BitwardenCLI.isSessionKey(key))
        XCTAssertEqual(log.questions, [.chooseMethod(["Authenticator App", "Email", "Yubico OTP Security Key"]),
                                       .twoStepCode(method: "Email"), .newDeviceCode])
        XCTAssertEqual(fake.state()["method"] as? String, "Email")
        XCTAssertEqual(fake.state()["emailSent"] as? Bool, true)
        XCTAssertFalse(fake.commandLines.contains(FakeBitwarden.password))
        XCTAssertFalse(fake.commandLines.contains("135790"))
    }

    func testSingleMethodIsChosenByItself() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario([
            "twostep": ["Authenticator App"], "codes": ["Authenticator App": "111222"]]))
        let conversation = try fake.cli.startLogin(email: "max@example.com", password: FakeBitwarden.password)
        let log = StepLog()
        conversation.onStep = { [weak conversation] step in
            log.append(step)
            if step == .twoStepCode(method: nil) { conversation?.answer("111222") }
        }
        _ = try await conversation.run()
        XCTAssertEqual(log.questions, [.twoStepCode(method: nil)])
    }

    func testWrongCodeAndWrongPassword() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario([
            "twostep": ["Email"], "codes": ["Email": "135790"]]))
        let conversation = try fake.cli.startLogin(email: "max@example.com", password: FakeBitwarden.password)
        conversation.onStep = { [weak conversation] step in
            if case .twoStepCode = step { conversation?.answer("999999") }
        }
        do {
            _ = try await conversation.run()
            XCTFail("a wrong code signed in")
        } catch BitwardenError.failed(let message) {
            XCTAssertEqual(message, "Two-step token is invalid. Try again.")
        }
        let wrong = try fake.cli.startLogin(email: "max@example.com", password: "nope")
        do {
            _ = try await wrong.run()
            XCTFail("a wrong password signed in")
        } catch BitwardenError.failed(let message) {
            XCTAssertTrue(message.hasPrefix("Invalid master password."))
        }
        XCTAssertThrowsError(try fake.cli.startLogin(email: "--apikey", password: "x"))
        XCTAssertThrowsError(try fake.cli.startLogin(email: "no address", password: "x"))
    }

    func testCancellingASignIn() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(["newdevice": true, "newdeviceCode": "1"]))
        let conversation = try fake.cli.startLogin(email: "max@example.com", password: FakeBitwarden.password)
        conversation.onStep = { [weak conversation] step in
            if step == .newDeviceCode { conversation?.cancel() }
        }
        do {
            _ = try await conversation.run()
            XCTFail("not cancelled")
        } catch BitwardenError.cancelled {}
        XCTAssertEqual(fake.state()["state"] as? String, "unauthenticated")
    }

    func testUnlockLockAndLogout() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(),
                                     state: ["state": "locked", "email": "max@example.com"])
        do {
            _ = try await fake.cli.unlock(password: "wrong")
            XCTFail("unlocked with a wrong password")
        } catch let error as BitwardenError {
            XCTAssertEqual(error, .wrongPassword)
        }
        let key = try await fake.cli.unlock(password: FakeBitwarden.password)
        let status = try await fake.cli.status(session: key)
        XCTAssertEqual(status.state, .unlocked)
        XCTAssertEqual(status.email, "max@example.com")
        try await fake.cli.sync(session: key)
        try await fake.cli.lock()
        let value4 = try await fake.cli.status(session: key).state
        XCTAssertEqual(value4, .locked)  // the old key opens nothing
        do {
            _ = try await fake.cli.items(forHost: "campus.tum.de", session: key)
            XCTFail("listed while locked")
        } catch let error as BitwardenError {
            XCTAssertEqual(error, .locked)
        }
        try await fake.cli.logout()
        let value5 = try await fake.cli.status().state
        XCTAssertEqual(value5, .unauthenticated)
        XCTAssertFalse(fake.commandLines.contains(FakeBitwarden.password))
        XCTAssertFalse(fake.commandLines.contains(key))
        XCTAssertEqual(fake.leaks, "")
    }

    func testItemsAndSecrets() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(), state: ["state": "locked", "email": "max@example.com"])
        let key = try await fake.cli.unlock(password: FakeBitwarden.password)
        let items = try await fake.cli.items(forHost: "campus.tum.de", session: key)
        // Logins only, not in the trash; what aOS keeps of them has no password
        XCTAssertEqual(items.map(\.name), ["TUMonline", "TUM Login", "TUM", "Bank"])
        XCTAssertEqual(items.first { $0.id == FakeBitwarden.whole }?.hasTOTP, true)
        XCTAssertEqual(items.first { $0.id == FakeBitwarden.bank }?.reprompt, true)
        XCTAssertEqual(items.first { $0.id == FakeBitwarden.whole }?.uris, ["androidapp://de.tum", "tum.de"])

        let (item, password) = try await fake.cli.login(id: FakeBitwarden.campus, session: key)
        XCTAssertEqual(item.username, "ge12abc")
        XCTAssertEqual(password, "campus-pw")
        let value6 = try await fake.cli.password(id: FakeBitwarden.login, session: key)
        XCTAssertEqual(value6, "login-pw")
        let value7 = try await fake.cli.totp(id: FakeBitwarden.whole, session: key)
        XCTAssertEqual(value7, "424242")
        do {
            _ = try await fake.cli.totp(id: FakeBitwarden.campus, session: key)
            XCTFail("a code for a login without authenticator key")
        } catch BitwardenError.failed(let message) {
            XCTAssertEqual(message, "No TOTP available for this login.")
        }
        // Only item ids reach the command line: nothing that could pose as an option or a search
        let before = fake.commandLines
        for bad in ["--session", "campus", "11111111-1111-4111-8111-11111111111", ""] {
            do {
                _ = try await fake.cli.login(id: bad, session: key)
                XCTFail("ran with \(bad)")
            } catch let error as BitwardenError {
                XCTAssertEqual(error, .notFound)
            }
        }
        XCTAssertEqual(fake.commandLines, before)
        XCTAssertFalse(fake.commandLines.contains(key))
    }

    func testOneBwAtATimePerFolder() async throws {
        let serial = BitwardenSerial()
        let log = StepLog()
        await serial.acquire("a")
        let waiting = Task {
            await serial.acquire("a")
            log.append(.question("second", secret: false))
            await serial.release("a")
        }
        await serial.acquire("b")  // another folder doesn't wait
        await serial.release("b")
        try await Task.sleep(nanoseconds: 100_000_000)
        log.append(.question("first", secret: false))
        await serial.release("a")
        await waiting.value
        XCTAssertEqual(log.steps, [.question("first", secret: false), .question("second", secret: false)])
        await serial.acquire("a")  // free again
        await serial.release("a")
    }

    func testRepliesAndChecks() {
        let reply = BitwardenCLI.reply(from: Data("(node) a warning\n{\"success\":false,\"message\":\"Vault is locked.\"}\n".utf8))
        XCTAssertEqual(reply?.success, false)
        XCTAssertEqual(BitwardenError(message: reply?.message), .locked)
        XCTAssertNil(BitwardenCLI.reply(from: Data("not json".utf8)))
        XCTAssertEqual(BitwardenCLI.reply(from: Data(#"{"success":true,"data":{"object":"string","data":"123456"}}"#.utf8))?.string, "123456")
        XCTAssertTrue(BitwardenCLI.isItemID("2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5"))
        XCTAssertFalse(BitwardenCLI.isItemID("-2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e"))
        XCTAssertTrue(BitwardenCLI.isEmail("max@example.com"))
        XCTAssertFalse(BitwardenCLI.isEmail("-x@example.com"))
        XCTAssertFalse(BitwardenCLI.isEmail("max@ example.com"))
        XCTAssertFalse(BitwardenCLI.isSessionKey("not a key!"))
    }
}

final class BitwardenPromptTests: XCTestCase {
    /// What inquirer 8 draws for `bw login` on a terminal: colors, erased and redrawn lines, cursor moves.
    let methodList = "\u{1B}[?25l\u{1B}[32m?\u{1B}[39m \u{1B}[1mTwo-step login method:\u{1B}[22m\u{1B}[0m \u{1B}[0m\u{1B}[2m(Use arrow keys)\u{1B}[22m\n"
        + "\u{1B}[36m❯ Authenticator App\u{1B}[39m \n  Email \n  \u{1B}[2m──────────────\u{1B}[22m\n  Cancel \u{1B}[5A\u{1B}[35C"

    func testRecognizesBitwardensQuestions() {
        let text = BitwardenPrompt.plain(methodList)
        XCTAssertEqual(BitwardenPrompt.all(in: text), [.twoStepMethod(["Authenticator App", "Email"])])

        let afterChoice = methodList + "\u{1B}[2K\u{1B}[1A\u{1B}[2K\u{1B}[G\u{1B}[32m?\u{1B}[39m \u{1B}[1mTwo-step login method:\u{1B}[22m\u{1B}[0m \u{1B}[0m\u{1B}[36mEmail\u{1B}[39m\n\u{1B}[?25h"
            + "\u{1B}[2K\u{1B}[G\u{1B}[32m?\u{1B}[39m \u{1B}[1mTwo-step login code:\u{1B}[22m\u{1B}[0m \u{1B}[0m"
            + "\u{1B}[2K\u{1B}[G\u{1B}[32m?\u{1B}[39m \u{1B}[1mTwo-step login code:\u{1B}[22m\u{1B}[0m \u{1B}[0m1"
        XCTAssertEqual(BitwardenPrompt.all(in: BitwardenPrompt.plain(afterChoice)),
                       [.twoStepMethod(["Authenticator App", "Email"]), .twoStepCode])

        let device = "\u{1B}[32m?\u{1B}[39m \u{1B}[1mNew device verification required. Enter OTP sent to login email:\u{1B}[22m\u{1B}[0m \u{1B}[0m"
        XCTAssertEqual(BitwardenPrompt.all(in: BitwardenPrompt.plain(device)), [.newDeviceCode])
        XCTAssertEqual(BitwardenPrompt.all(in: "? Master password: [hidden]"), [.masterPassword])
        XCTAssertEqual(BitwardenPrompt.all(in: "? Email address: "), [.email])
        XCTAssertEqual(BitwardenPrompt.all(in: "Additional authentication required.\nAPI key client_secret: "),
                       [.apiKey("client_secret")])
        XCTAssertEqual(BitwardenPrompt.all(in: "? Something new from Bitwarden: "), [.other("Something new from Bitwarden:")])
        // Messages that aren't questions
        XCTAssertEqual(BitwardenPrompt.all(in: "Invalid master password.\nEmail address is required.\nLogin failed."), [])
    }

    func testAnIncompleteListWaits() {
        let half = "\u{1B}[32m?\u{1B}[39m \u{1B}[1mTwo-step login method:\u{1B}[22m (Use arrow keys)\n❯ Authenticator App \n  Em"
        XCTAssertEqual(BitwardenPrompt.all(in: BitwardenPrompt.plain(half)), [.twoStepMethod([])])
    }
}

final class BitwardenToolTests: XCTestCase {
    func testOnlyBitwardensSignaturePasses() throws {
        // An Apple program is validly signed, but not by Bitwarden
        XCTAssertNil(BitwardenTool.checkSignature("/bin/ls", requirement: "anchor apple"))
        XCTAssertEqual(BitwardenTool.verify("/bin/ls"), "not signed by Bitwarden")
        // A script (like Homebrew's or npm's `bw`) has no signature
        let fake = try FakeBitwarden(scenario: [:])
        XCTAssertNotNil(BitwardenTool.verify(fake.executable))
        XCTAssertEqual(BitwardenTool.verify("/nonexistent/bw"), "not a file")
        XCTAssertTrue(BitwardenTool.developerIDRequirement(team: BitwardenTool.teamIdentifier)
            .hasSuffix("certificate leaf[subject.OU] = \"LTZ2PFU5D6\""))
    }

    func testDownloadsFromBitwardensRelease() throws {
        let release = URL(string: "https://github.com/bitwarden/clients/releases/download/cli-v2026.10.1/bw-macos-2026.10.1.zip")!
        XCTAssertEqual(try BitwardenTool.downloads(forRelease: release, arm64: true).map(\.absoluteString), [
            "https://github.com/bitwarden/clients/releases/download/cli-v2026.10.1/bw-macos-arm64-2026.10.1.zip",
            "https://github.com/bitwarden/clients/releases/download/cli-v2026.10.1/bw-macos-2026.10.1.zip",
        ])
        XCTAssertEqual(try BitwardenTool.downloads(forRelease: release, arm64: false).count, 1)
        for bad in ["https://github.com/bitwarden/clients/releases/download/cli-v2026.10.1/bw-macos-2026.9.0.zip",
                    "https://github.com/someone/clients/releases/download/cli-v2026.10.1/bw-macos-2026.10.1.zip",
                    "https://example.com/bitwarden/clients/releases/download/cli-v2026.10.1/bw-macos-2026.10.1.zip",
                    "https://github.com/bitwarden/clients/releases/download/desktop-v2026.10.1/Bitwarden.dmg"] {
            XCTAssertThrowsError(try BitwardenTool.downloads(forRelease: URL(string: bad)!), bad)
        }
    }
}

final class BitwardenVaultTests: XCTestCase {
    @MainActor
    func testUnlockOfferFillAndLock() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(), state: ["state": "locked", "email": "max@example.com"])
        let store = MemorySessionStore()
        let vault = BitwardenVault(paths: Paths(root: fake.folder), store: store, cli: fake.cli)
        await vault.refresh()
        XCTAssertEqual(vault.phase, .locked)
        XCTAssertEqual(vault.email, "max@example.com")
        let value8 = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(value8, .locked)

        await vault.unlock(password: "wrong")
        XCTAssertEqual(vault.phase, .locked)
        XCTAssertNotNil(vault.problem)
        await vault.unlock(password: FakeBitwarden.password)
        XCTAssertEqual(vault.phase, .unlocked)
        XCTAssertNotNil(store.load())

        // aOS's rule on top of Bitwarden's: login.tum.de isn't campus.tum.de; re-prompt, trash and notes stay out
        let offer = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(offer.state, "unlocked")
        XCTAssertEqual(offer.logins.map(\.name), ["TUM", "TUMonline"])
        let value9 = await vault.offer(for: "login.tum.de").logins.map(\.name)
        XCTAssertEqual(value9, ["TUM", "TUM Login"])

        let credentials = try await vault.credentials(id: FakeBitwarden.campus, host: "campus.tum.de")
        XCTAssertEqual(credentials.username, "ge12abc")
        XCTAssertEqual(credentials.password, "campus-pw")
        // Checked again right before filling: another site's login, or one with re-prompt, isn't filled
        for (id, host) in [(FakeBitwarden.login, "campus.tum.de"), (FakeBitwarden.bank, "campus.tum.de"),
                           (FakeBitwarden.campus, "evil.example")] {
            do {
                _ = try await vault.credentials(id: id, host: host)
                XCTFail("\(id) filled on \(host)")
            } catch {}
        }
        let value10 = try await vault.totp(id: FakeBitwarden.whole, host: "www.tum.de")
        XCTAssertEqual(value10, "424242")

        // The login used last for a site comes first next time
        vault.remember(login: FakeBitwarden.campus, host: "campus.tum.de")
        let value11 = await vault.offer(for: "campus.tum.de").logins.first?.id
        XCTAssertEqual(value11, FakeBitwarden.campus)

        var changes = 0
        vault.onOffersChanged = { changes += 1 }
        await vault.lock(reason: "test")
        XCTAssertEqual(vault.phase, .locked)
        XCTAssertNil(store.load())
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(fake.state()["state"] as? String, "locked")
        let value12 = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(value12, .locked)
        XCTAssertEqual(fake.leaks, "")
    }

    @MainActor
    func testSignInThroughTheVault() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario([
            "twostep": ["Authenticator App"], "codes": ["Authenticator App": "000111"],
            "newdevice": true, "newdeviceCode": "246810"]))
        let store = MemorySessionStore()
        let vault = BitwardenVault(paths: Paths(root: fake.folder), store: store, cli: fake.cli)
        var asked: [BitwardenLoginConversation.Step] = []
        vault.onChange = { [weak vault] in
            guard let vault, case .signingIn(let step) = vault.phase, step != .working, asked.last != step else { return }
            asked.append(step)
            switch step {
            case .twoStepCode: vault.answer("000111")
            case .newDeviceCode: vault.answer("246810")
            default: break
            }
        }
        await vault.refresh()
        XCTAssertEqual(vault.phase, .signedOut)
        await vault.signIn(email: "max@example.com", password: FakeBitwarden.password, server: .eu)
        XCTAssertNil(vault.problem)
        XCTAssertEqual(vault.phase, .unlocked)
        XCTAssertEqual(vault.server, .eu)
        XCTAssertEqual(vault.email, "max@example.com")
        XCTAssertEqual(asked, [.twoStepCode(method: nil), .newDeviceCode])
        XCTAssertNotNil(store.load())

        await vault.signOut()
        XCTAssertEqual(vault.phase, .signedOut)
        XCTAssertNil(store.load())
        XCTAssertEqual(fake.state()["state"] as? String, "unauthenticated")
        XCTAssertFalse(fake.commandLines.contains(FakeBitwarden.password))
    }

    @MainActor
    func testLocksWhenTimeIsUpOrTheMacSlept() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(), state: ["state": "locked", "email": "max@example.com"])
        let store = MemorySessionStore()
        let vault = BitwardenVault(paths: Paths(root: fake.folder), store: store, cli: fake.cli)
        vault.lastSleep = { nil }
        vault.bootTime = { nil }
        vault.lockHours = 8
        await vault.refresh()
        await vault.unlock(password: FakeBitwarden.password)
        let unlocked = try XCTUnwrap(store.load())
        XCTAssertEqual(unlocked.until.timeIntervalSince(unlocked.unlocked), 8 * 3600, accuracy: 1)
        vault.lockHours = 1
        XCTAssertEqual(try XCTUnwrap(store.load()).until.timeIntervalSince(unlocked.unlocked), 3600, accuracy: 1)

        // Time is up
        vault.now = { Date().addingTimeInterval(3601) }
        let value13 = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(value13, .locked)
        XCTAssertNil(store.load())
        XCTAssertEqual(vault.phase, .locked)

        // The Mac slept after unlocking
        vault.now = { Date() }
        await vault.unlock(password: FakeBitwarden.password)
        XCTAssertEqual(vault.phase, .unlocked)
        vault.lastSleep = { Date().addingTimeInterval(1) }
        let value14 = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(value14, .locked)
        XCTAssertNil(store.load())
    }

    @MainActor
    func testASessionFromTheKeychainOutlivesARestartOfTheApp() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(), state: ["state": "locked", "email": "max@example.com"])
        let key = try await fake.cli.unlock(password: FakeBitwarden.password)
        let store = MemorySessionStore(BitwardenSession(key: key, unlocked: Date(), until: Date().addingTimeInterval(3600)))
        let vault = BitwardenVault(paths: Paths(root: fake.folder), store: store, cli: fake.cli)
        vault.lastSleep = { nil }
        vault.bootTime = { nil }
        await vault.refresh()
        XCTAssertEqual(vault.phase, .unlocked)
        let value15 = await vault.offer(for: "www.tum.de").logins.map(\.name)
        XCTAssertEqual(value15, ["TUM"])

        // One from before a restart of the Mac is dropped
        let old = MemorySessionStore(BitwardenSession(key: key, unlocked: Date().addingTimeInterval(-60),
                                                      until: Date().addingTimeInterval(3600)))
        let later = BitwardenVault(paths: Paths(root: fake.folder), store: old, cli: fake.cli)
        later.bootTime = { Date().addingTimeInterval(-30) }
        await later.refresh()
        XCTAssertEqual(later.phase, .locked)
        XCTAssertNil(old.load())
    }

    func testLockRules() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let s = BitwardenSession(key: "k", unlocked: t, until: t.addingTimeInterval(8 * 3600))
        XCTAssertTrue(s.isValid(now: t.addingTimeInterval(3600), lastSleep: t.addingTimeInterval(-60), boot: t.addingTimeInterval(-86400)))
        XCTAssertFalse(s.isValid(now: t.addingTimeInterval(8 * 3600), lastSleep: nil, boot: nil))
        XCTAssertFalse(s.isValid(now: t.addingTimeInterval(60), lastSleep: t.addingTimeInterval(30), boot: nil))
        XCTAssertFalse(s.isValid(now: t.addingTimeInterval(60), lastSleep: nil, boot: t.addingTimeInterval(10)))
        XCTAssertFalse(s.isValid(now: t.addingTimeInterval(-3600), lastSleep: nil, boot: nil))
        XCTAssertNotNil(SystemClock.boot)
    }

    func testKeychainStoreRoundTrip() throws {
        let store = KeychainSessionStore(service: "dev.marquart.aos.tests.bitwarden-\(UUID().uuidString)")
        defer { store.delete() }
        let session = BitwardenSession(key: "c2Vzc2lvbg==", unlocked: Date(timeIntervalSince1970: 1_800_000_000),
                                       until: Date(timeIntervalSince1970: 1_800_028_800))
        do {
            try store.save(session)
        } catch {
            throw XCTSkip("no login keychain here: \(error)")
        }
        XCTAssertEqual(store.load(), session)
        store.delete()
        XCTAssertNil(store.load())
    }
}

/// The answer to a sign-in may only name a login that was offered with it.
final class SignInAnswerTests: XCTestCase {
    @MainActor
    func testAnswersNameOnlyOfferedLogins() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario())
        let paths = Paths(root: fake.folder.appendingPathComponent("aos", isDirectory: true))
        try paths.prepare()
        let controller = WorkspaceController(paths: paths, bitwarden: BitwardenVault(paths: paths, store: MemorySessionStore(),
                                                                                       cli: fake.cli))
        let withCode = "77777777-7777-4777-8777-777777777777", withoutCode = "88888888-8888-4888-8888-888888888888"
        controller.signInOffers["r1"] = SignInOffer(host: "github.com", field: "code", logins: [
            CompanionLogin(id: withCode, name: "GitHub", username: "max", totp: true),
            CompanionLogin(id: withoutCode, name: "GitHub (old)", username: "max", totp: false),
        ], bitwarden: "unlocked")
        let answer = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<SignInAnswer?, Never>) in
                controller.pendingSignIns["r1"] = continuation
            }
        }
        while controller.pendingSignIns["r1"] == nil { await Task.yield() }

        var request = AgentRequest(id: 1, op: "signin.answer")
        request.request = "r1"
        request.login = "99999999-9999-4999-8999-999999999999"
        var response = await controller.handle(request)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.text, "This login wasn't offered for this sign-in.")
        request.login = withoutCode
        response = await controller.handle(request)
        XCTAssertFalse(response.ok)  // a code request needs a login with an authenticator key
        request.login = withCode
        response = await controller.handle(request)
        XCTAssertTrue(response.ok)
        let given = await answer.value
        XCTAssertEqual(given?.login, withCode)
        XCTAssertNil(given?.password)
    }

    @MainActor
    func testUnlockingOffersTheLoginsToAnOpenRequest() async throws {
        let fake = try FakeBitwarden(scenario: FakeBitwarden.scenario(), state: ["state": "locked", "email": "max@example.com"])
        let paths = Paths(root: fake.folder.appendingPathComponent("aos", isDirectory: true))
        try paths.prepare()
        let vault = BitwardenVault(paths: paths, store: MemorySessionStore(), cli: fake.cli)
        vault.lastSleep = { nil }
        vault.bootTime = { nil }
        let controller = WorkspaceController(paths: paths, bitwarden: vault)
        let offer = await vault.offer(for: "campus.tum.de")
        XCTAssertEqual(offer, .locked)
        controller.signInOffers["r1"] = SignInOffer(host: "campus.tum.de", field: "password", logins: [], bitwarden: offer.state)
        controller.companion.post(CompanionEvent(event: "signin", request: "r1", agent: "Claude Code", host: "campus.tum.de",
                                                 field: "password", logins: [], bitwarden: offer.state))
        await vault.unlock(password: FakeBitwarden.password)
        await controller.refreshSignInOffers()
        let event = try XCTUnwrap(controller.companion.open["r1"])
        XCTAssertEqual(event.bitwarden, "unlocked")
        XCTAssertEqual(event.logins?.map(\.name), ["TUM", "TUMonline"])
        XCTAssertEqual(controller.signInOffers["r1"]?.logins.count, 2)
        // Sent again under the same request id: the phone updates the request it has
        let (events, _) = await controller.companion.events(since: 0, timeout: 0)
        XCTAssertEqual(events.filter { $0.request == "r1" }.count, 1)
    }

    func testEventsCarryLoginsWithoutSecrets() throws {
        let event = CompanionEvent(event: "signin", request: "r", agent: "Claude Code", host: "github.com", field: "password",
                                   logins: [CompanionLogin(id: "a", name: "GitHub", username: "max", totp: true)],
                                   bitwarden: "unlocked")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertTrue(json.contains(#""bitwarden":"unlocked""#))
        XCTAssertTrue(json.contains(#""logins":[{"id":"a","name":"GitHub","totp":true,"username":"max"}]"#))
        XCTAssertEqual(try JSONDecoder().decode(CompanionEvent.self, from: Data(json.utf8)).logins?.first?.name, "GitHub")
    }
}

final class HostMatchingTests: XCTestCase {
    func testExamplesFromTheDesign() {
        XCTAssertTrue(HostMatching.matches(uriHost: "amazon.de", requestHost: "www.amazon.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "login.tum.de", requestHost: "campus.tum.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "de", requestHost: "www.amazon.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "de", requestHost: "amazon.de"))
    }

    func testEqualHostsAndChildren() {
        XCTAssertTrue(HostMatching.matches(uriHost: "WWW.Amazon.DE.", requestHost: "www.amazon.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "www.amazon.de", requestHost: "amazon.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "amazon.de", requestHost: "notamazon.de"))
        XCTAssertFalse(HostMatching.matches(uriHost: "amazon.de", requestHost: "amazon.de.evil.com"))
        XCTAssertTrue(HostMatching.matches(uriHost: "tum.de", requestHost: "login.campus.tum.de"))
    }

    func testIPAddressesOnlyMatchExactly() {
        XCTAssertTrue(HostMatching.matches(uriHost: "192.168.1.1", requestHost: "192.168.1.1"))
        XCTAssertFalse(HostMatching.matches(uriHost: "168.1.1", requestHost: "192.168.1.1"))
        XCTAssertTrue(HostMatching.matches(uriHost: "[fe80::1]", requestHost: "fe80::1"))
    }

    func testHostsOfStoredURIs() {
        XCTAssertEqual(HostMatching.host(ofURI: "https://www.amazon.de/ap/signin?x=1"), "www.amazon.de")
        XCTAssertEqual(HostMatching.host(ofURI: "amazon.de"), "amazon.de")
        XCTAssertEqual(HostMatching.host(ofURI: "amazon.de:8443/login"), "amazon.de")
        XCTAssertEqual(HostMatching.host(ofURI: "http://User@Example.COM"), "example.com")
        XCTAssertNil(HostMatching.host(ofURI: "androidapp://com.amazon.mShop"))
        XCTAssertNil(HostMatching.host(ofURI: "  "))
        let uris = ["androidapp://de.tum.app", "https://campus.tum.de/tumonline", "moodle.tum.de"]
        XCTAssertTrue(HostMatching.matches(uris: uris, requestHost: "campus.tum.de"))
        XCTAssertTrue(HostMatching.matches(uris: uris, requestHost: "www.moodle.tum.de"))
        XCTAssertFalse(HostMatching.matches(uris: uris, requestHost: "login.tum.de"))
    }
}

final class InteractiveSubprocessTests: XCTestCase {
    func testQuestionsOnTheTerminalResultOnStdout() async throws {
        let script = #"printf '? Code: ' >&2; read c; [ -t 0 ] && t=tty || t=pipe; printf '{"got":"%s","stdin":"%s"}\n' "$c" "$t""#
        let process = try Subprocess.interactive("/bin/sh", ["-c", script], timeout: 20)
        var seen = ""
        for await chunk in process.terminal {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("Code:") && !seen.contains("42") { process.send(Data("42\r".utf8)) }
        }
        let result = await process.result()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "{\"got\":\"42\",\"stdin\":\"tty\"}\n")
    }

    func testTerminateEndsIt() async throws {
        let process = try Subprocess.interactive("/bin/sleep", ["30"], timeout: 60)
        let start = Date()
        process.terminate()
        let result = await process.result()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
