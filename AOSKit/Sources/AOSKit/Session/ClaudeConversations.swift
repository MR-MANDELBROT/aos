import Darwin
import Foundation

/// A Claude Code conversation as it is stored on this Mac (one transcript in ~/.claude/projects).
public struct ClaudeConversation: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var cwd: String
    public var title: String
    /// When the person last used it: their last message, or the last answer of a turn they started. What Claude Code
    /// writes by itself doesn't count: a resume and Remote Control's bookkeeping (all the keeper's own processes
    /// append), hooks, compaction, titles, costs, and turns that automation started (task notifications, channels,
    /// other agents). Without such a record: the Claude desktop app's last activity, else the file's modification time.
    public var lastActivity: Date
    /// The conversation was connected to Remote Control at some point (a `bridge-session` record).
    public var usedRemoteControl: Bool
    /// Where it was started: "claude-desktop" (the Claude app), "cli" (a terminal or a tool), "sdk-cli" (automation).
    public var startedIn: String
    /// What the Claude desktop app knows about it, if it started or adopted it.
    public var desktop: DesktopInfo?
    /// When the transcript last changed. That happens for many reasons besides the person (see `lastActivity`): it
    /// orders nothing.
    public var modified: Date?

    /// An older version of a conversation the Claude desktop app continues under another session id now: starting or
    /// keeping it would resume the old state, so lists leave it out (the current one is listed instead).
    public var isOlderVersion: Bool {
        guard let current = desktop?.current, !current.isEmpty else { return false }
        return current != id
    }

    public struct DesktopInfo: Codable, Sendable, Equatable {
        public var archived: Bool
        public var scheduled: Bool
        public var permissionMode: String?
        public var remoteControlTurnedOff: Bool
        public var title: String?
        /// The desktop app's own record of the last activity (`lastActivityAt`): only while it ran the conversation.
        public var lastActivity: Date?
        /// The Claude Code session the desktop app continues the conversation in now (`cliSessionId`); its earlier
        /// ones (`priorCliSessionIds`) are older versions of the same conversation.
        public var current: String? = nil
    }
}

/// A running Claude Code process, from Claude Code's own registry (~/.claude/sessions/<pid>.json).
public struct LiveClaudeProcess: Sendable, Equatable {
    public var pid: pid_t
    public var sessionId: String
    public var cwd: String
    public var entrypoint: String   // "cli", "claude-desktop", ...
    public var name: String?
}

/// Reads what Claude Code and the Claude desktop app keep on disk. Everything here is best effort: these are
/// internal formats of Claude Code; anything unexpected is skipped, never guessed.
public enum ClaudeConversations {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var projectsFolder: URL { home.appendingPathComponent(".claude/projects") }
    public static var registryFolder: URL { home.appendingPathComponent(".claude/sessions") }
    static var desktopSessionsFolder: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Where the transcripts and the desktop app's records are (tests use folders of their own).
    public struct Sources: Sendable, Equatable {
        public var projects: URL
        public var desktop: URL

        public init(projects: URL, desktop: URL) {
            self.projects = projects
            self.desktop = desktop
        }

        public static var standard: Sources { Sources(projects: projectsFolder, desktop: desktopSessionsFolder) }
    }

    /// At most this many transcripts are read per look, the most recently changed ones.
    static let candidateLimit = 400

