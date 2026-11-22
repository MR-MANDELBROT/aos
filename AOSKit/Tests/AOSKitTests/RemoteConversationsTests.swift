@testable import AOSKit
import Darwin
import XCTest

/// The chats aOS's Remote Control server runs, the ones its end cuts off, and how the keeper continues them.
final class RemoteConversationsTests: XCTestCase {
    let now = Date()
    let first = RemoteConversations.Server(pid: 100, started: Date(timeIntervalSince1970: 1_000))
    let second = RemoteConversations.Server(pid: 200, started: Date(timeIntervalSince1970: 2_000))

    func child(_ pid: Int32, _ id: String) -> RemoteConversations.Child {
        RemoteConversations.Child(pid: pid, id: id, cwd: "/Users/x/cloupi")
    }

    // MARK: The record

    func testTheEndOfTheServerCutsOffTheChatsItRuns() {
        var r = RemoteConversations()
        XCTAssertTrue(r.observe([child(11, "kiosk"), child(12, "poster"), child(13, "done")], server: first, now: now))
        XCTAssertFalse(r.observe([child(11, "kiosk"), child(12, "poster"), child(13, "done")], server: first, now: now),
                       "nothing new: nothing to write")
        XCTAssertEqual(r.running.map(\.sessionId), ["done", "kiosk", "poster"])
        XCTAssertEqual(r.running.first?.entrypoint, RemoteConversations.entrypoint)
        // One ends while the server runs (it went idle, or the person ended it): the server's still, never cut off
        r.observe([child(11, "kiosk"), child(12, "poster")], server: first, now: now)
        XCTAssertTrue(r.interrupted.isEmpty, "running ones are nobody else's")
        // aOS ends the server (an update)
        let cut = r.serverEnded(first, interrupting: true, now: now)
        XCTAssertEqual(cut, ["kiosk", "poster"])
        XCTAssertEqual(Set(r.interrupted.keys), ["kiosk", "poster"])
        XCTAssertNil(r.server)
        XCTAssertTrue(r.running.isEmpty)
    }

    func testTurnedOffInTheSettingsCutsNothingOff() {
        var r = RemoteConversations()
        r.observe([child(11, "chat")], server: first, now: now)
        XCTAssertEqual(r.serverEnded(first, interrupting: false, now: now), [])
        XCTAssertTrue(r.interrupted.isEmpty)
    }

    func testTheNextServerServingItAgainTakesItBack() {
        var r = RemoteConversations()
        r.observe([child(11, "chat")], server: first, now: now)
        r.serverEnded(first, interrupting: true, now: now)
        XCTAssertEqual(Array(r.interrupted.keys), ["chat"])
        // The next server runs: nothing of its own yet
        r.observe([], server: second, now: now)
        XCTAssertEqual(Array(r.interrupted.keys), ["chat"], "still cut off")
        // The person wrote in the old chat, the new server runs it again: not the keeper's any more
        r.observe([child(21, "chat")], server: second, now: now)
        XCTAssertTrue(r.interrupted.isEmpty)
        XCTAssertEqual(r.running.map(\.pid), [21])
        // An end of a server that isn't the one running it changes nothing
        r.serverEnded(first, interrupting: true, now: now)
        XCTAssertTrue(r.interrupted.isEmpty)
    }

    func testEndedOrArchivedByThePersonIsForgotten() {
        var r = RemoteConversations()
        r.observe([child(11, "chat")], server: first, now: now)
        r.serverEnded(first, interrupting: true, now: now)
        r.dismiss("chat")
        XCTAssertTrue(r.interrupted.isEmpty)
    }

    func testOldEntriesAreForgotten() {
        var r = RemoteConversations()
        r.observe([child(11, "old")], server: first, now: now.addingTimeInterval(-40 * 24 * 3600))
        r.serverEnded(first, interrupting: true, now: now.addingTimeInterval(-40 * 24 * 3600))
        r.observe([child(21, "new")], server: second, now: now)
        r.serverEnded(second, interrupting: true, now: now)
        XCTAssertEqual(Array(r.interrupted.keys), ["new"])
    }

