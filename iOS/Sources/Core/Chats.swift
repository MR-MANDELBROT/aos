import Foundation

// The chats (Docs/COMPANION.md, "Chats"; the Overview's Chats page): the Claude Code conversations as the Mac's
// settings list them, in the Mac's order (reachable first, then pinned, then by the person's last activity), with what
// aOS's keeper does with each. Read with `chats.list`, changed with one signed op per action (the chat's id is the
// signed value). Tested in ChatsTests.

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
        /// It can be continued in the Claude app now: aOS runs it (or starts it), or it is open elsewhere on the Mac.
        var isReachable: Bool { isRunning || state == "openElsewhere" }
        /// aOS keeps it: its keeper has it, or it is pinned, or the rules keep it and the keeper hasn't started it yet
        /// (no reason given).
        var isKept: Bool { state != nil || (!skipped && (pinned || reason == nil)) }
        /// Nothing runs it on the Mac: the keeper has no copy (or one that failed, lost its folder or waits for the
        /// network) and it isn't open elsewhere. Only then can it be deleted. A state the phone doesn't know counts as
        /// running.
        var isIdle: Bool { state.map { ["failed", "folderMissing", "waitingForNetwork"].contains($0) } ?? true }
        /// The Claude app's own choices (archived, scheduled, Remote Control off), aOS's own session and automation:
        /// aOS never keeps these, pinned or not.
        var isNeverKept: Bool {
            ["archived", "scheduled", "remoteControlOff", "ownSession", "automation"].contains(reason ?? "")
        }
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
    /// Running now (the keeper's count).
    var running: Int
    /// The keeper on the Mac can restart a single chat.
    var canRestart: Bool
    /// In the Mac's order, as it sent them.
    var chats: [Chat]

    /// Reachable in the Claude app now (running, starting or open elsewhere).
    var reachable: Int { chats.filter(\.isReachable).count }

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
}

/// What can be done with a chat now: the Chats page (swipe actions, context menu) and the chat's page offer only these.
struct ChatOffer: Equatable, Sendable {
    /// Start it now, kept from then on: `chats.start`, or `chats.pin` on a Mac from before it (pinning clears the skip
    /// there too, and the keeper starts pinned ones).
    var start: MacAction?
    /// Stop it: `chats.stop`, or `chats.skip` on a Mac from before it (skipping unpins there too).
    var stop: MacAction?
    var restart = false
    /// Its conversation to the Mac's Trash: only while nothing runs it, and only a Mac that knows `chats.delete`.
    var delete = false

    /// `features`: what aOS on the Mac knows (hello).
    static func now(_ chat: ChatList.Chat, in list: ChatList, features: Set<String>) -> ChatOffer {
        func has(_ action: MacAction) -> Bool { features.contains(action.rawValue) }
        var offer = ChatOffer()
        offer.restart = has(.chatsRestart) && list.enabled && list.canRestart
            && ["running", "starting", "needsAttention", "failed"].contains(chat.state ?? "")
        // Start: when it isn't reachable and aOS would keep it (not with keeping off on the Mac, nor what aOS never
        // keeps). One that needs something or failed has Restart; one without its folder can't start.
        if !chat.isReachable, !chat.isNeverKept, list.enabled, !offer.restart, chat.state != "folderMissing" {
            offer.start = has(.chatsStart) ? .chatsStart : has(.chatsPin) ? .chatsPin : nil
        }
        // Stop: when aOS keeps it or runs it.
        if chat.isKept {
            offer.stop = has(.chatsStop) ? .chatsStop : has(.chatsSkip) ? .chatsSkip : nil
        }
        // Delete: not while it runs or is open somewhere (the Mac refuses that too), never aOS's own session.
        offer.delete = has(.chatsDelete) && chat.isIdle && chat.reason != "ownSession"
        return offer
    }

    /// Nothing to offer.
    var isEmpty: Bool { self == ChatOffer() }
}
