import Foundation

// The chats on the phone's Overview (Docs/COMPANION.md, "Chats"): the Claude Code conversations as the Mac's settings
// list them, in the same order (pinned first, then by the person's last activity), with what the keeper does with
// each, and one signed op per action. The conversation's id travels in `text`, which the signature covers.

/// What the person changes about a conversation (Settings > Claude Code > Conversations on the Mac).
public enum ConversationChange: String, Sendable, Equatable, CaseIterable {
    /// Always keep it reachable (also when it's older); takes it off the skipped ones.
    case pin
    /// Keep it only automatically again.
    case unpin
    /// Never keep it: the keeper ends it now if it runs.
    case skip
    /// May be kept again.
    case unskip
}

/// The conversations as the lists show them, on the Mac and on the iPhone (Max, 2026-11-09: the reachable ones on top,
/// no sessions of aOS's own, nothing old that doesn't matter).
public enum ChatListing {
    /// Reachable in the Claude app now: aOS keeps it running (or starts it), or a Claude Code process has it open (the
    /// desktop app, a terminal).
    public static func reachable(keeper: KeeperStatus?, live: [LiveClaudeProcess]) -> Set<String> {
        var ids = Set(live.map(\.sessionId))
        for e in keeper?.entries ?? [] where [.running, .starting, .openElsewhere].contains(e.state) { ids.insert(e.id) }
        return ids
    }

    /// Without aOS's own session (its folder, or its conversation wherever it runs): reachable ones first, then the
    /// pinned ones, then by the person's last activity; the same moment by id.
    public static func shown(_ conversations: [ClaudeConversation], reachable: Set<String>, pinned: Set<String>,
                             exclude folder: String, ownConversation own: String?) -> [ClaudeConversation] {
        conversations
            .filter { c in !(c.cwd == folder || c.cwd.hasPrefix(folder + "/") || c.id == own) }
            .sorted { a, b in
                let ra = reachable.contains(a.id), rb = reachable.contains(b.id)
                if ra != rb { return ra }
                let pa = pinned.contains(a.id), pb = pinned.contains(b.id)
                if pa != pb { return pa }
                if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
                return a.id < b.id
            }
    }
}

public enum CompanionChats {
    /// The list as the phone gets it with every chats answer.
    /// `exclude` and `ownConversation`: aOS's own session's folder and conversation (`SessionKeeper.select`).
    public static func json(_ conversations: [ClaudeConversation], keeper: KeeperStatus?, settings s: AgentSettings,
                            exclude folder: String, ownConversation own: String? = nil, live: [LiveClaudeProcess] = [],
                            now: Date = Date(),
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let running = keeper.map { $0.enabled && s.keepReachable } ?? false
        let entries = running ? (keeper?.entries ?? []) : []
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // What the keeper keeps by the same rules (it may not have looked yet, or aos-session isn't running).
        let wanted = Set(SessionKeeper.select(conversations, settings: s, exclude: folder, ownConversation: own, now: now)
            .map(\.0.id))
        let skipped = Set(s.skippedConversations)
        let pinned = Set(s.keptConversations)
        var list: [[String: Any]] = []
        var listed = Set<String>()
        let reachable = ChatListing.reachable(keeper: running ? keeper : nil, live: live)
        let liveByID = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        for c in ChatListing.shown(conversations, reachable: reachable, pinned: pinned, exclude: folder, ownConversation: own) {
            listed.insert(c.id)
            var o: [String: Any] = ["id": c.id, "title": c.title, "folder": tilde(c.cwd, home: home),
                                    "origin": origin(c.startedIn), "activity": iso.string(from: c.lastActivity),
                                    "pinned": pinned.contains(c.id), "skipped": skipped.contains(c.id)]
            if let e = byID[c.id] {
                add(e, to: &o, iso: iso)
            } else if let p = liveByID[c.id] {
                // Open in the Claude app or a terminal (aOS doesn't keep it, it runs anyway)
                o["state"] = KeeperStatus.State.openElsewhere.rawValue
                o["detail"] = p.entrypoint == "claude-desktop" ? "open in the Claude app" : "open in a terminal or another tool"
                o["note"] = p.entrypoint == "claude-desktop" ? "app" : "terminal"
                o["since"] = iso.string(from: now)
            } else if let reason = SessionKeeper.reason(c, settings: s, exclude: folder, ownConversation: own,
                                                        kept: wanted, now: now) {
                o["reason"] = reason.rawValue
            }
            list.append(o)
        }
        // A conversation the keeper has that the list doesn't (it shouldn't happen): shown from the keeper's record.
        for e in entries where !listed.contains(e.id) && e.id != own {
            var o: [String: Any] = ["id": e.id, "title": e.title, "folder": tilde(e.cwd, home: home),
                                    "activity": iso.string(from: e.lastActivity), "pinned": e.pinned,
                                    "skipped": skipped.contains(e.id)]
            add(e, to: &o, iso: iso)
            list.append(o)
        }
        return ["enabled": s.keepReachable, "automatic": s.keepAutomatic, "terminal": s.keepTerminal,
                "hours": s.keepHours, "max": s.keepMax, "running": entries.filter { $0.state == .running }.count,
                "restart": running && (keeper?.commands?.contains("restart") ?? false), "list": list]
    }

