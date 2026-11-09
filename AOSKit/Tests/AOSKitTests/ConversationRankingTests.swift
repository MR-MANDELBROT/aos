@testable import AOSKit
import Darwin
import XCTest

/// Synthetic transcripts the way Claude Code writes them (only the fields aOS reads, made-up text).
struct Transcript {
    let id: String
    let file: URL
    var cwd = "/Users/x/project"
    var entrypoint = "claude-desktop"
    private(set) var lines: [String] = []

    init(in folder: URL, id: String = UUID().uuidString.lowercased(), entrypoint: String = "claude-desktop") {
        self.id = id
        self.entrypoint = entrypoint
        file = folder.appendingPathComponent("\(id).jsonl")
    }

    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    mutating func add(_ object: [String: Any]) {
        var o = object
        if o["sessionId"] == nil { o["sessionId"] = id }
        lines.append(String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self))
    }

    private func base(_ type: String, _ at: Date) -> [String: Any] {
        ["type": type, "timestamp": Self.stamp(at), "cwd": cwd, "entrypoint": entrypoint, "uuid": UUID().uuidString,
         "isSidechain": false, "userType": "external"]
    }

    /// Something the person typed (newer Claude Code marks it `origin.kind: human`; older versions don't say).
    mutating func prompt(_ at: Date, origin: String? = "human", meta: Bool = false) {
        var o = base("user", at)
        o["message"] = ["role": "user", "content": "Hallo"]
        o["promptId"] = UUID().uuidString
        if let origin { o["origin"] = ["kind": origin] }
        if meta { o["isMeta"] = true }
        add(o)
    }

    mutating func reply(_ at: Date, model: String = "claude-opus-5-5", apiError: Bool = false, sidechain: Bool = false) {
        var o = base("assistant", at)
        o["message"] = ["role": "assistant", "model": model, "content": [["type": "text", "text": "Gern."]]]
        if apiError { o["isApiErrorMessage"] = true }
        if sidechain { o["isSidechain"] = true }
        add(o)
    }

    /// A tool call and its result (the result is a user record).
    mutating func tool(_ at: Date) {
        var use = base("assistant", at)
        use["message"] = ["role": "assistant", "model": "claude-opus-5-5",
                          "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]]
        add(use)
        var result = base("user", at.addingTimeInterval(1))
        result["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "a b"]]]
        result["toolUseResult"] = ["stdout": "a b"]
        result["sourceToolAssistantUUID"] = "x"
        add(result)
    }

    /// What `claude --resume <id> --remote-control` appends when the keeper starts it (seen in real transcripts).
    mutating func keeperStart(_ at: Date, padding: Int = 0) {
        add(["type": "bridge-session", "bridgeSessionId": "cse_1", "lastSequenceNum": 3])
        add(["type": "cost-state", "totalCostUSD": 0, "modelUsage": ["padding": String(repeating: "x", count: padding)]])
        add(["type": "last-prompt", "lastPrompt": "Hallo", "leafUuid": "l"])
        add(["type": "cost-state", "totalCostUSD": 0])
        add(["type": "bridge-session", "bridgeSessionId": "cse_2", "lastSequenceNum": 0])
        var status = base("system", at)
        status["subtype"] = "bridge_status"
        status["isMeta"] = true
        status["content"] = "Remote Control connected"
        add(status)
    }

    mutating func compaction(_ at: Date) {
        var boundary = base("system", at)
        boundary["subtype"] = "compact_boundary"
        add(boundary)
        var summary = base("user", at)
        summary["message"] = ["role": "user", "content": "Summary of the conversation"]
        summary["isCompactSummary"] = true
        summary["isVisibleInTranscriptOnly"] = true
        add(summary)
    }

    mutating func title(_ text: String) { add(["type": "ai-title", "aiTitle": text]) }

    var text: String { lines.map { $0 + "\n" }.joined() }

    func write() throws { try text.write(to: file, atomically: true, encoding: .utf8) }

    /// Appends the lines after `count` (the file grows, as Claude Code's does).
    func append(after count: Int) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.dropFirst(count).map { $0 + "\n" }.joined().utf8))
    }
}

