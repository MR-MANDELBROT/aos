import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import aOS
@testable import ScreenClient

/// The Mac's password into its lock screen (`MacUnlock`, `ScreenSession`'s unlock): only when the Mac reports this
/// account's screen locked, a password field in front, and the password can be typed there.
struct MacUnlockTests {
    private func lock(_ state: String, user: String = "max", name: String? = "Max Marquart") -> MacStatus.ScreenLock {
        MacStatus.ScreenLock(state: state, user: user, name: name)
    }

    @Test func typesOnlyIntoTheLockedScreenOfTheSameAccount() {
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "max", password: "geheim 1!", secureInput: true) == .type)
        // The full name works too (screen sharing takes either), case and spaces aside
        #expect(MacUnlock.verdict(lock: lock("locked"), username: " max marquart ", password: "pw", secureInput: true) == .type)
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "MAX", password: "pw", secureInput: true) == .type)
    }

    @Test func everyDoubtIsASkip() {
        // Unlocked, another session in front, a state this app doesn't know, no state at all
        #expect(MacUnlock.verdict(lock: lock("unlocked"), username: "max", password: "pw", secureInput: true) == .skip(.unlocked))
        #expect(MacUnlock.verdict(lock: lock("away"), username: "max", password: "pw", secureInput: true) == .skip(.away))
        #expect(MacUnlock.verdict(lock: lock("screensaver"), username: "max", password: "pw", secureInput: true) == .skip(.unknown))
        #expect(MacUnlock.verdict(lock: nil, username: "max", password: "pw", secureInput: true) == .skip(.unknown))
        // Another account's lock screen
        #expect(MacUnlock.verdict(lock: lock("locked", user: "anna", name: "Anna"), username: "max", password: "pw",
                                  secureInput: true) == .skip(.otherAccount("anna")))
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "", password: "pw", secureInput: true) == .skip(.otherAccount("max")))
        // No password field reported
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "max", password: "pw", secureInput: false) == .skip(.noPasswordField))
        // Characters a Mac password field doesn't take over screen sharing, and no password
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "max", password: "Größe", secureInput: true) == .skip(.unsupportedCharacters))
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "max", password: "tab\there", secureInput: true) == .skip(.unsupportedCharacters))
        #expect(MacUnlock.verdict(lock: lock("locked"), username: "max", password: "", secureInput: true) == .skip(.unsupportedCharacters))
    }

    @Test func onlyALockedMacsSkipsAreSaid() {
        #expect(!MacUnlock.Skip.unlocked.isWorthSaying)
        #expect(!MacUnlock.Skip.unknown.isWorthSaying)
        #expect(!MacUnlock.Skip.away.isWorthSaying)
        #expect(MacUnlock.Skip.noPasswordField.isWorthSaying)
        #expect(MacUnlock.Skip.otherAccount("anna").isWorthSaying)
        #expect(MacUnlock.Skip.unsupportedCharacters.isWorthSaying)
    }

    @Test func whatCanBeTypedIsWhatTheSessionTypes() {
        for password in ["pw", "Pa55 w0rd!~", "äöü", "emoji😀", "line\nbreak", "", " "] {
            #expect(MacUnlock.canType(password) == SessionController.typesAsPassword(password), "\(password)")
        }
        #expect(MacUnlock.canType(" !\"#$%&'()*+,-./09:;<=>?@AZ[\\]^_`az{|}~"))
    }

    @Test func afterTypingOnlyUnlockedCountsAsWorking() {
        #expect(MacUnlock.outcome(lock("unlocked")) == .unlocked)
        #expect(MacUnlock.outcome(lock("locked")) == .stillLocked)
        #expect(MacUnlock.outcome(lock("away")) == .unknown)
        #expect(MacUnlock.outcome(nil) == .unknown)
    }

    @Test func theMacStatusCarriesTheLockState() throws {
        let line = #"{"screen":{"state":"locked","user":"max","name":"Max Marquart"},"display":{"state":"on","external":0}}"#
        let object = try #require(JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).object)
        #expect(MacStatus(object).screen == MacStatus.ScreenLock(state: "locked", user: "max", name: "Max Marquart"))
        #expect(MacStatus(object).screen?.isLocked == true)
        // An older aOS doesn't say; an entry without its account counts as not said
        let old = try #require(JSONDecoder().decode(JSONValue.self, from: Data(#"{"display":{"state":"on","external":0}}"#.utf8)).object)
        #expect(MacStatus(old).screen == nil)
        let noUser = try #require(JSONDecoder().decode(JSONValue.self, from: Data(#"{"screen":{"state":"locked","user":""}}"#.utf8)).object)
        #expect(MacStatus(noUser).screen == nil)
    }

    @MainActor
    @Test func aLockScreenThatDidntTakeThePasswordIsRemembered() {
        let name = "unlock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.screenUnlocksMac)  // on by default
        #expect(ScreenOptions(settings: settings).unlocksMac)
        let mac = UUID()
        #expect(!settings.unlockFailed(for: mac))
        settings.noteUnlock(false, for: mac)
        #expect(AppSettings(defaults: defaults).unlockFailed(for: mac))
        #expect(!AppSettings(defaults: defaults).unlockFailed(for: UUID()))
        settings.noteUnlock(nil, for: mac)  // a new login
        #expect(!AppSettings(defaults: defaults).unlockFailed(for: mac))
        settings.screenUnlocksMac = false
        #expect(!ScreenOptions(settings: AppSettings(defaults: defaults)).unlocksMac)
    }
}

