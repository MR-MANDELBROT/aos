import Foundation

// The Overview's view of the Mac and aOS (Docs/COMPANION.md, "The Mac from the iPhone"): one signed op to read,
// one signed op per action. Tested in MacStatusTests.

/// The Overview's ops (the phone's names; the Mac gets them as "companion." + name).
enum MacAction: String, Sendable, CaseIterable {
    case status = "mac.status"
    case sleep = "mac.sleep"
    case displayOff = "mac.display-off"
    case displayOn = "mac.display-on"
    case stayAwake = "mac.stay-awake"
    case batteryLimit = "mac.battery-limit"
    case workspaceStart = "workspace.start"
    case workspaceStop = "workspace.stop"
    case bitwardenLock = "bitwarden.lock"
    case sessionRestart = "session.restart"
    /// The session's routines: add or change one (JSON), delete one, send one now (its id).
    case routineSet = "routines.set"
    case routineDelete = "routines.delete"
    case routineRun = "routines.run"
    /// The chats (Claude Code conversations the Mac keeps reachable, Core/Chats.swift): the list, and one change per
    /// op with the chat's id as the value.
    case chatsList = "chats.list"
    case chatsPin = "chats.pin"
    case chatsUnpin = "chats.unpin"
    case chatsSkip = "chats.skip"
    case chatsUnskip = "chats.unskip"
    case chatsRestart = "chats.restart"
    /// Start one now: the Mac pins it and clears its skip, the keeper starts it at once (a Mac without it: pin).
    case chatsStart = "chats.start"
    /// Stop one: the Mac unpins and skips it, the keeper ends its copy (a Mac without it: skip).
    case chatsStop = "chats.stop"
    /// Delete one: its transcript goes to the Mac's Trash, aOS forgets it (refused while it runs or is open).
    case chatsDelete = "chats.delete"

    /// Changes a chat (the list answers with the new one, the keeper on the Mac follows a moment later).
    var changesChat: Bool { rawValue.hasPrefix("chats.") && self != .chatsList }
}

/// When aOS keeps the Mac awake (AOSKit `StayAwake`).
enum MacStayAwake: String, Sendable, CaseIterable, Identifiable {
    case off, lidOpen, lidClosed
    var id: String { rawValue }
}

/// The Mac and aOS as `mac.status` reports them. Fields a Mac leaves out stay nil.
struct MacStatus: Equatable, Sendable {
    struct Power: Equatable, Sendable {
        /// ac, battery, ups, unknown
        var source: String
        var battery: Int?
        var charging: Bool?
        /// Until empty on battery, until full while charging.
        var minutes: Int?
        /// open, closed, none (a Mac without a lid)
        var lid: String
        /// nominal, fair, serious, critical
        var thermal: String
    }

    struct Display: Equatable, Sendable {
        /// on (a screen is lit), off (all asleep), none (no screen: the lid closed without a monitor)
        var state: String
        /// Monitors besides the built-in screen.
        var external: Int
    }

    struct Awake: Equatable, Sendable {
        var setting: MacStayAwake
        var holding: Bool
        var lidClosedMode: Bool
        /// cloupi, nothingToKeep, helperNotReady, lowBattery, thermal
        var blocker: String?
        /// enabled, requiresApproval, notRegistered, notFound
        var helper: String
        /// Another service owns sleep on this Mac.
        var otherService: Bool
        /// On battery with the lid closed: awake down to this level (0: no limit); nil from an older Mac.
        var batteryLimit: Int? = nil
        var batteryLimits: [Int] = []
    }

    struct Workspace: Equatable, Sendable {
        /// stopped, starting, running, open, closing, failed
        var state: String
        var setupComplete: Bool
        var purpose: String?
        var until: Date?
        var error: String?
    }

    struct Session: Equatable, Sendable {
        var enabled: Bool
        /// starting, running, waitingForNetwork, needsLogin, needsAttention, missingClaude, restarting, stopped, failed
        var state: String?
        var detail: String?
        var since: Date?
    }

    struct NewChats: Equatable, Sendable {
        var enabled: Bool
        /// off, waitingForNetwork, starting, running, needsLogin, needsTrust, missingClaude, restarting
        var state: String?
    }

    struct Vault: Equatable, Sendable {
        /// unlocked, locked, signedOut, needsHelper, unknown
        var state: String
        var until: Date?
    }

    /// aOS's session's routines, reminders waiting for it and what went in lately (nil from an older aOS).
    struct Routines: Equatable, Sendable {
        struct Item: Equatable, Sendable, Identifiable, Codable {
            var id: String
            var name: String
            /// Cron, five fields, the Mac's local time.
            var schedule: String
            var prompt: String
            var enabled: Bool
            var next: Date?

            private enum CodingKeys: String, CodingKey { case id, name, schedule, prompt, enabled }
        }
        struct Upcoming: Equatable, Sendable {
            var name: String
            var at: Date
        }
        struct Sent: Equatable, Sendable {
            /// routine, reminder, note, start
            var kind: String
            var name: String
            var at: Date
        }
        var items: [Item]
        var reminders: [Upcoming] = []
        var queued = 0
        var recent: [Sent] = []

