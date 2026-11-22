import Darwin
import Foundation

/// The conversations aOS's Remote Control server (`RemoteServer`) ran for chats started in the Claude app, and the
/// ones its end cut off (run/remote-conversations.json, Docs/DESIGN.md "New chats from the Claude app").
///
/// The server runs each chat as a child process (`claude --print --sdk-url … --session-id …`, entrypoint `sdk-cli`,
/// no `bridge-session` record), and when the server ends it ends them all (SIGTERM, SIGKILL after 30 s: read in
/// Claude Code 2.1.330). Their transcripts look like automation, so the keeper's rules never kept them; an update of
/// aOS, which restarts the server, cut them off mid-turn and nothing brought them back (2026-11-22, twice).
///
/// So the server notes every child it runs (its conversation, by process tree, every 2 s) and, when it ends while
/// children run, which ones were cut off (`interrupted`). Those the keeper continues like conversations of the Claude
/// app, first after the pinned ones. A conversation the server still serves (its child runs, or it ended under the
/// same server, which starts it again when the next message comes) is never the keeper's.
public struct RemoteConversations: Codable, Sendable, Equatable {
    /// One run of the server: its pid and when it started (pids are reused).
    public struct Server: Codable, Sendable, Equatable {
        public var pid: Int32
        public var started: Date
        public init(pid: Int32, started: Date) {
            self.pid = pid
            self.started = started
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var cwd: String
        /// The server run that ran it last.
        public var server: Server
        /// Its process while that server runs it; nil once it ended.
        public var pid: Int32?
        public var firstSeen: Date
        public var lastSeen: Date
        /// When the end of its server cut it off (it was running then); nil when it ended by itself or the server
        /// serves it again.
        public var interrupted: Date?
    }

    /// A child the server runs now.
    public struct Child: Sendable, Equatable {
        public var pid: Int32
        public var id: String
        public var cwd: String
        public init(pid: Int32, id: String, cwd: String) {
            self.pid = pid
            self.id = id
            self.cwd = cwd
        }
    }

    /// The server running now (nil while none runs).
    public var server: Server?
    public var entries: [String: Entry] = [:]

    public init() {}

    /// Forgotten this long after they were last seen (or cut off).
    static let keepFor: TimeInterval = 31 * 24 * 3600
    /// `lastSeen` of a running child is written at most this often.
    static let seenInterval: TimeInterval = 60

    // MARK: What the server notes

    /// The children `server` runs now. True when something changed that matters (written to disk then).
    @discardableResult
    public mutating func observe(_ children: [Child], server: Server, now: Date = Date()) -> Bool {
        var changed = self.server != server
        self.server = server
        let ids = Set(children.map(\.id))
        for c in children {
            if var e = entries[c.id] {
                if e.server != server || e.pid != c.pid || e.interrupted != nil || e.cwd != c.cwd { changed = true }
                if now.timeIntervalSince(e.lastSeen) >= Self.seenInterval { changed = true; e.lastSeen = now }
                // The server serves it again (the person wrote in the chat): not cut off any more, not the keeper's.
                e.server = server; e.pid = c.pid; e.interrupted = nil; e.cwd = c.cwd
                entries[c.id] = e
            } else {
                entries[c.id] = Entry(id: c.id, cwd: c.cwd, server: server, pid: c.pid, firstSeen: now, lastSeen: now,
                                      interrupted: nil)
                changed = true
            }
        }
        // Ended while the server runs (the chat went idle, or the person ended it): the server's still.
        for (id, e) in entries where e.server == server && e.pid != nil && !ids.contains(id) {
            entries[id]?.pid = nil
            entries[id]?.lastSeen = now
            changed = true
        }
        return changed
    }

    /// `server` ended: the children it ran then are cut off (`interrupting`), unless the person turned the server off.
    /// Returns the conversations cut off.
    @discardableResult
    public mutating func serverEnded(_ server: Server, interrupting: Bool, now: Date = Date()) -> [String] {
        var cut: [String] = []
        for (id, e) in entries where e.server == server && e.pid != nil {
            entries[id]?.pid = nil
            entries[id]?.lastSeen = now
            if interrupting {
                entries[id]?.interrupted = now
                cut.append(id)
            }
        }
        if self.server == server { self.server = nil }
        prune(now: now)
        return cut.sorted()
    }