/// Whether a login is saved is read without Face ID: the keychain items' attributes only.
@MainActor
@Suite(.serialized)
struct MacLoginPresenceTests {
    @Test func theSavedLoginIsSeenWithoutReadingIt() throws {
        let saved = SecretStore.screenService
        SecretStore.screenService = "dev.marquart.aos.tests.macscreen-\(UUID().uuidString.prefix(8))"
        defer {
            Keychain.deleteAll(service: SecretStore.screenService)
            SecretStore.screenService = saved
        }
        let mac = PairedMac(name: "Mac", hosts: ["127.0.0.1"], sshPort: 22, user: "max", hostKey: "",
                            hostKeyFingerprint: "SHA256:x", companionPath: "/x")
        #expect(!SecretStore.hasScreenLogin(for: mac))
        // The simulator has no passcode, so an item behind user presence can't be kept there; one readable while
        // unlocked stands in for it (the presence check reads attributes either way).
        try Keychain.setJSON(SecretStore.ScreenLogin(username: "max", password: "pw"), service: SecretStore.screenService,
                             account: mac.id.uuidString, protection: .whenUnlocked)
        #expect(SecretStore.hasScreenLogin(for: mac))
        #expect(!SecretStore.hasScreenLogin(for: PairedMac(name: "Other", hosts: ["127.0.0.2"], sshPort: 22, user: "max",
                                                           hostKey: "", hostKeyFingerprint: "SHA256:y", companionPath: "/x")))
        SecretStore.deleteScreenLogin(for: mac)
        #expect(!SecretStore.hasScreenLogin(for: mac))
    }
}

/// "Type Password" is offered on the Mac's own screen only, after the keyboard in the toolbar.
@MainActor
struct TypePasswordCommandTests {
    @Test func onlyWhereAOSHandlesIt() {
        #expect(ToolbarLayout.mac.defaultBar.contains(.typePassword))
        if let keyboard = ToolbarLayout.mac.defaultBar.firstIndex(of: .keyboard) {
            #expect(ToolbarLayout.mac.defaultBar.firstIndex(of: .typePassword) == keyboard + 1)
        }
        #expect(SessionCommand.typePassword.applies(to: .mac))
        #expect(!SessionCommand.typePassword.applies(to: .iOS))
        #expect(!SessionCommand.typePassword.applies(to: .pc))
        let session = ScreenClientSession(screen: UUID(), name: "Workspace", port: 9, login: .none, followsWindowShape: true)
        defer { session.close() }
        // The workspace: no handler, not offered
        #expect(!SessionCommand.typePassword.isOffered(by: session.controller))
        session.onTypePassword = {}
        #expect(SessionCommand.typePassword.isOffered(by: session.controller))
    }
}

