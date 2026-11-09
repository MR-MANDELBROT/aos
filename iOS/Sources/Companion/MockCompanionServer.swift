import CryptoKit
import Foundation

/// The Mac's side of the companion API in memory: answers requests the way `aos-companion serve` does
/// (Docs/COMPANION.md) and sends events on demand. Used by the tests and by the app's demo mode.
final class MockCompanionServer: @unchecked Sendable {
    struct State: Sendable {
        var macName = "Max’s MacBook Pro"
        var aosVersion = "0.2.0"
        var workspace = WorkspaceStatus(state: .open, purpose: "Rechnungen herunterladen",
                                        until: Date().addingTimeInterval(25 * 60),
                                        sessions: [.init(id: 0, title: "Claude Code", state: "running")])
        var screens: [ScreenTarget: ScreenEndpoint] = [
            .mac: ScreenEndpoint(host: "127.0.0.1", port: 5900),
            .workspace: ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "aos", password: "demo-only"),
        ]
        /// Requests the server answers with `ok: false` and this message.
        var refuse: [String: String] = [:]
        /// ... and with this code (the Overview's actions: "sleep-disabled", "not-set-up", ...).
        var refuseCode: [String: String] = [:]
        /// What `mac.status` reports; the actions change it as the Mac would.
        var macStatus = MockCompanionServer.demoMacStatus
        /// What `chats.list` reports (in the Mac's order: pinned first, then by last use); the chats ops change it.
        var chats = MockCompanionServer.demoChats()
        /// Keeping chats reachable is on (Settings > Claude Code on the Mac).
        var chatsEnabled = true
        /// The keeper on the Mac restarts single chats (an older one can't).
        var chatsRestart = true
        /// The Mac is older and doesn't know the Overview's ops.
        var oldMac = false
        /// The phone the Mac knows: with it set, every request must be signed by that phone, as aOS on the Mac
        /// checks it (refused with "pair-again" without, "invalid" for a bad signature or a nonce seen before).
        var trustedPhone: TrustedSigner?
    }

    /// A phone's signing key as the Mac keeps it.
    struct TrustedSigner: Sendable, Equatable {
        var phoneID: String
        /// P-256, X9.63.
        var publicKey: Data
    }

    /// A request as the server received it.
    struct Received: Equatable, Sendable {
        var op: String
        var fields: [String: JSONValue]
    }

    private let lock = NSLock()
    private var state: State
    private var subscribed = false
    private var nonces: Set<String> = []
    private var log: [Received] = []
    private let keepsSecrets: Bool
    /// Where lines to the client go.
    private var outbound: (@Sendable (Data) -> Void)?
    private var hangUp: (@Sendable () -> Void)?

    /// `keepsSecrets`: whether received sign-in answers keep their password (tests only; the demo never does).
    init(state: State = State(), keepsSecrets: Bool = false) {
        self.state = state
        self.keepsSecrets = keepsSecrets
    }

    var received: [Received] { lock.withLock { log } }
    var isSubscribed: Bool { lock.withLock { subscribed } }

    func update(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }

    // MARK: Wiring

    /// A transport for a `CompanionClient`, connected to this server in memory.
    func makeTransport() -> CompanionTransport {
        let (toClient, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        attach(write: { continuation.yield($0) }, hangUp: { continuation.finish() })
        return MemoryTransport(server: self, toClient: toClient)
    }

    /// Connects the server to any byte sink (the stdout of an exec channel in the SSH tests). Feed what the client
    /// sends into the returned `Feeder`.
    @discardableResult
    func attach(write: @escaping @Sendable (Data) -> Void, hangUp: @escaping @Sendable () -> Void) -> Feeder {
        lock.withLock {
            outbound = write
            self.hangUp = hangUp
            subscribed = false
        }
        return Feeder(server: self)
    }

    /// Splits what the client sends into lines and answers them.
    final class Feeder: @unchecked Sendable {
        private let server: MockCompanionServer
        private let lock = NSLock()
        private var splitter = LineSplitter()

        fileprivate init(server: MockCompanionServer) { self.server = server }

        func feed(_ data: Data) {
            let lines = lock.withLock { (try? splitter.append(data)) ?? [] }
            for line in lines where !line.isEmpty {
                if let answer = server.handle(line: line) { server.write(answer) }
            }
        }
    }

    /// Sends an event to the client (only after it subscribed, like the Mac).
    func emit(_ event: CompanionEvent) {
        guard lock.withLock({ subscribed }) else { return }
        write(Self.line(for: event))
    }

    /// Ends the connection from the Mac's side.
    func disconnect() {
        let hangUp = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.hangUp = nil; outbound = nil }
            return self.hangUp
        }
        hangUp?()
    }

    fileprivate func write(_ data: Data) {
        lock.withLock { outbound }?(data)
    }

    // MARK: Handling

    /// Handles one request line; returns the answer line (with "\n").
    func handle(line: Data) -> Data? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), let object = value.object,
              let id = object["id"]?.int, let op = object["op"]?.string else { return nil }
        var fields = object
        if !keepsSecrets, fields["password"] != nil { fields["password"] = .string("•••") }
        let state: State = lock.withLock {
            log.append(Received(op: op, fields: fields))
            return self.state
        }
        if let trusted = state.trustedPhone, let refusal = check(op: op, object: object, trusted: trusted) {
            return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string(refusal.message),
                                "code": .string(refusal.code)])
        }
        if op == "subscribe" { lock.withLock { subscribed = true } }
        if let message = state.refuse[op] {
            var refusal: [String: JSONValue] = ["id": .number(Double(id)), "ok": .bool(false), "error": .string(message)]
            if let code = state.refuseCode[op] { refusal["code"] = .string(code) }
            return Self.encode(refusal)
        }
        var body: [String: JSONValue] = ["id": .number(Double(id)), "ok": .bool(true)]
        if let action = MacAction(rawValue: op), !state.oldMac {
            if action.rawValue.hasPrefix("chats.") {
                // As aOS on the Mac: the chat's id must be one, a restart only for one that runs there.
                if let refusal = chatAction(action, id: object["text"]?.string) {
                    var answer: [String: JSONValue] = ["id": .number(Double(id)), "ok": .bool(false),
                                                       "error": .string(refusal.message)]
                    if let code = refusal.code { answer["code"] = .string(code) }
                    return Self.encode(answer)
                }
                body["chats"] = .object(chatsJSON())
            }
            body["status"] = .object(macAction(action, value: object["text"]?.string))
            if action == .sleep {
                body["sleeping"] = .bool(true)
                body["after"] = .number(1.5)
            }
            return Self.encode(body)
        }
        switch op {
        case "hello":
            body["mac"] = .string(state.macName)
            body["aos"] = .string(state.aosVersion)
            if !state.oldMac {
                body["features"] = .array((MacAction.allCases.map(\.rawValue) + ["term"]).map { .string($0) })
            }
        case "status":
            var workspace: [String: JSONValue] = ["state": .string(Self.raw(state.workspace.state)),
                                                  "purpose": .string(state.workspace.purpose)]
            if let until = state.workspace.until { workspace["until"] = .string(ISO8601.format(until)) }
            body["workspace"] = .object(workspace)
            body["sessions"] = .array(state.workspace.sessions.map {
                .object(["title": .string($0.title), "state": .string($0.state)])
            })
        case "subscribe", "signin.answer", "help.done", "approval.answer", "type":
            break
        case "display":
            // The size it asked for, or the workspace's own one
            let parts = (object["text"]?.string ?? "").split(separator: "@").first?.split(separator: "x") ?? []
            body["width"] = .number(Double(parts.count == 2 ? Int(parts[0]) ?? 1280 : 1280))
            body["height"] = .number(Double(parts.count == 2 ? Int(parts[1]) ?? 800 : 800))
            body["lease"] = .number(45)
        case "screen":
            guard let target = object["target"]?.string.flatMap(ScreenTarget.init(rawValue:)),
                  let endpoint = state.screens[target] else {
                return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string("no such screen")])
            }
            var login: [String: JSONValue] = ["host": .string(endpoint.host), "port": .number(Double(endpoint.port))]
            if let username = endpoint.username { login["username"] = .string(username) }
            if let password = endpoint.password { login["password"] = .string(password) }
            guard target == .workspace else {
                body.merge(login) { $1 }
                break
            }
            // As aOS on the Mac: the workspace's login only sealed to the request's one-time key, never in plaintext
            guard let key = object["reply"]?.string.flatMap({ Data(base64Encoded: $0) }) else {
                return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "code": .string("update"),
                                    "error": .string("Update aOS on the iPhone to see the workspace.")])
            }
            let auth = CompanionAuth(object["auth"])
            var plaintext = Self.encode(login)
            plaintext.removeLast()
            guard let sealed = try? ScreenSeal.seal(plaintext, to: key, op: "companion.screen", phone: auth?.key ?? "",
                                                    nonce: auth?.nonce ?? "") else {
                return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string("bad key")])
            }
            body["sealed"] = sealed.json
        default:
            return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string("unknown op \(op)")])
        }
        return Self.encode(body)
    }

    // MARK: The Overview

    /// A MacBook on battery with the lid open, staying awake with the lid closed, the workspace open for the agent.
    static let demoMacStatus: [String: JSONValue] = [
        "power": .object(["source": .string("battery"), "battery": .number(76), "charging": .bool(false),
                          "minutes": .number(312), "lid": .string("open"), "thermal": .string("nominal")]),
        "display": .object(["state": .string("on"), "external": .number(0)]),
        "awake": .object(["setting": .string("lidClosed"), "holding": .bool(true), "lidClosedMode": .bool(false),
                          "helper": .string("enabled"), "otherService": .bool(false)]),
        "workspace": .object(["state": .string("open"), "setupComplete": .bool(true),
                              "purpose": .string("Rechnungen herunterladen"),
                              "until": .string(ISO8601.format(Date().addingTimeInterval(25 * 60)))]),
        "session": .object(["enabled": .bool(true), "state": .string("running"),
                            "since": .string(ISO8601.format(Date().addingTimeInterval(-3 * 3600)))]),
        "newChats": .object(["enabled": .bool(true), "state": .string("running")]),
        "kept": .object(["enabled": .bool(true), "running": .number(2)]),
        "bitwarden": .object(["state": .string("unlocked")]),
        "routines": .object([
            "items": .array([
                .object(["id": .string("7D0B3C52-6F7E-4B0F-9F4F-4C3B2C1E0A01"), "name": .string("Morgen-Briefing"),
                         "schedule": .string("0 6 * * *"),
                         "prompt": .string("Lies prompts/morning-briefing.md und arbeite den Ablauf ab."),
                         "enabled": .bool(true), "next": .string(ISO8601.format(Date().addingTimeInterval(14 * 3600)))]),
                .object(["id": .string("7D0B3C52-6F7E-4B0F-9F4F-4C3B2C1E0A02"), "name": .string("Routine-Check"),
                         "schedule": .string("13 14 * * *"),
                         "prompt": .string("Lies prompts/routine-check.md und arbeite den Ablauf ab."),
                         "enabled": .bool(true), "next": .string(ISO8601.format(Date().addingTimeInterval(2 * 3600)))]),
                .object(["id": .string("7D0B3C52-6F7E-4B0F-9F4F-4C3B2C1E0A03"), "name": .string("Wochenplanung"),
                         "schedule": .string("30 17 * * 0"),
                         "prompt": .string("Lies prompts/weekly-planning.md und arbeite den Ablauf ab."),
                         "enabled": .bool(false)]),
            ]),
            "reminders": .array([.object(["name": .string("Zahnarzt anrufen"),
                                          "at": .string(ISO8601.format(Date().addingTimeInterval(5 * 3600)))])]),
            "queued": .number(0),
            "recent": .array([.object(["kind": .string("routine"), "name": .string("Routine-Check"),
                                       "at": .string(ISO8601.format(Date().addingTimeInterval(-2 * 3600)))])]),
        ]),
    ]

    /// What the Mac does for an action, on the status it reports.
    private func macAction(_ action: MacAction, value: String?) -> [String: JSONValue] {
        lock.withLock {
            var status = state.macStatus
            func set(_ section: String, _ key: String, _ v: JSONValue) {
                var o = status[section]?.object ?? [:]
                o[key] = v
                status[section] = .object(o)
            }
            switch action {
            case .stayAwake:
                if let value { set("awake", "setting", .string(value)); set("awake", "holding", .bool(value == "lidClosed")) }
            case .workspaceStart:
                set("workspace", "state", .string("starting"))
            case .workspaceStop:
                set("workspace", "state", .string("stopped"))
                if var w = status["workspace"]?.object {
                    w["purpose"] = nil
                    w["until"] = nil
                    status["workspace"] = .object(w)
                }
            case .bitwardenLock:
                set("bitwarden", "state", .string("locked"))
            case .sessionRestart:
                set("session", "state", .string("restarting"))
            case .displayOff:
                set("display", "state", .string("off"))
            case .displayOn:
                set("display", "state", .string("on"))
            case .batteryLimit:
                if let value, let p = Int(value) { set("awake", "batteryLimit", .number(Double(p))) }
            case .routineSet:
                // As the Mac does: replace the routine with the same id, or add it
                if let value, let data = value.data(using: .utf8),
                   let routine = try? JSONDecoder().decode(MacStatus.Routines.Item.self, from: data) {
                    var r = status["routines"]?.object ?? [:]
                    var items = r["items"]?.array ?? []
                    let entry: JSONValue = .object(["id": .string(routine.id), "name": .string(routine.name),
                                                    "schedule": .string(routine.schedule), "prompt": .string(routine.prompt),
                                                    "enabled": .bool(routine.enabled)])
                    if let i = items.firstIndex(where: { $0.object?["id"]?.string == routine.id }) { items[i] = entry }
                    else { items.append(entry) }
                    r["items"] = .array(items)
                    status["routines"] = .object(r)
                }
            case .routineDelete:
                var r = status["routines"]?.object ?? [:]
                r["items"] = .array((r["items"]?.array ?? []).filter { $0.object?["id"]?.string != value })
                status["routines"] = .object(r)
            case .chatsList, .chatsPin, .chatsUnpin, .chatsSkip, .chatsUnskip, .chatsRestart:
                set("kept", "running", .number(Double(state.chats.filter { $0.state == "running" }.count)))
            case .status, .sleep, .routineRun:
                break
            }
            state.macStatus = status
            return status
        }
    }

    // MARK: Chats

    /// Chats in all their states: pinned and running, open in the Claude app, running, waiting for a sign-in,
    /// stopped from the phone, from a terminal, not used for days.
    static func demoChats(now: Date = Date()) -> [ChatList.Chat] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return ordered([
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e01", title: "aOS: Chats auf dem iPhone", folder: "~/Developer/annex",
                  origin: "app", activity: ago(4), pinned: true, state: "running", since: ago(180)),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e02", title: "Bachelorarbeit: Gliederung", folder: "~/Uni/Bachelorarbeit",
                  origin: "app", activity: ago(2), state: "openElsewhere", detail: "open in the Claude app", note: "app",
                  since: ago(2)),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e03", title: "Rechnungen vom Oktober sortieren",
                  folder: "~/Documents/Finanzen", origin: "app", activity: ago(35), state: "running", since: ago(30)),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e04", title: "Website: QR-Code-Abschnitt", folder: "~/Developer/marquart.dev",
                  origin: "app", activity: ago(190), state: "needsAttention", detail: "Claude Code needs a sign-in",
                  note: "signIn", since: ago(20)),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e05", title: "Morgenbriefing", folder: "~/cloupi", origin: "app",
                  activity: ago(300), skipped: true, reason: "skipped"),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e06", title: "Tailscale auf dem iPhone testen", folder: "~/Developer/annex",
                  origin: "terminal", activity: ago(26 * 60), reason: "terminal"),
            .init(id: "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e07", title: "Umzugskartons zählen", folder: "~", origin: "app",
                  activity: ago(4 * 24 * 60), reason: "inactive"),
        ])
    }

    /// The Mac's order: pinned first, then by last use.
    static func ordered(_ chats: [ChatList.Chat]) -> [ChatList.Chat] {
        chats.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.activity != b.activity { return (a.activity ?? .distantPast) > (b.activity ?? .distantPast) }
            return a.id < b.id
        }
    }

    /// What the Mac does for a chats op, or why it refuses (with the Mac's code, if it has one).
    private func chatAction(_ action: MacAction, id: String?) -> (code: String?, message: String)? {
        lock.withLock {
            guard action != .chatsList else { return nil }
            guard let id, let index = state.chats.firstIndex(where: { $0.id == id }) else {
                return (nil, "Not a conversation: \(id ?? "")")
            }
            var c = state.chats[index]
            switch action {
            case .chatsPin:
                c.pinned = true
                c.skipped = false
                if c.state == nil { c.state = "starting"; c.reason = nil; c.since = Date() }
            case .chatsUnpin:
                c.pinned = false
            case .chatsSkip:
                c.skipped = true
                c.pinned = false
                c.state = nil; c.detail = nil; c.note = nil; c.reason = "skipped"
            case .chatsUnskip:
                c.skipped = false
                c.reason = c.origin == "terminal" ? "terminal" : "overLimit"
            case .chatsRestart:
                guard state.chatsRestart else {
                    return ("keeper-old", "aOS's background process on the Mac is from an older version and can't restart a single conversation. It can after the Mac restarts.")
                }
                guard ["running", "starting", "needsAttention", "failed"].contains(c.state ?? "") else {
                    return ("not-kept", "aOS doesn't run this conversation right now, so there is nothing to restart.")
                }
                c.state = "starting"; c.detail = "restarting"; c.note = "restarting"; c.since = Date()
            default:
                break
            }
            state.chats[index] = c
            state.chats = Self.ordered(state.chats)
            return nil
        }
    }

    private func chatsJSON() -> [String: JSONValue] { lock.withLock { Self.chatsJSON(state) } }

    static func chatsJSON(_ state: State) -> [String: JSONValue] {
        let list: [JSONValue] = state.chats.map { c in
            var o: [String: JSONValue] = ["id": .string(c.id), "title": .string(c.title), "folder": .string(c.folder),
                                          "pinned": .bool(c.pinned), "skipped": .bool(c.skipped)]
            if let origin = c.origin { o["origin"] = .string(origin) }
            if let activity = c.activity { o["activity"] = .string(ISO8601.format(activity)) }
            if let s = c.state { o["state"] = .string(s) }
            if let detail = c.detail { o["detail"] = .string(detail) }
            if let note = c.note { o["note"] = .string(note) }
            if let since = c.since { o["since"] = .string(ISO8601.format(since)) }
            if let reason = c.reason { o["reason"] = .string(reason) }
            return .object(o)
        }
        return ["enabled": .bool(state.chatsEnabled), "automatic": .bool(true), "terminal": .bool(false),
                "hours": .number(48), "max": .number(6),
                "running": .number(Double(state.chats.filter { $0.state == "running" }.count)),
                "restart": .bool(state.chatsRestart), "list": .array(list)]
    }

    // MARK: Signatures (as aOS on the Mac checks them)

    /// Why the Mac would refuse this request, or nil if the trusted phone signed it.
    private func check(op: String, object: [String: JSONValue], trusted: TrustedSigner) -> (code: String, message: String)? {
        guard let auth = CompanionAuth(object["auth"]), auth.key == trusted.phoneID else {
            return ("pair-again", "This iPhone can't approve on this Mac until it is paired again.")
        }
        guard abs(Double(auth.ts) - Date().timeIntervalSince1970) <= 120 else {
            return ("clock", "The iPhone's clock and the Mac's differ by more than 2 minutes.")
        }
        guard let message = CompanionSignature.message(Self.signatureFields(op: op, object: object, auth: auth)),
              let raw = Data(base64Encoded: auth.sig), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              let key = try? P256.Signing.PublicKey(x963Representation: trusted.publicKey),
              key.isValidSignature(signature, for: message) else {
            return ("invalid", "The request's signature doesn't check out.")
        }
        guard lock.withLock({ nonces.insert(auth.nonce).inserted }) else {
            return ("invalid", "This request was sent before.")
        }
        return nil
    }

    /// What the Mac signs over, read from the line the way the Mac reads it: `aos-companion` passes on only the fields
    /// each operation has, the app derives the decision from them (AOSKit `CompanionSignature.fields(for:auth:)`).
    static func signatureFields(op: String, object: [String: JSONValue], auth: CompanionAuth) -> CompanionSignature.Fields {
        let macOp = ["hello", "status", "subscribe", "screen", "type", "display"].contains(op) || MacAction(rawValue: op) != nil
            ? "companion." + op : op
        var f = CompanionSignature.Fields(op: macOp, key: auth.key, ts: auth.ts, nonce: auth.nonce)
        func text(_ name: String) -> String? { object[name]?.string }
        if MacAction(rawValue: op) != nil {
            // aos-companion passes on only the text; the app signs over it.
            if let value = text("text") { f.data = CompanionSignature.dataDigest(text: value) }
            return f
        }
        switch op {
        case "screen":
            f.target = text("target") == "workspace" ? "workspace" : "mac"
            f.data = CompanionSignature.dataDigest(reply: text("reply"))
        case "signin.answer":
            f.request = text("request") ?? ""
            f.host = text("host") ?? ""
            f.login = text("login") ?? ""
            if object["decline"]?.bool == true { f.decision = "decline" }
            else if text("login") != nil { f.decision = "login" }
            else if text("username") != nil || text("password") != nil { f.decision = "fill" }
            else if text("totp") != nil { f.decision = "code" }
            f.data = CompanionSignature.dataDigest(username: text("username"), password: text("password"),
                                                   totp: text("totp"))
        case "type":
            f.data = CompanionSignature.dataDigest(text: text("text"))
        case "display":
            f.target = text("target") ?? ""
            f.data = CompanionSignature.dataDigest(text: text("text"))
        case "help.done":
            f.request = text("request") ?? ""
            f.decision = "done"
        case "approval.answer":
            f.request = text("request") ?? ""
            f.decision = object["allowed"]?.bool == true ? "allow" : "deny"
        default:
            break
        }
        return f
    }

    // MARK: Encoding

    static func line(for event: CompanionEvent) -> Data {
        switch event {
        case .signIn(let r):
            var object: [String: JSONValue] = ["event": .string("signin"), "request": .string(r.id),
                                               "agent": .string(r.agent), "host": .string(r.host),
                                               "purpose": .string(r.purpose)]
            if let expires = r.expires { object["expires"] = .string(ISO8601.format(expires)) }
            object["field"] = .string(r.field.rawValue)
            object["bitwarden"] = .string(r.bitwarden.rawValue)
            object["logins"] = .array(r.logins.map {
                .object(["id": .string($0.id), "name": .string($0.name), "username": .string($0.username),
                         "totp": .bool($0.hasCode)])
            })
            return encode(object)
        case .signInClosed(let request, let result):
            return encode(["event": .string("signin.closed"), "request": .string(request),
                           "result": .string(result.rawValue)])
        case .help(let h):
            var object: [String: JSONValue] = ["event": .string("help"), "request": .string(h.id),
                                               "agent": .string(h.agent), "purpose": .string(h.purpose)]
            if let r = h.region {
                object["region"] = .object(["x": .number(r.x), "y": .number(r.y), "w": .number(r.width),
                                            "h": .number(r.height)])
            }
            return encode(object)
        case .helpClosed(let request):
            return encode(["event": .string("help.closed"), "request": .string(request)])
        case .approval(let a):
            var object: [String: JSONValue] = ["event": .string("approval"), "request": .string(a.id),
                                               "agent": .string(a.agent), "purpose": .string(a.purpose)]
            if let minutes = a.minutes { object["minutes"] = .number(Double(minutes)) }
            if let expires = a.expires { object["expires"] = .string(ISO8601.format(expires)) }
            return encode(object)
        case .approvalClosed(let request, let result):
            return encode(["event": .string("approval.closed"), "request": .string(request),
                           "result": .string(result.rawValue)])
        case .mac(let state, let detail):
            return encode(["event": .string("mac"), "state": .string(state), "detail": .string(detail)])
        case .workspace(let state):
            return encode(["event": .string("workspace"), "state": .string(raw(state))])
        case .chats:
            return encode(["event": .string("chats")])
        case .subscriptionEnded:
            return encode(["event": .string("subscription"), "state": .string("ended")])
        }
    }

    static func raw(_ state: WorkspaceState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .open: "open"
        case .closing: "closing"
        case .other(let s): s
        }
    }

    private static func encode(_ object: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// Client side of the in-memory connection.
private final class MemoryTransport: CompanionTransport, @unchecked Sendable {
    private let server: MockCompanionServer
    private let feeder: MockCompanionServer.Feeder
    private let toClient: AsyncThrowingStream<Data, Error>
    private let lock = NSLock()
    private var closed = false

    init(server: MockCompanionServer, toClient: AsyncThrowingStream<Data, Error>) {
        self.server = server
        self.toClient = toClient
        feeder = MockCompanionServer.Feeder(server: server)
    }

    func send(_ data: Data) async throws {
        if lock.withLock({ closed }) { throw CompanionError.closed }
        feeder.feed(data)
    }

    func incoming() -> AsyncThrowingStream<Data, Error> { toClient }

    func close() async {
        lock.withLock { closed = true }
        server.disconnect()
    }
}