        /// The routine that runs next.
        var next: Item? { items.filter { $0.enabled && $0.next != nil }.min { $0.next! < $1.next! } }
    }

    /// Installing apps on this iPhone (AOSKit `CompanionControl.apps`): the Mac's connection to the iPhone (a
    /// CoreDevice tunnel) and the latest installs. States the phone doesn't know stay as they come.
    struct Apps: Equatable, Sendable {
        struct Job: Equatable, Sendable, Identifiable {
            var id: String
            var name: String
            var bundleId: String
            /// queued, installing, done, failed
            var state: String
            var created: Date?
            /// "1.0 (2)"
            var version: String?
            /// Who asked: an agent's name, or "Mac".
            var source: String?
            var finished: Date?
            var seconds: Double?
            /// The iPhone's network while it installed: wifi, cellular
            var network: String?
            /// Why it failed.
            var message: String?

            /// Not installed yet: waiting for the connection, or going on now.
            var isPending: Bool { state == "queued" || state == "installing" }
        }
        /// connected, searching, connecting, notPaired, starting, stopped, unknown
        var state: String
        /// Since when the connection holds (only while connected).
        var since: Date?
        /// wifi, cellular (only while connected)
        var network: String?
        /// The iPhone's name.
        var device: String?
        /// How long the previous connection held.
        var previousSeconds: Int?
        /// Newest first, at most 10.
        var jobs: [Job] = []

        var isConnected: Bool { state == "connected" }
        var queued: Int { jobs.filter { $0.state == "queued" }.count }
        var installing: Int { jobs.filter { $0.state == "installing" }.count }
    }

    var power: Power?
    /// nil from an older aOS (it doesn't say).
    var display: Display?
    var awake: Awake?
    var workspace: Workspace?
    var session: Session?
    var newChats: NewChats?
    /// Kept conversations running now (nil: the setting is off).
    var kept: Int?
    var bitwarden: Vault?
    var routines: Routines?
    /// nil while installing apps on the iPhone is off on the Mac (or from an older aOS).
    var apps: Apps?

    init(power: Power? = nil, display: Display? = nil, awake: Awake? = nil, workspace: Workspace? = nil,
         session: Session? = nil, newChats: NewChats? = nil, kept: Int? = nil, bitwarden: Vault? = nil) {
        self.power = power
        self.display = display
        self.awake = awake
        self.workspace = workspace
        self.session = session
        self.newChats = newChats
        self.kept = kept
        self.bitwarden = bitwarden
    }

    init(_ o: [String: JSONValue]) {
        func date(_ v: JSONValue?) -> Date? { v?.string.flatMap(ISO8601.parse) }
        if let p = o["power"]?.object {
            power = Power(source: p["source"]?.string ?? "unknown", battery: p["battery"]?.int, charging: p["charging"]?.bool,
                          minutes: p["minutes"]?.int, lid: p["lid"]?.string ?? "none", thermal: p["thermal"]?.string ?? "nominal")
        }
        if let d = o["display"]?.object, let state = d["state"]?.string {
            display = Display(state: state, external: d["external"]?.int ?? 0)
        }
        if let a = o["awake"]?.object, let setting = a["setting"]?.string.flatMap(MacStayAwake.init(rawValue:)) {
            awake = Awake(setting: setting, holding: a["holding"]?.bool ?? false, lidClosedMode: a["lidClosedMode"]?.bool ?? false,
                          blocker: a["blocker"]?.string, helper: a["helper"]?.string ?? "notRegistered",
                          otherService: a["otherService"]?.bool ?? false, batteryLimit: a["batteryLimit"]?.int,
                          batteryLimits: a["batteryLimits"]?.array?.compactMap(\.int) ?? [])
        }
        if let w = o["workspace"]?.object {
            workspace = Workspace(state: w["state"]?.string ?? "stopped", setupComplete: w["setupComplete"]?.bool ?? true,
                                  purpose: w["purpose"]?.string, until: date(w["until"]), error: w["error"]?.string)
        }
        if let s = o["session"]?.object {
            session = Session(enabled: s["enabled"]?.bool ?? true, state: s["state"]?.string, detail: s["detail"]?.string,
                              since: date(s["since"]))
        }
        if let c = o["newChats"]?.object {
            newChats = NewChats(enabled: c["enabled"]?.bool ?? false, state: c["state"]?.string)
        }
        if let k = o["kept"]?.object, k["enabled"]?.bool == true { kept = k["running"]?.int ?? 0 }
        if let b = o["bitwarden"]?.object, let state = b["state"]?.string {
            bitwarden = Vault(state: state, until: date(b["until"]))
        }
        if let r = o["routines"]?.object {
            let items = (r["items"]?.array ?? []).compactMap { v -> Routines.Item? in
                guard let i = v.object, let id = i["id"]?.string, let name = i["name"]?.string,
                      let schedule = i["schedule"]?.string else { return nil }
                return Routines.Item(id: id, name: name, schedule: schedule, prompt: i["prompt"]?.string ?? "",
                                     enabled: i["enabled"]?.bool ?? true, next: date(i["next"]))
            }
            let reminders = (r["reminders"]?.array ?? []).compactMap { v -> Routines.Upcoming? in
                guard let i = v.object, let at = date(i["at"]) else { return nil }
                return Routines.Upcoming(name: i["name"]?.string ?? "", at: at)
            }
            let recent = (r["recent"]?.array ?? []).compactMap { v -> Routines.Sent? in
                guard let i = v.object, let at = date(i["at"]) else { return nil }
                return Routines.Sent(kind: i["kind"]?.string ?? "routine", name: i["name"]?.string ?? "", at: at)
            }
            routines = Routines(items: items, reminders: reminders, queued: r["queued"]?.int ?? 0, recent: recent)
        }
        if let a = o["apps"]?.object {
            let jobs = (a["jobs"]?.array ?? []).compactMap { v -> Apps.Job? in
                guard let j = v.object, let id = j["id"]?.string else { return nil }
                let bundleId = j["bundleId"]?.string ?? ""
                return Apps.Job(id: id, name: j["name"]?.string ?? bundleId, bundleId: bundleId,
                                state: j["state"]?.string ?? "unknown", created: date(j["created"]),
                                version: j["version"]?.string, source: j["source"]?.string, finished: date(j["finished"]),
                                seconds: j["seconds"]?.number, network: j["network"]?.string, message: j["message"]?.string)
            }
            let previous = a["previousSeconds"]?.number.flatMap { abs($0) < 1e9 ? Int($0.rounded()) : nil }
            apps = Apps(state: a["state"]?.string ?? "unknown", since: date(a["since"]), network: a["network"]?.string,
                        device: a["device"]?.string, previousSeconds: previous, jobs: jobs)
        }
    }
}

