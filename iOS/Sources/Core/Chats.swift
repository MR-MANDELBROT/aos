import Foundation

// The chats on the Overview (Docs/COMPANION.md, "Chats"): the Claude Code conversations as the Mac's settings list
// them, pinned first, then by when the person last used them, with what aOS's keeper does with each. Read with
// `chats.list`, changed with one signed op per action (the chat's id is the signed value). Tested in ChatsTests.

/// The chats as the Mac reports them. Fields a Mac leaves out keep their defaults.
struct ChatList: Equatable, Sendable {
    struct Chat: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        /// Where it runs, with the home folder as "~".
        var folder: String
        /// app (started in the Claude app), terminal, other.
        var origin: String?
        /// When the person last wrote in it or got an answer.
        var activity: Date?
        /// Kept reachable always.
        var pinned: Bool
        /// Never kept (stopped from here or on the Mac).
        var skipped: Bool
        /// What aOS's keeper does with it: running, starting, openElsewhere, waitingForNetwork, needsAttention,
        /// failed, folderMissing; nil when it doesn't keep it.
        var state: String?
        /// The keeper's words (English), for states the phone doesn't know.
        var detail: String?
        /// The detail as a code: app, terminal, elsewhere, signIn, question, exiting, restarting.
        var note: String?
        var since: Date?
        /// Why it isn't kept: off, skipped, archived, scheduled, remoteControlOff, ownSession, automation, onlyPinned,
        /// terminal, noRemoteControl, inactive, overLimit.
        var reason: String?

        init(id: String, title: String, folder: String = "", origin: String? = nil, activity: Date? = nil,
             pinned: Bool = false, skipped: Bool = false, state: String? = nil, detail: String? = nil,
             note: String? = nil, since: Date? = nil, reason: String? = nil) {
            self.id = id
            self.title = title
            self.folder = folder
            self.origin = origin
            self.activity = activity
            self.pinned = pinned
            self.skipped = skipped
            self.state = state
            self.detail = detail
            self.note = note
            self.since = since
            self.reason = reason
        }

        /// aOS runs it on the Mac now (or starts it).
        var isRunning: Bool { state == "running" || state == "starting" }
        /// The folder's own name.
        var folderName: String {
            let name = folder.split(separator: "/").last.map(String.init) ?? folder
            return name.isEmpty ? folder : name
        }
    }

    /// Keeping chats reachable is on (Settings > Claude Code on the Mac).
    var enabled: Bool
    /// Besides pinned ones, the ones used within `hours` (else pinned ones only).
    var automatic: Bool
    /// Also chats started in a terminal.
    var terminal: Bool
    var hours: Int
    /// At most this many at once.
    var max: Int
    /// Running now (reachable in the Claude app).
    var running: Int
    /// The keeper on the Mac can restart a single chat.
    var canRestart: Bool
    var chats: [Chat]

    init(enabled: Bool = true, automatic: Bool = true, terminal: Bool = false, hours: Int = 48, max: Int = 6,
         running: Int = 0, canRestart: Bool = false, chats: [Chat] = []) {
        self.enabled = enabled
        self.automatic = automatic
        self.terminal = terminal
        self.hours = hours
        self.max = max
        self.running = running
        self.canRestart = canRestart
        self.chats = chats
    }

    init(_ o: [String: JSONValue]) {
        func date(_ v: JSONValue?) -> Date? { v?.string.flatMap(ISO8601.parse) }
        enabled = o["enabled"]?.bool ?? false
        automatic = o["automatic"]?.bool ?? true
        terminal = o["terminal"]?.bool ?? false
        hours = o["hours"]?.int ?? 48
        max = o["max"]?.int ?? 6
        running = o["running"]?.int ?? 0
        canRestart = o["restart"]?.bool ?? false
        chats = (o["list"]?.array ?? []).compactMap { value in
            guard let c = value.object, let id = c["id"]?.string, !id.isEmpty else { return nil }
            return Chat(id: id, title: c["title"]?.string ?? "Claude Code", folder: c["folder"]?.string ?? "",
                        origin: c["origin"]?.string, activity: date(c["activity"]), pinned: c["pinned"]?.bool ?? false,
                        skipped: c["skipped"]?.bool ?? false, state: c["state"]?.string, detail: c["detail"]?.string,
                        note: c["note"]?.string, since: date(c["since"]), reason: c["reason"]?.string)
        }
    }

    /// The ones the card shows before "Show All": every pinned one and every one aOS has, then the newest others,
    /// at least `minimum` (the list's own order: pinned first, then by last use).
    func shortList(minimum: Int = 5) -> [Chat] {
        var others = 0
        let room = Swift.max(minimum - chats.filter { $0.pinned || $0.state != nil }.count, 0)
        return chats.filter { chat in
            if chat.pinned || chat.state != nil { return true }
            others += 1
            return others <= room
        }
    }
}

/// What can be done with a chat now: the card and the chat's page offer only these.
struct ChatOffer: Equatable, Sendable {
    var pin = false
    var unpin = false
    /// Stop keeping it (ends it on the Mac if it runs there).
    var stop = false
    /// Keep it again after it was stopped.
    var keepAgain = false
    var restart = false

    /// `features`: what aOS on the Mac knows (hello).
    static func now(_ chat: ChatList.Chat, in list: ChatList, features: Set<String>) -> ChatOffer {
        func has(_ action: MacAction) -> Bool { features.contains(action.rawValue) }
        if chat.skipped { return ChatOffer(keepAgain: has(.chatsUnskip)) }
        var offer = ChatOffer()
        // The Claude app's own choices (archived, scheduled, Remote Control off) and aOS's own session aren't kept,
        // pinned or not: nothing to pin there.
        let never = ["archived", "scheduled", "remoteControlOff", "ownSession", "automation"].contains(chat.reason ?? "")
        if chat.pinned { offer.unpin = has(.chatsUnpin) } else if !never { offer.pin = has(.chatsPin) }
        offer.stop = has(.chatsSkip) && !never
        offer.restart = has(.chatsRestart) && list.enabled && list.canRestart
            && ["running", "starting", "needsAttention", "failed"].contains(chat.state ?? "")
        return offer
    }
}