    /// Conversations the person used in the last `within` seconds, by their last activity (newest first). With a
    /// cache, unchanged transcripts and desktop records aren't read again, and grown transcripts only from where they
    /// were read before.
    public static func recent(within: TimeInterval, limit: Int = 60, cache: ConversationCache? = nil,
                              sources: Sources = .standard) -> [ClaudeConversation] {
        let cutoff = Date().addingTimeInterval(-within)
        let desktop = desktopRecords(in: sources.desktop, cache: cache)
        // A transcript changes whenever something is written to it, so one the person used within the window
        // changed within it too: the modification time narrows down what is read, the person's activity decides.
        var candidates: [(URL, Date)] = []
        for folder in contents(of: sources.projects) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                guard let date = modificationDate(f), date >= cutoff else { continue }
                candidates.append((f, date))
            }
        }
        candidates.sort { $0.1 > $1.1 }
        let list = candidates.prefix(candidateLimit).compactMap { file, modified in
            conversation(file, modified: modified, desktop: desktop, cache: cache)
        }.filter { $0.lastActivity >= cutoff }
        return Array(order(list, pinned: []).prefix(limit))
    }

    /// The conversations as aOS keeps and lists them: the ones used within `within` seconds and the pinned ones (also
    /// older ones), pinned first, then by the person's last activity; at most `limit` besides the pinned ones. Never
    /// automation (`sdk-cli`).
    public static func list(within: TimeInterval, pinned: [String], limit: Int, cache: ConversationCache? = nil,
                            sources: Sources = .standard) -> [ClaudeConversation] {
        let desktopNow = desktopRecords(in: sources.desktop, cache: cache)
        // An older version of a conversation the desktop app continues in another session: only the current one.
        let pinned = pinned.map { currentID($0, desktop: desktopNow) }
        var all = recent(within: within, limit: .max, cache: cache, sources: sources)
            .filter { $0.startedIn != "sdk-cli" && !$0.isOlderVersion }
        let have = Set(all.map(\.id))
        let missing = pinned.filter { !have.contains($0) }
        if !missing.isEmpty {
            let desktop = desktopRecords(in: sources.desktop, cache: cache)
            for id in missing {
                if let c = find(id, desktop: desktop, cache: cache, sources: sources), c.startedIn != "sdk-cli",
                   !c.isOlderVersion { all.append(c) }
            }
        }
        let pinnedSet = Set(pinned)
        var others = 0
        return order(all, pinned: pinnedSet).filter { c in
            if pinnedSet.contains(c.id) { return true }
            others += 1
            return others <= limit
        }
    }

    /// The id the desktop app continues a conversation under now (the id itself when it has no newer one).
    public static func currentID(_ id: String, desktop: [String: ClaudeConversation.DesktopInfo]) -> String {
        guard let current = desktop[id]?.current, !current.isEmpty else { return id }
        return current
    }

    /// Ids of older versions mapped to the current ones (pinned and skipped ids in the settings).
    public static func currentIDs(_ ids: [String], cache: ConversationCache? = nil, sources: Sources = .standard) -> [String] {
        let desktop = desktopRecords(in: sources.desktop, cache: cache)
        var out: [String] = []
        for id in ids.map({ currentID($0, desktop: desktop) }) where !out.contains(id) { out.append(id) }
        return out
    }

    /// What the settings list, on the Mac and on the iPhone: the last week (or `keepHours`, if longer) and the pinned
    /// ones.
    public static func shown(settings s: AgentSettings, cache: ConversationCache? = nil,
                             sources: Sources = .standard) -> [ClaudeConversation] {
        list(within: Double(max(s.keepHours, 168)) * 3600, pinned: s.keptConversations, limit: 40, cache: cache,
             sources: sources)
    }

    /// The one order for the keeper and every list: pinned ones first, then the person's last activity, newest first;
    /// the same moment by id, so the order doesn't flap.
    public static func order(_ list: [ClaudeConversation], pinned: Set<String>) -> [ClaudeConversation] {
        list.sorted { a, b in
            let pa = pinned.contains(a.id), pb = pinned.contains(b.id)
            if pa != pb { return pa }
            if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
            return a.id < b.id
        }
    }

    /// One conversation by id (searched in all project folders).
    public static func find(_ id: String, cache: ConversationCache? = nil, sources: Sources = .standard) -> ClaudeConversation? {
        find(id, desktop: desktopRecords(in: sources.desktop, cache: cache), cache: cache, sources: sources)
    }

    static func find(_ id: String, desktop: [String: ClaudeConversation.DesktopInfo], cache: ConversationCache?,
                     sources: Sources) -> ClaudeConversation? {
        guard UUID(uuidString: id) != nil else { return nil }
        for folder in contents(of: sources.projects) {
            let file = folder.appendingPathComponent("\(id).jsonl")
            if let modified = modificationDate(file),
               let c = conversation(file, modified: modified, desktop: desktop, cache: cache) {
                return c
            }
        }
        return nil
    }

    /// The transcript files of a conversation (its .jsonl and the folder of the same name with its subagents and tool
    /// output), wherever they are under ~/.claude/projects.
    public static func files(of id: String, sources: Sources = .standard) -> [URL] {
        guard UUID(uuidString: id) != nil else { return [] }
        var out: [URL] = []
        for folder in contents(of: sources.projects) {
            let file = folder.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: file.path) { out.append(file) }
            let dir = folder.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { out.append(dir) }
        }
        return out
    }

    static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    static func modificationDate(_ file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func conversation(_ file: URL, modified: Date, desktop: [String: ClaudeConversation.DesktopInfo],
                             cache: ConversationCache?) -> ClaudeConversation? {
        let id = file.deletingPathExtension().lastPathComponent
        let scan = cache.map { $0.scan(file, modified: modified) } ?? TranscriptScan.read(file, after: nil)
        guard let scan else { return nil }
        return conversation(scan, id: id, modified: modified, desktop: desktop[id])
    }

    /// Reads one transcript completely anew (as far as it needs to).
    static func read(_ file: URL, modified: Date, desktop: ClaudeConversation.DesktopInfo? = nil) -> ClaudeConversation? {
        guard let scan = TranscriptScan.read(file, after: nil) else { return nil }
        return conversation(scan, id: file.deletingPathExtension().lastPathComponent, modified: modified, desktop: desktop)
    }

    static func conversation(_ scan: TranscriptScan, id: String, modified: Date,
                             desktop: ClaudeConversation.DesktopInfo?) -> ClaudeConversation? {
        // Claude Code finds a conversation by the folder it was started in, not where it went later.
        guard let folder = scan.startCwd ?? scan.cwd else { return nil }
        var title = [scan.customTitle, scan.aiTitle, scan.agentName, scan.lastPrompt.map { String($0.prefix(60)) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Claude Code"
        if let t = desktop?.title, !t.isEmpty { title = t }
        // Without the person's activity in what was read: the desktop app's record of it, else the oldest time read
        // (theirs is older; for a conversation only automation used, that's when it began), else the file's time.
        return ClaudeConversation(id: id, cwd: folder, title: title,
                                  lastActivity: scan.activity ?? desktop?.lastActivity ?? scan.earliest ?? modified,
                                  usedRemoteControl: scan.bridge, startedIn: scan.startedIn ?? "cli", desktop: desktop,
                                  modified: modified)
    }

    /// The Claude desktop app's records of its local sessions, keyed by every Claude Code session id they used.
    static func desktopRecords(in folder: URL = desktopSessionsFolder,
                               cache: ConversationCache? = nil) -> [String: ClaudeConversation.DesktopInfo] {
        var out: [String: ClaudeConversation.DesktopInfo] = [:]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return out }
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("local_")
            && file.pathExtension == "json" {
            let modified = modificationDate(file)
            if let cache, let modified, let hit = cache.desktop(file, modified: modified) {
                for id in hit.ids { out[id] = hit.info }
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let info = ClaudeConversation.DesktopInfo(
                archived: obj["isArchived"] as? Bool ?? false,
                scheduled: !(obj["scheduledTaskId"] is NSNull) && obj["scheduledTaskId"] != nil,
                permissionMode: obj["permissionMode"] as? String,
                remoteControlTurnedOff: (obj["remoteControlUserEnabled"] as? Bool) == false,
                title: obj["title"] as? String,
                lastActivity: (obj["lastActivityAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                current: obj["cliSessionId"] as? String)
            var ids = (obj["priorCliSessionIds"] as? [String]) ?? []
            if let id = obj["cliSessionId"] as? String { ids.append(id) }
            for id in ids { out[id] = info }
            if let cache, let modified { cache.storeDesktop(file, modified: modified, ids: ids, info: info) }
        }
        return out
    }

    /// Claude Code processes that are running now.
    public static func live() -> [LiveClaudeProcess] {
        let files = (try? FileManager.default.contentsOfDirectory(at: registryFolder, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveClaudeProcess] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, let session = obj["sessionId"] as? String,
                  isClaude(pid) else { continue }
            out.append(LiveClaudeProcess(pid: pid, sessionId: session, cwd: obj["cwd"] as? String ?? "",
                                         entrypoint: obj["entrypoint"] as? String ?? "?", name: obj["name"] as? String))
        }
        return out
    }

    /// The pid runs and is a Claude Code process (registry files of ended processes can stay behind, and pids are
    /// reused).
    static func isClaude(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        // ~/.local/bin/claude points to ~/.local/share/claude/versions/<version>; the desktop app has its own copy.
        return path.hasSuffix("/claude") || path.contains("/claude-code/") || path.contains("/share/claude/versions/")
    }
}

/// What a transcript says about itself: the start folder and where it was started (from its beginning), title and
/// Remote Control use (repeated near its end), and the person's last activity.
///
/// Transcripts only grow (JSON lines are appended) and can be large, so the first read goes backwards from the end
/// in windows until it meets the person's last message, and a later read takes only what was appended since, after
/// checking that the bytes where it stopped are still the same (else it reads anew).
struct TranscriptScan: Sendable, Equatable {
    /// Who started the turn the records belong to.
    enum Turn: Sendable, Equatable { case person, automation }

    /// What one record says (most say nothing that matters here).
    enum Event: Equatable {
        /// The person wrote (or interrupted): a prompt typed in the Claude app, a terminal or on the phone.
        case person(Date)
        /// A prompt that automation sent (a task notification, a channel, another agent): its turn isn't the person's.
        case automation
        /// Claude answered (text or tools).
        case reply(Date)
    }

    var inode: UInt64 = 0
    /// Read up to here: just after the last complete line.
    var end: UInt64 = 0
    /// The bytes just before `end`, to notice a transcript that was written anew.
    var check = Data()
    var startCwd: String?
    var startedIn: String?
    /// The head of the file was read to its end without both of them: they may still come.
    var headOpen = false
    var cwd: String?
    var customTitle: String?
    var aiTitle: String?
    var agentName: String?
    var lastPrompt: String?
    var bridge = false
    var activity: Date?
    var turn: Turn?
    /// The oldest time stamp read: without the person's activity, theirs is older than this (or there is none).
    var earliest: Date?

    static let headSize = 256 * 1024
    static let window: UInt64 = 1 << 20
    /// A first read goes back at most this far for the person's last message.
    static let backLimit: UInt64 = 32 << 20
    /// More appended than this since the last read: reading backwards from the end is cheaper.
    static let growthLimit: UInt64 = 4 << 20
    static let checkSize = 64
    static let longestLine = 2_000_000

    // MARK: Reading

    static func read(_ file: URL, after previous: TranscriptScan?) -> TranscriptScan? {
        let id = file.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: id) != nil, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let size = UInt64(max(info.st_size, 0))
        let inode = UInt64(info.st_ino)
        if let previous, let grown = previous.continued(handle, id: id, inode: inode, size: size) { return grown }
        return fresh(handle, id: id, inode: inode, size: size)
    }

    /// Only what was appended since `self` was read, if the transcript is still the same file with the same bytes up
    /// to there.
    func continued(_ handle: FileHandle, id: String, inode: UInt64, size: UInt64) -> TranscriptScan? {
        guard inode == self.inode, size >= end, size - end <= Self.growthLimit, end >= UInt64(check.count) else { return nil }
        do {
            try handle.seek(toOffset: end - UInt64(check.count))
            guard (try handle.read(upToCount: check.count) ?? Data()) == check else { return nil }
            if size == end { return self }
            guard let data = try handle.read(upToCount: Int(size - end)) else { return nil }
            var next = self
            // Only complete lines: the last one may still be being written.
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return self }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) {
                if let facts = Self.facts(line, id: id) { next.apply(facts) }
            }
            next.end = end + UInt64(complete.count)
            if next.end > UInt64(Self.headSize) { next.headOpen = false }
            next.check = Self.tail(of: Data(complete), before: self.check)
            return next
        } catch {
            return nil
        }
    }

    /// Reads the head, then windows from the end backwards until one holds a message of the person (or the limit).
    static func fresh(_ handle: FileHandle, id: String, inode: UInt64, size: UInt64) -> TranscriptScan? {
        var scan = TranscriptScan(inode: inode)
        do {
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: headSize) ?? Data()
            for line in head.split(separator: 0x0A) {
                guard scan.startCwd == nil || scan.startedIn == nil else { break }
                guard let obj = object(line) else { continue }
                if scan.startCwd == nil, let c = obj["cwd"] as? String { scan.startCwd = c }
                if scan.startedIn == nil, let e = obj["entrypoint"] as? String { scan.startedIn = e }
            }
            scan.headOpen = size <= UInt64(headSize) && (scan.startCwd == nil || scan.startedIn == nil)

            var windows: [[Facts]] = []
            var carry = Data()
            var end = size
            var completeEnd: UInt64?
            while end > 0, size - end < backLimit {
                let start = end > window ? end - window : 0
                try handle.seek(toOffset: start)
                var data = try handle.read(upToCount: Int(end - start)) ?? Data()
                if completeEnd == nil {
                    // The end of the file: after the last line break comes a line still being written (never read).
                    guard let newline = data.lastIndex(of: 0x0A) else {
                        end = start
                        if start == 0 { completeEnd = 0 }
                        continue
                    }
                    completeEnd = start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
                    data = Data(data[data.startIndex..<newline])
                }
                data.append(carry)
                var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                // The beginning belongs to a line that started before this window: it goes with the next one.
                carry = start > 0 ? Data(lines.removeFirst()) : Data()
                let facts = lines.compactMap { facts($0, id: id) }
                windows.append(facts)
                end = start
                if facts.contains(where: { if case .person = $0.event { return true } else { return false } }) { break }
            }
            for facts in windows.reversed() {
                for f in facts { scan.apply(f) }
            }
            scan.end = completeEnd ?? 0
            let from = scan.end > UInt64(checkSize) ? scan.end - UInt64(checkSize) : 0
            try handle.seek(toOffset: from)
            scan.check = try handle.read(upToCount: Int(scan.end - from)) ?? Data()
            return scan
        } catch {
            return nil
        }
    }

    /// The last `checkSize` bytes of what was read before plus what was read now.
    static func tail(of appended: Data, before previous: Data) -> Data {
        if appended.count >= checkSize { return Data(appended.suffix(checkSize)) }
        return Data((previous + appended).suffix(checkSize))
    }

    // MARK: Records

    /// What a record contributes, if anything.
    struct Facts {
        var cwd: String?
        var entrypoint: String?
        var customTitle: String?
        var aiTitle: String?
        var agentName: String?
        var lastPrompt: String?
        var bridge = false
        var event: Event?
        var stamp: String?
    }

    mutating func apply(_ f: Facts) {
        if earliest == nil, let stamp = f.stamp { earliest = Self.date(stamp) }
        if let t = f.customTitle { customTitle = t }
        if let t = f.aiTitle { aiTitle = t }
        if let t = f.agentName { agentName = t }
        if f.bridge { bridge = true }
        if lastPrompt == nil, let p = f.lastPrompt { lastPrompt = p }
        if let c = f.cwd {
            cwd = c
            if headOpen, startCwd == nil { startCwd = c }
        }
        if headOpen, startedIn == nil, let e = f.entrypoint { startedIn = e }
        switch f.event {
        case .person(let date)?:
            activity = max(activity ?? date, date)
            turn = .person
        case .automation?:
            turn = .automation
        case .reply(let date)?:
            // An answer in the person's turn (or one whose start wasn't read) counts; automation's turns don't.
            if turn != .automation { activity = max(activity ?? date, date) }
        case nil:
            break
        }
    }

    /// Tool results are most of a transcript's bytes and never matter here: found without parsing them. The key with
    /// its quotes and colon can't appear inside a JSON string (quotes are escaped there).
    private static let toolResultKey = Data("\"toolUseResult\":".utf8)

    static func facts(_ line: Data.SubSequence, id: String) -> Facts? {
        guard !line.isEmpty, line.count < longestLine, line.range(of: toolResultKey) == nil,
              let obj = object(line) else { return nil }
        if let s = obj["sessionId"] as? String, s != id { return nil }  // records of another conversation
        var f = Facts()
        switch obj["type"] as? String {
        case "custom-title": f.customTitle = obj["customTitle"] as? String
        case "ai-title": f.aiTitle = obj["aiTitle"] as? String
        case "agent-name": f.agentName = obj["agentName"] as? String
        case "bridge-session": f.bridge = true
        case "last-prompt": f.lastPrompt = obj["lastPrompt"] as? String
        default: break
        }
        f.cwd = obj["cwd"] as? String
        f.entrypoint = obj["entrypoint"] as? String
        f.event = event(obj)
        f.stamp = obj["timestamp"] as? String
        return f
    }

    static func object(_ line: Data.SubSequence) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    /// The person's prompts and Claude's answers; everything else (meta records like the keeper's bridge status,
    /// compaction summaries, tool results, API errors, synthetic answers, side chains) is no activity.
    static func event(_ obj: [String: Any]) -> Event? {
        if obj["isSidechain"] as? Bool == true { return nil }
        let type = obj["type"] as? String
        guard type == "user" || type == "assistant", let stamp = obj["timestamp"] as? String,
              let date = date(stamp) else { return nil }
        let message = obj["message"] as? [String: Any]
        if type == "assistant" {
            if obj["isApiErrorMessage"] as? Bool == true || message?["model"] as? String == "<synthetic>" { return nil }
            return .reply(date)
        }
        if obj["isCompactSummary"] as? Bool == true || obj["isVisibleInTranscriptOnly"] as? Bool == true
            || obj["toolUseResult"] != nil { return nil }
        if let blocks = message?["content"] as? [Any],
           blocks.contains(where: { ($0 as? [String: Any])?["type"] as? String == "tool_result" }) { return nil }
        // What aOS typed into its session (routines, reminders, notes, the start message): automation, though Claude
        // Code records it like a typed prompt.
        if isFromAOS(message?["content"]) { return .automation }
        // Newer Claude Code says who wrote a prompt: "human", or automation ("task-notification", "channel", "peer").
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String {
            return kind == "human" ? .person(date) : .automation
        }
        // Without one: reminders and caveats Claude Code adds are meta; the rest is the person's (older versions,
        // "[Request interrupted by user]").
        if obj["isMeta"] as? Bool == true { return nil }
        return .person(date)
    }

    /// A prompt that starts with the header line aOS puts in front of what it sends (`SessionDelivery.message`).
    static func isFromAOS(_ content: Any?) -> Bool {
        var text: String?
        if let s = content as? String { text = s }
        else if let blocks = content as? [Any] {
            text = blocks.lazy.compactMap { ($0 as? [String: Any]).flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }.first
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return ["[aOS routine ", "[aOS reminder ", "[aOS note", "[aOS: the session"].contains { t.hasPrefix($0) }
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func date(_ text: String) -> Date? {
        (try? fractional.parse(text)) ?? (try? whole.parse(text))
    }
}

/// Remembers what was read from transcripts and desktop records, keyed by file and modification date; a transcript
/// that changed is read on from where it was read before.
public final class ConversationCache: @unchecked Sendable {
    private var scans: [String: (modified: Date, scan: TranscriptScan?)] = [:]
    private var desktopEntries: [String: (Date, [String], ClaudeConversation.DesktopInfo)] = [:]
    private let lock = NSLock()

    public init() {}

    func scan(_ file: URL, modified: Date) -> TranscriptScan? {
        let hit = lock.withLock { scans[file.path] }
        if let hit, hit.modified == modified { return hit.scan }
        let value = TranscriptScan.read(file, after: hit?.scan)
        lock.withLock { scans[file.path] = (modified, value) }
        return value
    }

    func desktop(_ file: URL, modified: Date) -> (ids: [String], info: ClaudeConversation.DesktopInfo)? {
        guard let hit = lock.withLock({ desktopEntries[file.path] }), hit.0 == modified else { return nil }
        return (hit.1, hit.2)
    }

    func storeDesktop(_ file: URL, modified: Date, ids: [String], info: ClaudeConversation.DesktopInfo) {
        lock.withLock { desktopEntries[file.path] = (modified, ids, info) }
    }
}
