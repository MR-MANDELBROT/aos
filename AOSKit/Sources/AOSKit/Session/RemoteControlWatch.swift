import Darwin
import Foundation

/// Remote Control that is gone and doesn't come back (Docs/DESIGN.md, "Remote Control that stays gone").
///
/// Claude Code notes in the conversation's transcript when its Remote Control is up (a system record "/remote-control
/// is active", subtype bridge_status) and when it is lost ("Remote Control disconnected — <reason>"). After some losses
/// it reconnects by itself (a new "active" follows within seconds or minutes); after others the process stays without
/// Remote Control until it is started again, and the chat is missing or frozen in the Claude app (14.11.2026: "the
/// server no longer reports this session", 39 minutes until an update restarted it).
///
/// So the keeper (each kept conversation) and the supervisor (aOS's own session) read the transcript of the running
/// process, and a loss that lasts start the process again with the same conversation. Not for losses the person caused
/// or that mean another process has it: the chat was ended or archived on another device, or another connection took
/// it over.
public enum RemoteControlEvent: Equatable, Sendable {
    case active(Date)
    case lost(Date, reason: String)

    public var date: Date {
        switch self {
        case .active(let d), .lost(let d, _): return d
        }
    }
}

public enum RemoteControlLoss: Equatable, Sendable {
    /// Ended or archived from another device or app: the person did it.
    case endedByPerson
    /// Another connection took the session over: another process serves it.
    case takenOver
    /// The server no longer knows the session ("it may have been deleted"): mostly not deleted at all, but it could be.
    case unknownToServer
    /// The rest: token refresh, "couldn't reconnect", session creation failed.
    case other

    public init(reason: String) {
        let r = reason.lowercased()
        if r.contains("ended or archived") { self = .endedByPerson }
        else if r.contains("took over") || r.contains("standing down") { self = .takenOver }
        else if r.contains("no longer reports") || r.contains("deleted") { self = .unknownToServer }
        else { self = .other }
    }

    public var restartHelps: Bool { self == .unknownToServer || self == .other }
}

/// What the restarts for one conversation have been (kept across its processes).
public struct RemoteControlHealth: Equatable, Sendable {
    /// Restarts since Remote Control last stayed up a while.
    public var restarts = 0
    public var lastRestart: Date?
    public init() {}
}

public enum RemoteControlPolicy {
    /// A loss lasts this long before a restart (Claude Code often reconnects by itself within it).
    public static let graceSec = 120.0
    /// Up this long: the restarts start counting from zero again.
    public static let stableSec = 600.0
    /// At most this many restarts in a row without Remote Control staying up in between; when the server no longer
    /// knows the session only one (the person may really have deleted it).
    public static let maxRestarts = 3
    public static let maxRestartsUnknown = 1
    /// The time since the previous restart before the next one (the 2nd, the 3rd).
    public static let spacingSec = [0.0, 600, 1800]

    /// Whether to start the process again now. `last`: the newest Remote Control record of the running process (nil:
    /// none yet). `apiUp` is asked last, only when everything else says yes (it takes up to a few seconds).
    public static func shouldRestart(last: RemoteControlEvent?, now: Date, apiUp: () -> Bool,
                                     health h: inout RemoteControlHealth) -> Bool {
        guard let last else { return false }
        switch last {
        case .active(let at):
            if now.timeIntervalSince(at) >= stableSec { h.restarts = 0 }
            return false
        case .lost(let at, let reason):
            let loss = RemoteControlLoss(reason: reason)
            guard loss.restartHelps, now.timeIntervalSince(at) >= graceSec else { return false }
            guard h.restarts < (loss == .unknownToServer ? maxRestartsUnknown : maxRestarts) else { return false }
            if let previous = h.lastRestart,
               now.timeIntervalSince(previous) < spacingSec[min(h.restarts, spacingSec.count - 1)] { return false }
            guard apiUp() else { return false }
            h.restarts += 1
            h.lastRestart = now
            return true
        }
    }

    /// A transcript record's Remote Control event, if it is one.
    static func event(_ obj: [String: Any]) -> RemoteControlEvent? {
        guard obj["type"] as? String == "system", let content = obj["content"] as? String,
              let stamp = obj["timestamp"] as? String, let date = TranscriptScan.date(stamp) else { return nil }
        if obj["subtype"] as? String == "bridge_status" || content.hasPrefix("/remote-control is active") {
            return .active(date)
        }
        let prefix = "Remote Control disconnected"
        guard content.hasPrefix(prefix) else { return nil }
        let reason = content.dropFirst(prefix.count).drop { " —-:".contains($0) }
        return .lost(date, reason: String(reason))
    }
}

/// Follows one process's Remote Control in its conversation's transcript: reads only what was appended since the last
/// look, and only records from `since` on (the transcript holds those of earlier processes too).
final class RemoteControlTail {
    let since: Date
    private(set) var last: RemoteControlEvent?
    private var id: String?
    private var file: URL?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    /// A first read goes back at most this far (the records of this process are near the end).
    static let backLimit: UInt64 = 8 << 20

    init(since: Date) { self.since = since.addingTimeInterval(-2) }

    /// Reads on; `id`: the conversation the process runs now, `locate`: its transcript file.
    @discardableResult
    func poll(id: String, locate: (String) -> URL? = RemoteControlTail.transcript) -> RemoteControlEvent? {
        if id != self.id {
            self.id = id
            file = nil
            inode = 0
        }
        if file == nil { file = locate(id) }
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else {
            self.file = nil
            return last
        }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return last }
        let size = UInt64(max(info.st_size, 0))
        var skipPartial = false
        if UInt64(info.st_ino) != inode || size < offset {
            inode = UInt64(info.st_ino)
            offset = size > Self.backLimit ? size - Self.backLimit : 0
            skipPartial = offset > 0
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { return last }
        var complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        if skipPartial, let first = complete.firstIndex(of: 0x0A) { complete = complete[complete.index(after: first)...] }
        for line in complete.split(separator: 0x0A) where Self.mayMatter(line) {
            guard let obj = TranscriptScan.object(line), let e = RemoteControlPolicy.event(obj), e.date >= since,
                  e.date >= (last?.date ?? .distantPast) else { continue }
            last = e
        }
        return last
    }

    private static let markers = [Data("bridge_status".utf8), Data("Remote Control disconnected".utf8)]

    /// Without one of the markers a line is no Remote Control record (most lines; no JSON parsing for them).
    static func mayMatter(_ line: Data.SubSequence) -> Bool {
        line.count < 100_000 && markers.contains { line.range(of: $0) != nil }
    }

    static func transcript(_ id: String) -> URL? {
        ClaudeConversations.files(of: id).first { $0.pathExtension == "jsonl" }
    }
}