    static func add(_ e: KeeperStatus.Entry, to o: inout [String: Any], iso: ISO8601DateFormatter) {
        o["state"] = e.state.rawValue
        if !e.detail.isEmpty { o["detail"] = e.detail }
        if let note = e.note { o["note"] = note }
        o["since"] = iso.string(from: e.since)
    }

    /// app (the Claude app), terminal (a terminal or a tool), or other.
    static func origin(_ startedIn: String) -> String {
        switch startedIn {
        case "claude-desktop": return "app"
        case "cli": return "terminal"
        default: return "other"
        }
    }

    /// The folder with the home folder as "~".
    static func tilde(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension WorkspaceController {
    /// The chats as the phone shows them: the list the Mac's settings show, read off the main thread.
    func chats() async -> [String: Any] {
        let s = settings
        let cache = conversationCache
        let sources = conversationSources
        let folder = paths.session.standardizedFileURL.path
        let keeper = KeeperStatus.read(paths)
        let conversations = await Task.detached(priority: .userInitiated) {
            ClaudeConversations.shown(settings: s, cache: cache, sources: sources)
        }.value
        return CompanionChats.json(conversations, keeper: keeper, settings: s, exclude: folder,
                                   ownConversation: SessionKeeper.ownConversation(paths), live: ClaudeConversations.live())
    }

    /// The chats ops (after CompanionGate admitted them): the list, and one change per op.
    func handleChats(_ r: AgentRequest, from: String) async -> AgentResponse {
        func refused(_ refusal: MacControlRefusal) -> AgentResponse {
            AgentResponse(id: r.id, ok: false, text: refusal.message, code: refusal.code)
        }
        func done() async -> AgentResponse {
            let object: [String: Any] = ["chats": await chats(), "status": macStatus()]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return AgentResponse(id: r.id, ok: true, text: String(decoding: data, as: UTF8.self))
        }
        if r.op == CompanionControl.chatsList { return await done() }
        guard let id = r.text, UUID(uuidString: id) != nil else { return .failure(r.id, "Not a conversation: \(r.text ?? "")") }
        let change: ConversationChange
        switch r.op {
        case CompanionControl.chatsPin: change = .pin
        case CompanionControl.chatsUnpin: change = .unpin
        case CompanionControl.chatsSkip: change = .skip
        case CompanionControl.chatsUnskip: change = .unskip
        case CompanionControl.chatsStart: change = .pin
        case CompanionControl.chatsStop:
            guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
            if let refusal = controls.changeConversation(id, .unpin) { return refused(refusal) }
            if let refusal = controls.changeConversation(id, .skip) { return refused(refusal) }
            log("\(from): conversation \(id.prefix(8)) stopped")
            return await done()
        case CompanionControl.chatsDelete:
            // Not while it runs or is open (the process would write it again); the files go to the Trash.
            let running = KeeperStatus.read(paths)?.entries.contains { $0.id == id && $0.state != .waitingForNetwork } ?? false
            if running || ClaudeConversations.live().contains(where: { $0.sessionId == id }) { return refused(.chatRunning) }
            let files = ClaudeConversations.files(of: id)
            guard !files.isEmpty else { return refused(.chatNotFound) }
            for f in files { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) }
            if let controls = macControls {
                _ = controls.changeConversation(id, .unpin)
                _ = controls.changeConversation(id, .unskip)
            }
            log("\(from): conversation \(id.prefix(8)) moved to the Trash")
            return await done()
        case CompanionControl.chatsRestart:
            // aos-session's keeper restarts its copy; one from before this can't (it would take the command as typing).
            guard let keeper = KeeperStatus.read(paths), keeper.enabled, settings.keepReachable else { return refused(.noKeeper) }
            guard keeper.commands?.contains("restart") == true else { return refused(.keeperTooOld) }
            guard let entry = keeper.entries.first(where: { $0.id == id }),
                  [.running, .starting, .needsAttention, .failed].contains(entry.state) else { return refused(.notKept) }
            guard let client = try? RawSocket(path: paths.run.appendingPathComponent("session.sock")) else {
                return refused(.noKeeper)
            }
            client.send(SessionSupervisor.keeperRestartCommand(id))
            client.close()
            log("\(from) restarts the kept conversation \"\(entry.title)\"")
            return await done()
        default:
            return .failure(r.id, "unknown companion operation \(r.op)")
        }
        guard let controls = macControls else { return .failure(r.id, "\(Brand.name) can't do that right now.") }
        if let refusal = controls.changeConversation(id, change) { return refused(refusal) }
        log("\(from): conversation \(id.prefix(8)) \(change.rawValue)")
        return await done()
    }
}
