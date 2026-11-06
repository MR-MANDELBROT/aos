import Foundation

/// An event for the iPhone app (see Docs/COMPANION.md, "Companion API").
public struct CompanionEvent: Codable, Sendable, Equatable {
    public var seq: Int = 0
    /// signin, signin.closed, help, help.closed, approval, approval.closed, workspace
    public var event: String
    public var request: String?
    public var agent: String?
    public var host: String?
    /// For sign-ins: "username", "password" or "code" (the field the agent is at).
    public var field: String?
    public var purpose: String?
    public var minutes: Int?
    public var expires: Date?
    public var result: String?
    public var state: String?

    public init(event: String, request: String? = nil, agent: String? = nil, host: String? = nil, field: String? = nil,
                purpose: String? = nil, minutes: Int? = nil, expires: Date? = nil, result: String? = nil,
                state: String? = nil) {
        self.event = event
        self.request = request
        self.agent = agent
        self.host = host
        self.field = field
        self.purpose = purpose
        self.minutes = minutes
        self.expires = expires
        self.result = result
        self.state = state
    }
}

/// Collects what the iPhone app should see and holds the questions it can answer. Phones poll (long poll over the
/// agent socket, through annex-companion); a phone that connects later first gets the questions still open.
@MainActor
public final class CompanionHub {
    private var log: [CompanionEvent] = []
    private var seq = 0
    private var waiters: [UUID: (since: Int, continuation: CheckedContinuation<[CompanionEvent], Never>)] = [:]
    /// Questions that are still open, by request id.
    public private(set) var open: [String: CompanionEvent] = [:]
    /// The last phone that asked, and when (for "iPhone connected" in the menu).
    public private(set) var lastDevice: (name: String, seen: Date)?
    public var onChange: (() -> Void)?

    public init() {}

    public var phoneConnected: Bool {
        guard let last = lastDevice else { return false }
        return Date().timeIntervalSince(last.seen) < 45
    }

    public func seen(device: String?) {
        lastDevice = (device ?? lastDevice?.name ?? "iPhone", Date())
        onChange?()
    }

    /// Publishes an event. An event that opens a question ("signin", "help", "approval") stays in `open` until the
    /// matching ".closed" event.
    public func post(_ event: CompanionEvent) {
        seq += 1
        var e = event
        e.seq = seq
        log.append(e)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if let id = e.request {
            if e.event.hasSuffix(".closed") { open[id] = nil } else if ["signin", "help", "approval"].contains(e.event) {
                open[id] = e
            }
        }
        for (key, w) in waiters where w.since < seq {
            waiters[key] = nil
            w.continuation.resume(returning: events(after: w.since))
        }
        onChange?()
    }

    private func events(after since: Int) -> [CompanionEvent] { log.filter { $0.seq > since } }

    /// Events after `since`; waits up to `timeout` for the next one. `since` 0 (a phone that just connected): the open
    /// questions and the current sequence number, nothing old.
    public func events(since: Int, timeout: TimeInterval) async -> (events: [CompanionEvent], seq: Int) {
        if since <= 0 || since > seq {
            return (open.values.sorted { $0.seq < $1.seq }, seq)
        }
        let ready = events(after: since)
        if !ready.isEmpty { return (ready, seq) }
        let key = UUID()
        let result: [CompanionEvent] = await withCheckedContinuation { cont in
            waiters[key] = (since, cont)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let w = self?.waiters.removeValue(forKey: key) { w.continuation.resume(returning: []) }
            }
        }
        return (result, seq)
    }
}