/// The Mac's actions that make sense now: the Overview offers only these.
struct MacOffer: Equatable, Sendable {
    var sleep = false
    var displayOff = false
    var displayOn = false

    /// `features`: what aOS on the Mac knows (hello); `sleeping`: it was put to sleep and hasn't answered since.
    static func now(_ status: MacStatus, features: Set<String>, sleeping: Bool) -> MacOffer {
        guard !sleeping else { return MacOffer() }
        var offer = MacOffer(sleep: true)
        switch status.display?.state {
        case "on": offer.displayOff = true
        // Off: aOS wakes it (as a key press would); an older aOS can't.
        case "off": offer.displayOn = features.contains(MacAction.displayOn.rawValue)
        // No screen to turn on or off (the lid is closed, no monitor).
        case "none": break
        // An older aOS doesn't say: as before.
        default: offer.displayOff = true
        }
        return offer
    }
}

/// What an Overview action brought back.
struct MacActionResult: Equatable, Sendable {
    var status: MacStatus?
    /// mac.sleep: the Mac goes to sleep in this many seconds.
    var sleepsIn: Double?
    /// The chats ops: the list as it is now.
    var chats: ChatList?

    init(status: MacStatus? = nil, sleepsIn: Double? = nil, chats: ChatList? = nil) {
        self.status = status
        self.sleepsIn = sleepsIn
        self.chats = chats
    }

    init(_ r: CompanionResponse) {
        status = r.body["status"]?.object.map(MacStatus.init)
        sleepsIn = r.body["sleeping"]?.bool == true ? (r.body["after"]?.number ?? 0) : nil
        chats = r.body["chats"]?.object.map(ChatList.init)
    }
}

/// The Mac said no to an Overview action; `code` says why (the phone words it).
struct MacRefusal: Error, Equatable, Sendable {
    var code: String?
    var message: String

    /// In the person's language where the code is known, else what the Mac said.
    var text: String {
        switch code {
        case "other-service": String(localized: "Another service takes care of sleep on this Mac. aOS leaves it alone.")
        case "sleep-disabled": String(localized: "Sleep is switched off on this Mac by another program (pmset disablesleep). aOS doesn't change that.")
        case "sleep-held": String(localized: "aOS's helper didn't let go of the Mac in time. Try again in a moment.")
        case "not-set-up": String(localized: "The workspace isn't set up yet. Finish the setup in aOS on the Mac.")
        case "no-session": String(localized: "aOS's background process isn't running on the Mac, so there is no Claude Code session to restart.")
        case "no-keeper": String(localized: "aOS's background process on the Mac doesn't keep chats reachable right now.")
        case "keeper-old": String(localized: "aOS's background process on the Mac is older and can't restart a single chat yet. It can after the Mac restarts.")
        case "not-kept": String(localized: "aOS doesn't run this chat on the Mac right now, so there is nothing to restart.")
        case "chat-running": String(localized: "Stop it first, or close it in the Claude app.")
        case "not-found": String(localized: "This chat isn't on the Mac any more.")
        default: message.isEmpty ? String(localized: "aOS on the Mac said no.") : message
        }
    }
}
