import Darwin
import Foundation

/// A Claude Code conversation as it is stored on this Mac (one transcript in ~/.claude/projects).
public struct ClaudeConversation: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var cwd: String
    public var title: String
    public var lastActivity: Date
    /// The conversation was connected to Remote Control at some point (a `bridge-session` record).
    public var usedRemoteControl: Bool
    /// Where it was started: "claude-desktop" (the Claude app), "cli" (a terminal or a tool), "sdk-cli" (automation).
    public var startedIn: String
    /// What the Claude desktop app knows about it, if it started or adopted it.
    public var desktop: DesktopInfo?

    public struct DesktopInfo: Codable, Sendable, Equatable {
        public var archived: Bool
        public var scheduled: Bool
        public var permissionMode: String?
        public var remoteControlTurnedOff: Bool
        public var title: String?
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

    /// Conversations with activity in the last `within` seconds, newest first. With a cache, unchanged transcripts
    /// and desktop records aren't read again.
    public static func recent(within: TimeInterval, limit: Int = 60, cache: ConversationCache? = nil) -> [ClaudeConversation] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        var candidates: [(URL, Date)] = []
        let folders = (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                guard let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date >= cutoff else { continue }
                candidates.append((f, date))
            }
        }
        candidates.sort { $0.1 > $1.1 }
        let desktop = desktopRecords(cache: cache)
        return candidates.prefix(limit).compactMap { file, date in
            guard var c = cache?.conversation(file, modified: date) ?? read(file, modified: date) else { return nil }
            c.desktop = desktop[c.id]
            if let t = c.desktop?.title, !t.isEmpty { c.title = t }
            return c
        }
    }

    /// One conversation by id (searched in all project folders).
    public static func find(_ id: String) -> ClaudeConversation? {
        guard UUID(uuidString: id) != nil else { return nil }
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? [] {
            let file = folder.appendingPathComponent("\(id).jsonl")
            if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               var c = read(file, modified: date) {
                c.desktop = desktopRecords()[id]
                if let t = c.desktop?.title, !t.isEmpty { c.title = t }
                return c
            }
        }
        return nil
    }

    /// Reads the start folder and where it was started from the beginning of a transcript, title and Remote Control
    /// use from its end (they are repeated there; transcripts can be large).
    static func read(_ file: URL, modified: Date) -> ClaudeConversation? {
        let id = file.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: id) != nil, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var startCwd: String?, startedIn: String?
        if let head = try? handle.read(upToCount: 256 * 1024) {
            for line in head.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if startCwd == nil, let c = obj["cwd"] as? String { startCwd = c }
                if startedIn == nil, let e = obj["entrypoint"] as? String { startedIn = e }
                if startCwd != nil && startedIn != nil { break }
            }
        }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1 << 20
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var cwd: String?, customTitle: String?, aiTitle: String?, agentName: String?, firstPrompt: String?
        var bridge = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count < 2_000_000,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let s = obj["sessionId"] as? String, s != id { continue }  // records of another conversation
            switch obj["type"] as? String {
            case "custom-title": customTitle = obj["customTitle"] as? String ?? customTitle
            case "ai-title": aiTitle = obj["aiTitle"] as? String ?? aiTitle
            case "agent-name": agentName = obj["agentName"] as? String ?? agentName
            case "bridge-session": bridge = true
            case "last-prompt": if firstPrompt == nil { firstPrompt = obj["lastPrompt"] as? String }
            default: break
            }
            if let c = obj["cwd"] as? String { cwd = c }
        }
        // Claude Code finds a conversation by the folder it was started in, not where it went later.
        guard let folder = startCwd ?? cwd else { return nil }
        let title = [customTitle, aiTitle, agentName, firstPrompt.map { String($0.prefix(60)) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Claude Code"
        return ClaudeConversation(id: id, cwd: folder, title: title, lastActivity: modified,
                                  usedRemoteControl: bridge, startedIn: startedIn ?? "cli", desktop: nil)
    }

    /// The Claude desktop app's records of its local sessions, keyed by every Claude Code session id they used.
    static func desktopRecords(cache: ConversationCache? = nil) -> [String: ClaudeConversation.DesktopInfo] {
        var out: [String: ClaudeConversation.DesktopInfo] = [:]
        guard let enumerator = FileManager.default.enumerator(at: desktopSessionsFolder,
                                                              includingPropertiesForKeys: [.contentModificationDateKey])
        else { return out }
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("local_")
            && file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
                title: obj["title"] as? String)
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

/// Remembers what was read from transcripts and desktop records, keyed by file and modification date.
public final class ConversationCache: @unchecked Sendable {
    private var conversations: [String: (Date, ClaudeConversation?)] = [:]
    private var desktopEntries: [String: (Date, [String], ClaudeConversation.DesktopInfo)] = [:]
    private let lock = NSLock()

    public init() {}

    func conversation(_ file: URL, modified: Date) -> ClaudeConversation? {
        if let hit = lock.withLock({ conversations[file.path] }), hit.0 == modified { return hit.1 }
        let value = ClaudeConversations.read(file, modified: modified)
        lock.withLock { conversations[file.path] = (modified, value) }
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