/// The unlock and Type Password against a screen sharing server in the test (plain RFB, which reports secure input as
/// Apple's screen sharing does when told to): what it types, and when it doesn't.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MacUnlockSessionTests {
    final class Locks {
        var answers: [MacStatus.ScreenLock?]
        var asked = 0
        init(_ answers: [MacStatus.ScreenLock?]) { self.answers = answers }
        /// The answers in turn; the last one stays.
        func next() -> MacStatus.ScreenLock? {
            defer { asked += 1 }
            return answers[min(asked, answers.count - 1)]
        }
    }

    /// A portrait picture: Open Screen Sharing turns the iPhone to a Mac picture's orientation, and the screen's layout
    /// tests, running meanwhile, need it upright.
    private static func server() async throws -> FakeRFBServer { try await FakeRFBServer.start(width: 48, height: 64) }

    private static let locked = MacStatus.ScreenLock(state: "locked", user: "max", name: "Max Marquart")
    private static let unlocked = MacStatus.ScreenLock(state: "unlocked", user: "max", name: "Max Marquart")
    private let login = SecretStore.ScreenLogin(username: "max", password: "pw!")
    /// "pw!" and Return
    private let typedWithReturn: [UInt32] = [0x70, 0x77, 0x21, 0xff0d]

    private func connect(_ server: FakeRFBServer, _ locks: Locks) async throws -> ScreenSession {
        ScreenSession.unlockCheckInterval = .milliseconds(50)
        ScreenSession.appIsActive = { true }
        let session = ScreenSession(target: .mac)
        session.startMacForTesting(host: "127.0.0.1", port: server.port, login: login) { locks.next() }
        // As on the Screen tab: the session's view connects it and draws its picture
        let client = try #require(session.client)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for old in windows { old.isHidden = true }
        windows = []
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ScreenClientView(session: client) {})
        // Shown, but behind and never key: other suites (the screen's layout, the keyboard) run meanwhile
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isHidden = false
        windows.append(window)
        try await waitUntil(timeout: .seconds(20)) { client.state == .connected }
        try await waitUntil(timeout: .seconds(20)) { client.hasPicture }
        return session
    }

    private func finish(_ session: ScreenSession) {
        session.stop()
        for window in windows { window.isHidden = true }
        windows = []
    }

    /// The windows the sessions are shown in (until the test ends).
    private var windows: [UIWindow] { get { Self.shown } nonmutating set { Self.shown = newValue } }
    private static var shown: [UIWindow] = []

    @Test func aLockedMacGetsThePasswordAndReturnOnce() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        server.log.reportsSecureInput = true
        let locks = Locks([Self.locked, Self.locked, Self.unlocked])
        let session = try await connect(server, locks)
        defer { finish(session) }
        try await waitUntil(timeout: .seconds(20)) { session.unlock != nil }
        #expect(session.unlock == .unlocked)
        #expect(server.log.typedKeysyms == typedWithReturn)
        // Asked twice before typing (at first, and right before), then until it reported unlocked
        #expect(locks.asked == 3)
    }

    @Test func anUnlockedOrSilentMacGetsNothing() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        server.log.reportsSecureInput = true
        for answer in [Self.unlocked, nil, MacStatus.ScreenLock(state: "away", user: "max")] {
            let locks = Locks([answer])
            let session = try await connect(server, locks)
            try await waitUntil(timeout: .seconds(10)) { locks.asked >= 1 }
            try? await Task.sleep(for: .milliseconds(500))
            finish(session)
            #expect(session.unlock == nil)
            #expect(locks.asked == 1)
        }
        #expect(server.log.typedKeysyms.isEmpty)
    }

    @Test func unlockedRightBeforeTypingGetsNothing() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        server.log.reportsSecureInput = true
        // Someone unlocked it at the Mac meanwhile
        let locks = Locks([Self.locked, Self.unlocked])
        let session = try await connect(server, locks)
        defer { finish(session) }
        try await waitUntil(timeout: .seconds(10)) { session.unlock != nil }
        #expect(session.unlock == .skipped(.unlocked))
        #expect(server.log.typedKeysyms.isEmpty)
    }

    @Test func withoutAPasswordFieldOnlyShiftGoesOut() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        let locks = Locks([Self.locked])
        let session = try await connect(server, locks)
        defer { finish(session) }
        try await waitUntil(timeout: .seconds(15)) { session.unlock != nil }
        #expect(session.unlock == .skipped(.noPasswordField))
        #expect(server.log.typedKeysyms.isEmpty)
        // Shift woke the lock screen, nothing else
        #expect(server.log.keyEvents.map(\.keysym) == [0xffe1, 0xffe1])
    }

    @Test func anotherAccountsLockScreenGetsNothing() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        server.log.reportsSecureInput = true
        let locks = Locks([MacStatus.ScreenLock(state: "locked", user: "anna", name: "Anna")])
        let session = try await connect(server, locks)
        defer { finish(session) }
        try await waitUntil(timeout: .seconds(10)) { session.unlock != nil }
        #expect(session.unlock == .skipped(.otherAccount("anna")))
        #expect(server.log.keyEvents.isEmpty)
    }

    /// Typed once; the Mac stayed locked: said, and not typed again (the memory per Mac: aLockScreenThatDidntTake...).
    @Test func aLockScreenThatStaysLockedIsTypedIntoOnce() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        server.log.reportsSecureInput = true
        let session = try await connect(server, Locks([Self.locked]))
        defer { finish(session) }
        try await waitUntil(timeout: .seconds(20)) { session.unlock != nil }
        #expect(session.unlock == .stayedLocked)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(server.log.typedKeysyms == typedWithReturn)
    }

    @Test func typePasswordTypesOnlyIntoAPasswordField() async throws {
        let server = try await Self.server()
        defer { Task { await server.stop() } }
        let session = ScreenClientSession(screen: UUID(), name: "Mac", port: server.port, login: .none,
                                          followsWindowShape: false)
        defer { session.close() }
        session.start()
        try await waitUntil(timeout: .seconds(30)) { session.state == .connected }
        // No password field: nothing goes out
        #expect(session.typePassword("pw!", pressingReturn: false) == .noPasswordField)
        #expect(server.log.keyEvents.isEmpty)
        server.log.reportsSecureInput = true
        try await waitUntil(timeout: .seconds(10)) { session.reportsPasswordField }
        // Characters a password field doesn't take: nothing goes out
        #expect(session.typePassword("Größe", pressingReturn: false) == .unsupportedCharacters)
        #expect(server.log.keyEvents.isEmpty)
        #expect(session.typePassword("pw!", pressingReturn: false) == .typed)
        try await waitUntil(timeout: .seconds(5)) { server.log.typedKeysyms.count == 3 }
        #expect(server.log.typedKeysyms == [0x70, 0x77, 0x21])  // no Return
    }
}