    /// The person ended or archived it (its Remote Control says so): nothing continues it again.
    public mutating func dismiss(_ id: String) {
        entries[id]?.interrupted = nil
    }

    mutating func prune(now: Date) {
        entries = entries.filter { _, e in
            e.pid != nil || now.timeIntervalSince(max(e.lastSeen, e.interrupted ?? .distantPast)) < Self.keepFor
        }
    }

    // MARK: What the keeper reads

    /// Cut off by the end of their server and not served again: id and when.
    public var interrupted: [String: Date] {
        var out: [String: Date] = [:]
        for (id, e) in entries where e.pid == nil {
            if let at = e.interrupted { out[id] = at }
        }
        return out
    }

    /// The children the server runs now (the keeper counts them as running Claude Code processes, also if Claude
    /// Code's registry doesn't list them).
    public var running: [LiveClaudeProcess] {
        guard let server else { return [] }
        return entries.values.filter { $0.server == server && $0.pid != nil }.sorted { $0.id < $1.id }
            .map { LiveClaudeProcess(pid: $0.pid!, sessionId: $0.id, cwd: $0.cwd, entrypoint: Self.entrypoint, name: nil) }
    }

    /// How the keeper's status names a process of the server.
    public static let entrypoint = "remote-control"

    // MARK: On disk

    static func url(_ paths: Paths) -> URL { paths.run.appendingPathComponent("remote-conversations.json") }

    /// aos-session's server and keeper share the file (different queues): every change is read, made and written
    /// under this lock.
    private static let lock = NSLock()

    public static func read(_ paths: Paths) -> RemoteConversations {
        lock.withLock { load(paths) }
    }

    @discardableResult
    public static func update<T>(_ paths: Paths, _ change: (inout RemoteConversations) -> T) -> T {
        lock.withLock {
            var record = load(paths)
            let old = record
            let result = change(&record)
            if record != old { save(record, paths) }
            return result
        }
    }

    private static func load(_ paths: Paths) -> RemoteConversations {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: url(paths).path),
              let record = try? decoder.decode(RemoteConversations.self, from: data) else { return RemoteConversations() }
        return record
    }

    private static func save(_ record: RemoteConversations, _ paths: Paths) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) { try? data.write(to: url(paths), options: .atomic) }
    }
}

/// Processes below a process, and a process's command line (for the server's children).
enum ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Children, their children and so on, `depth` levels down.
    static func descendants(of pid: pid_t, depth: Int = 3) -> [pid_t] {
        var out: [pid_t] = []
        var level = [pid]
        for _ in 0..<depth {
            level = level.flatMap { children(of: $0) }.filter { !out.contains($0) }
            if level.isEmpty { break }
            out += level
        }
        return out
    }

    /// The command line of a process of this user (KERN_PROCARGS2), nil if it can't be read.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        // The executable's path, then padding
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The value of `--name value` or `--name=value`.
    static func option(_ name: String, in args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a == name, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(name + "=") { return String(a.dropFirst(name.count + 1)) }
        }
        return nil
    }
}

/// aOS was updated while Claude Code works: aos-session restarts with the new version only once none of its Claude
/// Code processes (its own session, the kept conversations, the server's chats) is in the middle of a turn, at most
/// `longestWait` later. Before, the update cut every running turn off at once.
public enum UpdateRestart {
    public static let longestWait: TimeInterval = 30 * 60

    public static func shouldWait(busy: Int, noticed: Date, now: Date = Date()) -> Bool {
        busy > 0 && now.timeIntervalSince(noticed) < longestWait
    }

    /// Claude Code processes below `pid` that are in the middle of a turn (Claude Code's registry says `busy`).
    public static func busyClaudeProcesses(under pid: pid_t = getpid()) -> [pid_t] {
        ProcessTree.descendants(of: pid, depth: 4).filter {
            ClaudeConversations.isClaude($0) && ClaudeRegistry.entry(pid: $0)?.status == "busy"
        }
    }
}
