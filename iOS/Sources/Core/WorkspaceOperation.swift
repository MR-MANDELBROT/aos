import Foundation

/// A start or close of the workspace asked for from this iPhone, until the Mac reports it done. aOS on the Mac answers
/// `workspace.start` and `workspace.stop` at once, with the state before (it starts or closes the workspace after
/// answering), so an answer or a status that still says the old state is no result: the phone keeps showing the
/// operation until the state it asked for comes, the workspace fails, or the time is up. Tested in MacStatusTests.
struct WorkspaceOperation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case start, stop
    }

    enum Outcome: Equatable, Sendable {
        case underWay
        /// The workspace is where it was asked to go.
        case done
        /// It didn't start (the Mac reports `failed`, its error is in its status).
        case failed
        /// No result in time.
        case timedOut
    }

    let kind: Kind
    let since: Date
    /// The state when it was asked for (nil: not known).
    let from: String?
    /// The Mac reported another state since: a `failed` now is this operation's result, not the one before.
    private(set) var moved = false

    init(_ kind: Kind, from: String?, since: Date = Date()) {
        self.kind = kind
        self.from = from
        self.since = since
    }

    /// The operation an action starts, if it is one.
    init?(_ action: MacAction, from: String?, since: Date = Date()) {
        switch action {
        case .workspaceStart: self.init(.start, from: from, since: since)
        case .workspaceStop: self.init(.stop, from: from, since: since)
        default: return nil
        }
    }

    /// How long the Mac may take: a start boots and prepares the workspace, a close shuts it down (aOS on the Mac
    /// gives the guest 90 s before it turns it off).
    var timeout: TimeInterval { kind == .start ? 5 * 60 : 3 * 60 }

    /// What the state shows while it is under way.
    var shownState: String { kind == .start ? "starting" : "closing" }

    /// The workspace is where this operation wanted it.
    func arrived(at state: String?) -> Bool {
        switch (kind, state) {
        case (.start, "running"?), (.start, "open"?), (.stop, "stopped"?): true
        default: false
        }
    }

    /// Takes the state the Mac reports now (`state`) into account.
    mutating func observe(_ state: String?, at now: Date = Date()) -> Outcome {
        if let state, state != from { moved = true }
        if arrived(at: state) { return .done }
        if state == "failed", moved {
            // A close is over too: the workspace doesn't run (the card shows the Mac's error).
            return kind == .start ? .failed : .done
        }
        return now.timeIntervalSince(since) >= timeout ? .timedOut : .underWay
    }

    /// What the person reads when it took too long.
    var timeoutText: String {
        kind == .start
            ? String(localized: "The workspace didn't start within 5 minutes. Look at aOS on the Mac.")
            : String(localized: "The workspace didn't close within 3 minutes. Look at aOS on the Mac.")
    }
}
