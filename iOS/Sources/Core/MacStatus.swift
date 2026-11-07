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
    case workspaceStart = "workspace.start"
    case workspaceStop = "workspace.stop"
    case bitwardenLock = "bitwarden.lock"
    case sessionRestart = "session.restart"
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
                          otherService: a["otherService"]?.bool ?? false)
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

    init(status: MacStatus? = nil, sleepsIn: Double? = nil) {
        self.status = status
        self.sleepsIn = sleepsIn
    }

    init(_ r: CompanionResponse) {
        status = r.body["status"]?.object.map(MacStatus.init)
        sleepsIn = r.body["sleeping"]?.bool == true ? (r.body["after"]?.number ?? 0) : nil
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
        default: message.isEmpty ? String(localized: "aOS on the Mac said no.") : message
        }
    }
}