    func testOnDiskAndAfterAnAbruptEnd() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-remote-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true)
        XCTAssertEqual(RemoteConversations.read(paths), RemoteConversations(), "nothing yet")
        RemoteConversations.update(paths) { $0.observe([self.child(11, "chat")], server: self.first, now: self.now) }
        // aos-session ended without ending its server (2026-11-22: SIGPIPE): the next one finds the run still noted
        let previous = try XCTUnwrap(RemoteConversations.read(paths).server)
        XCTAssertEqual(previous, first)
        let cut = RemoteConversations.update(paths) { $0.serverEnded(previous, interrupting: true, now: self.now) }
        XCTAssertEqual(cut, ["chat"])
        XCTAssertEqual(Array(RemoteConversations.read(paths).interrupted.keys), ["chat"])
    }

    // MARK: Processes

    func testTheProcessTreeAndCommandLine() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["7"]
        try p.run()
        defer { p.terminate() }
        let pid = p.processIdentifier
        XCTAssertTrue(ProcessTree.children(of: getpid()).contains(pid))
        XCTAssertTrue(ProcessTree.descendants(of: getpid()).contains(pid))
        XCTAssertEqual(ProcessTree.arguments(of: pid), ["/bin/sleep", "7"])
        XCTAssertEqual(ProcessTree.option("--session-id", in: ["claude", "--print", "--session-id", "abc"]), "abc")
        XCTAssertEqual(ProcessTree.option("--session-id", in: ["claude", "--session-id=abc"]), "abc")
        XCTAssertNil(ProcessTree.option("--session-id", in: ["claude", "--session-id"]))
        XCTAssertTrue(RemoteServer.children(of: getpid(), folder: "/").isEmpty, "no Claude Code below the tests")
    }

    func testAnUpdateWaitsForTurnsAtMostHalfAnHour() {
        XCTAssertFalse(UpdateRestart.shouldWait(busy: 0, noticed: now, now: now), "nothing works: at once")
        XCTAssertTrue(UpdateRestart.shouldWait(busy: 2, noticed: now, now: now.addingTimeInterval(60)))
        XCTAssertFalse(UpdateRestart.shouldWait(busy: 2, noticed: now, now: now.addingTimeInterval(31 * 60)))
    }

    // MARK: The keeper's selection

    func conversation(_ id: String, origin: String = "sdk-cli", hoursAgo: Double = 1, cwd: String = "/Users/x/cloupi",
                      mode: String? = nil) -> ClaudeConversation {
        var c = ClaudeConversation(id: id, cwd: cwd, title: id, lastActivity: now.addingTimeInterval(-hoursAgo * 3600),
                                   usedRemoteControl: origin != "sdk-cli", startedIn: origin, desktop: nil)
        c.permissionMode = mode
        return c
    }

    func settings() -> AgentSettings {
        var s = AgentSettings()
        s.keepReachable = true
        s.keepHours = 48
        s.keepMax = 3
        return s
    }

    func testTheServersChatsAreKeptOnlyWhenItsEndCutThemOff() {
        let s = settings()
        let kiosk = conversation("kiosk", hoursAgo: 3)
        let idle = conversation("idle")
        let cut = ["kiosk": now.addingTimeInterval(-60)]
        XCTAssertEqual(SessionKeeper.select([kiosk, idle], settings: s, exclude: "/aOS/Session", now: now).map(\.0.id), [],
                       "they look like automation")
        XCTAssertEqual(SessionKeeper.select([kiosk, idle], settings: s, exclude: "/aOS/Session", interrupted: cut, now: now)
                        .map(\.0.id), ["kiosk"], "the one cut off, not the one the server still has")
        XCTAssertEqual(SessionKeeper.reason(idle, settings: s, exclude: "/aOS/Session", interrupted: cut, kept: ["kiosk"],
                                            now: now), .automation)
        XCTAssertNil(SessionKeeper.reason(kiosk, settings: s, exclude: "/aOS/Session", interrupted: cut, kept: ["kiosk"],
                                          now: now))
    }

    func testCutOffChatsComeFirstAfterThePinnedOnes() {
        var s = settings()
        s.keepMax = 3
        s.keptConversations = ["pinned"]
        let list = [conversation("app-1", origin: "claude-desktop", hoursAgo: 0.1),
                    conversation("app-2", origin: "claude-desktop", hoursAgo: 0.2),
                    conversation("pinned", origin: "claude-desktop", hoursAgo: 100),
                    conversation("kiosk", hoursAgo: 5)]
        let chosen = SessionKeeper.select(list, settings: s, exclude: "/aOS/Session", interrupted: ["kiosk": now], now: now)
        XCTAssertEqual(chosen.map(\.0.id), ["pinned", "kiosk", "app-1"], "within keepMax, before more recent ones")
        XCTAssertEqual(chosen.map(\.pinned), [true, false, false])
    }

    func testTheRulesStillHoldForCutOffChats() {
        var s = settings()
        let at = now.addingTimeInterval(-60)
        func reason(_ c: ClaudeConversation, own: String? = nil, cutAt: Date? = nil) -> KeepReason? {
            SessionKeeper.reason(c, settings: s, exclude: "/aOS/Session", ownConversation: own,
                                 interrupted: [c.id: cutAt ?? at], kept: [c.id], now: now)
        }
        XCTAssertEqual(reason(conversation("own"), own: "own"), .ownSession, "aOS's own session, by its id")
        XCTAssertNil(reason(conversation("in-aos", cwd: "/aOS/Session")), "a chat of the server in aOS's folder is no session's")
        XCTAssertEqual(SessionKeeper.reason(conversation("earlier", origin: "cli", cwd: "/aOS/Session"), settings: s,
                                            exclude: "/aOS/Session", kept: ["earlier"], now: now), .ownSession,
                       "earlier conversations of the session in its folder stay out")
        XCTAssertEqual(reason(conversation("old", hoursAgo: 100), cutAt: now.addingTimeInterval(-49 * 3600)), .inactive,
                       "keepHours after it was cut off")
        XCTAssertNil(reason(conversation("long-turn", hoursAgo: 100)), "a turn that ran long counts from its end")
        s.skippedConversations = ["skipped"]
        XCTAssertEqual(reason(conversation("skipped")), .skipped)
        s.keepAutomatic = false
        XCTAssertEqual(reason(conversation("only-pinned")), .onlyPinned)
        s.keptConversations = ["only-pinned"]
        XCTAssertNil(reason(conversation("only-pinned")))
    }

    func testThePermissionModeItContinuesIn() {
        XCTAssertEqual(SessionKeeper.permissionMode(conversation("a", mode: "auto"), fromServer: true), "auto",
                       "the mode its transcript names")
        XCTAssertEqual(SessionKeeper.permissionMode(conversation("b"), fromServer: true), "default", "else the server's")
        XCTAssertEqual(SessionKeeper.permissionMode(conversation("c", mode: "bypassPermissions"), fromServer: true), "default",
                       "never bypassing permissions")
        XCTAssertNil(SessionKeeper.permissionMode(conversation("d", origin: "cli", mode: "auto"), fromServer: false),
                     "a terminal's: Claude Code's own, as before")
        var desktop = conversation("e", origin: "claude-desktop")
        desktop.desktop = .init(archived: false, scheduled: false, permissionMode: "acceptEdits",
                                remoteControlTurnedOff: false, title: nil)
        XCTAssertEqual(SessionKeeper.permissionMode(desktop, fromServer: false), "acceptEdits")
        desktop.desktop?.permissionMode = "bypassPermissions"
        XCTAssertNil(SessionKeeper.permissionMode(desktop, fromServer: false))
    }

    // MARK: Transcripts

    func testTheListIncludesTheServersChatsOnlyWhenAsked() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aos-rc-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let projects = folder.appendingPathComponent("projects/-Users-x-cloupi")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let sources = ClaudeConversations.Sources(projects: folder.appendingPathComponent("projects"),
                                                  desktop: folder.appendingPathComponent("desktop"))
        // A chat the server ran (as its transcript looks: sdk-cli, the phone's prompt, its permission mode)
        var chat = Transcript(in: projects, entrypoint: "sdk-cli")
        chat.prompt(now.addingTimeInterval(-3600))
        chat.reply(now.addingTimeInterval(-3500))
        chat.add(["type": "permission-mode", "permissionMode": "auto"])
        try chat.write()
        XCTAssertEqual(ClaudeConversations.list(within: 48 * 3600, pinned: [], limit: 10, sources: sources).map(\.id), [],
                       "automation is never listed")
        let listed = ClaudeConversations.list(within: 48 * 3600, pinned: [], limit: 10, include: [chat.id], sources: sources)
        XCTAssertEqual(listed.map(\.id), [chat.id])
        XCTAssertEqual(listed.first?.permissionMode, "auto")
        // Also when it is older than the window (a long turn)
        XCTAssertEqual(ClaudeConversations.list(within: 600, pinned: [], limit: 0, include: [chat.id], sources: sources)
                        .map(\.id), [chat.id])
    }
}