final class ConversationRankingTests: XCTestCase {
    var folder: URL!
    let now = Date()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aos-rank-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    func read(_ t: Transcript) throws -> ClaudeConversation {
        try XCTUnwrap(ClaudeConversations.read(t.file, modified: now))
    }

    func assertSame(_ a: Date?, _ b: Date, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no date: \(message)", file: file, line: line) }
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: The person's last activity

    func testTheKeepersOwnStartsAreNoActivity() throws {
        // The person last wrote three days ago; the keeper started it again twice since (each start appends Remote
        // Control's bookkeeping, so the file looks fresh).
        var t = Transcript(in: folder)
        t.prompt(ago(72))
        t.tool(ago(71.99))
        t.reply(ago(71.98))
        t.keeperStart(ago(5))
        t.keeperStart(ago(1))
        try t.write()
        let c = try read(t)
        assertSame(c.lastActivity, ago(71.98), "the last answer in the person's turn")
        XCTAssertTrue(c.usedRemoteControl)
    }

    func testPromptsAndAnswersOfThePersonsTurnsCount() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(2))
        t.tool(ago(1.9))
        t.reply(ago(1.5))
        try t.write()
        assertSame(try read(t).lastActivity, ago(1.5))
        // A new prompt without an answer yet
        t.prompt(ago(0.2))
        try t.write()
        assertSame(try read(t).lastActivity, ago(0.2))
    }

    func testTurnsAutomationStartedDontCount() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(5))
        t.reply(ago(4.9))
        // A background task's notification, a channel (Cloupi's scheduler), another agent: each starts a turn
        t.prompt(ago(3), origin: "task-notification")
        t.reply(ago(2.9))
        t.prompt(ago(2), origin: "channel", meta: true)
        t.tool(ago(1.9))
        t.reply(ago(1.8))
        t.prompt(ago(1), origin: "peer", meta: true)
        t.reply(ago(0.9))
        try t.write()
        assertSame(try read(t).lastActivity, ago(4.9))
    }

    func testWhatIsNoActivity() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(10), origin: nil)  // older Claude Code: no origin, the person's
        t.reply(ago(9.9))
        t.prompt(ago(8), origin: nil, meta: true)  // a reminder Claude Code added
        t.compaction(ago(7))
        t.reply(ago(6), apiError: true)
        t.reply(ago(5), model: "<synthetic>")
        t.reply(ago(4), sidechain: true)
        t.keeperStart(ago(3))
        t.title("Rechnungen")
        try t.write()
        let c = try read(t)
        assertSame(c.lastActivity, ago(9.9))
        XCTAssertEqual(c.title, "Rechnungen")
        XCTAssertEqual(c.cwd, "/Users/x/project")
        XCTAssertEqual(c.startedIn, "claude-desktop")
    }

    func testAnInterruptionIsThePersons() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(3))
        t.reply(ago(2.9))
        // "[Request interrupted by user]": a user record without origin
        t.prompt(ago(2.5), origin: nil)
        try t.write()
        assertSame(try read(t).lastActivity, ago(2.5))
    }

    func testTheLastMessageFarBackIsFound() throws {
        // More than a reading window (1 MB) of bookkeeping after the person's last message.
        var t = Transcript(in: folder)
        t.prompt(ago(30))
        t.reply(ago(29.9))
        for i in 0..<12 { t.keeperStart(ago(Double(20 - i)), padding: 200_000) }
        try t.write()
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: t.file.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 2 << 20)
        assertSame(try read(t).lastActivity, ago(29.9))
    }

    func testWithoutThePersonsActivityTheOldestTimeOrTheDesktopAppsCounts() throws {
        // Only automation ever wrote in it: its beginning, not the file's time.
        var t = Transcript(in: folder, entrypoint: "cli")
        t.prompt(ago(40), origin: "channel", meta: true)
        t.reply(ago(39))
        t.keeperStart(ago(1))
        try t.write()
        assertSame(try read(t).lastActivity, ago(40))
        // The desktop app knows when it was used last
        let desktop = ClaudeConversation.DesktopInfo(archived: false, scheduled: false, permissionMode: nil,
                                                     remoteControlTurnedOff: false, title: "Vom Desktop",
                                                     lastActivity: ago(20))
        let c = try XCTUnwrap(ClaudeConversations.read(t.file, modified: now, desktop: desktop))
        assertSame(c.lastActivity, ago(20))
        XCTAssertEqual(c.title, "Vom Desktop")
    }

    // MARK: Reading on from where it was read

    func testAGrowingTranscriptIsReadOnFromWhereItStopped() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(5))
        t.reply(ago(4.9))
        try t.write()
        let first = try XCTUnwrap(TranscriptScan.read(t.file, after: nil))
        assertSame(first.activity, ago(4.9))

        // The keeper's bookkeeping appended: read on, the activity stays
        var count = t.lines.count
        t.keeperStart(ago(1))
        try t.append(after: count)
        let handle = try FileHandle(forReadingFrom: t.file)
        var info = stat()
        fstat(handle.fileDescriptor, &info)
        let grown = try XCTUnwrap(first.continued(handle, id: t.id, inode: UInt64(info.st_ino), size: UInt64(info.st_size)),
                                  "only the appended part")
        try handle.close()
        assertSame(grown.activity, ago(4.9))
        XCTAssertTrue(grown.bridge)
        XCTAssertEqual(grown.end, UInt64(info.st_size))

        // A new message: read on, the activity moves
        count = t.lines.count
        t.prompt(ago(0.1))
        try t.append(after: count)
        let newer = try XCTUnwrap(TranscriptScan.read(t.file, after: grown))
        assertSame(newer.activity, ago(0.1))
        // The same as reading it all anew
        let anew = try XCTUnwrap(TranscriptScan.read(t.file, after: nil))
        XCTAssertEqual(newer.activity, anew.activity)
        XCTAssertEqual(newer.end, anew.end)
        XCTAssertEqual(newer.startCwd, anew.startCwd)
        XCTAssertEqual(newer.aiTitle, anew.aiTitle)
    }

    func testAnAnswerAfterAnAutomatedPromptReadEarlierDoesntCount() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(5))
        t.reply(ago(4.9))
        t.prompt(ago(2), origin: "task-notification")
        try t.write()
        let first = try XCTUnwrap(TranscriptScan.read(t.file, after: nil))
        XCTAssertEqual(first.turn, .automation)
        let count = t.lines.count
        t.reply(ago(1.9))
        try t.append(after: count)
        assertSame(TranscriptScan.read(t.file, after: first)?.activity, ago(4.9), "the turn read before was automation's")
    }

    func testALineStillBeingWrittenIsReadOnceItIsComplete() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(5))
        try t.write()
        let first = try XCTUnwrap(TranscriptScan.read(t.file, after: nil))
        // Half a line: not read yet
        var more = t
        more.reply(ago(1))
        let line = Data((more.lines.last! + "\n").utf8)
        let handle = try FileHandle(forWritingTo: t.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.prefix(40))
        let half = try XCTUnwrap(TranscriptScan.read(t.file, after: first))
        assertSame(half.activity, ago(5))
        XCTAssertEqual(half.end, first.end)
        assertSame(TranscriptScan.read(t.file, after: nil)?.activity, ago(5), "also when read anew")
        try handle.write(contentsOf: line.dropFirst(40))
        try handle.close()
        assertSame(TranscriptScan.read(t.file, after: half)?.activity, ago(1))
    }

    func testATranscriptWrittenAnewIsReadAnew() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(1))
        t.reply(ago(0.9))
        try t.write()
        let first = try XCTUnwrap(TranscriptScan.read(t.file, after: nil))
        // Replaced by an older version of itself, longer than before (a new file: atomically written)
        var other = Transcript(in: folder, id: t.id)
        other.prompt(ago(9))
        other.reply(ago(8.9))
        for i in 0..<5 { other.keeperStart(ago(Double(8 - i))) }
        try other.write()
        assertSame(TranscriptScan.read(t.file, after: first)?.activity, ago(8.9))
    }

    func testTheCacheReadsOnlyWhatChanged() throws {
        var t = Transcript(in: folder)
        t.prompt(ago(3))
        t.reply(ago(2.9))
        try t.write()
        let cache = ConversationCache()
        let modified = try XCTUnwrap(ClaudeConversations.modificationDate(t.file))
        assertSame(cache.scan(t.file, modified: modified)?.activity, ago(2.9))
        let count = t.lines.count
        t.keeperStart(ago(0.5))
        try t.append(after: count)
        assertSame(cache.scan(t.file, modified: modified.addingTimeInterval(1))?.activity, ago(2.9))
    }

    // MARK: One order for the keeper and the lists

    func conversation(_ id: String, hoursAgo: Double, origin: String = "claude-desktop") -> ClaudeConversation {
        ClaudeConversation(id: id, cwd: "/tmp", title: id, lastActivity: ago(hoursAgo), usedRemoteControl: true,
                           startedIn: origin, desktop: nil, modified: now)
    }

    func testTheOrder() {
        let list = [conversation("b", hoursAgo: 2), conversation("a", hoursAgo: 2), conversation("c", hoursAgo: 1),
                    conversation("pinned", hoursAgo: 50)]
        XCTAssertEqual(ClaudeConversations.order(list, pinned: ["pinned"]).map(\.id), ["pinned", "c", "a", "b"],
                       "pinned first, then the newest; the same moment by id")
    }

    func testTheListOnDisk() throws {
        let projects = folder.appendingPathComponent("projects/-Users-x-project")
        let desktop = folder.appendingPathComponent("desktop/a/b")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let sources = ClaudeConversations.Sources(projects: folder.appendingPathComponent("projects"),
                                                  desktop: folder.appendingPathComponent("desktop"))
        // Used an hour ago; used yesterday; kept by the keeper but last used ten days ago (the file is fresh);
        // automation; pinned and old.
        var recent = Transcript(in: projects)
        recent.prompt(ago(1)); recent.reply(ago(0.99)); try recent.write()
        var yesterday = Transcript(in: projects)
        yesterday.prompt(ago(24)); yesterday.reply(ago(23.9)); try yesterday.write()
        var kept = Transcript(in: projects)
        kept.prompt(ago(240)); kept.reply(ago(239.9)); kept.keeperStart(ago(0.1)); try kept.write()
        var sdk = Transcript(in: projects, entrypoint: "sdk-cli")
        sdk.prompt(ago(0.5), origin: nil); try sdk.write()
        var old = Transcript(in: projects)
        old.prompt(ago(400)); old.reply(ago(399.9)); try old.write()
        try FileManager.default.setAttributes([.modificationDate: ago(399.9)], ofItemAtPath: old.file.path)
        // The desktop app's record of one: its title
        let record: [String: Any] = ["cliSessionId": yesterday.id, "title": "Vom Desktop", "isArchived": false,
                                     "lastActivityAt": ago(23.9).timeIntervalSince1970 * 1000]
        try JSONSerialization.data(withJSONObject: record).write(to: desktop.appendingPathComponent("local_1.json"))

        let cache = ConversationCache()
        let recentOnes = ClaudeConversations.recent(within: 48 * 3600, cache: cache, sources: sources)
        XCTAssertEqual(recentOnes.map(\.id), [sdk.id, recent.id, yesterday.id], "the kept one's fresh file doesn't make it recent")
        let list = ClaudeConversations.list(within: 48 * 3600, pinned: [old.id], limit: 1, cache: cache, sources: sources)
        XCTAssertEqual(list.map(\.id), [old.id, recent.id], "pinned (also old) first, then at most 1 more, no automation")
        let all = ClaudeConversations.list(within: 48 * 3600, pinned: [], limit: 10, cache: cache, sources: sources)
        XCTAssertEqual(all.map(\.id), [recent.id, yesterday.id])
        XCTAssertEqual(all.last?.title, "Vom Desktop")
        XCTAssertEqual(ClaudeConversations.find(kept.id, cache: cache, sources: sources)?.id, kept.id)
        // The week the settings show: the kept one comes back, in its place
        var s = AgentSettings()
        s.keepHours = 48
        s.keptConversations = [old.id]
        XCTAssertEqual(ClaudeConversations.shown(settings: s, cache: cache, sources: sources).map(\.id),
                       [old.id, recent.id, yesterday.id])
        s.keepHours = 24 * 30
        XCTAssertEqual(ClaudeConversations.shown(settings: s, cache: cache, sources: sources).map(\.id),
                       [old.id, recent.id, yesterday.id, kept.id])
    }
}
