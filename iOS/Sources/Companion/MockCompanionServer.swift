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
            return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string(message)])
        }
        var body: [String: JSONValue] = ["id": .number(Double(id)), "ok": .bool(true)]
        switch op {
        case "hello":
            body["mac"] = .string(state.macName)
            body["aos"] = .string(state.aosVersion)
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
            body["host"] = .string(endpoint.host)
            body["port"] = .number(Double(endpoint.port))
            if let username = endpoint.username { body["username"] = .string(username) }
            if let password = endpoint.password { body["password"] = .string(password) }
        default:
            return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string("unknown op \(op)")])
        }
        return Self.encode(body)
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
        let macOp = ["hello", "status", "subscribe", "screen", "type", "display"].contains(op) ? "companion." + op : op
        var f = CompanionSignature.Fields(op: macOp, key: auth.key, ts: auth.ts, nonce: auth.nonce)
        func text(_ name: String) -> String? { object[name]?.string }
        switch op {
        case "screen":
            f.target = text("target") == "workspace" ? "workspace" : "mac"
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
        case .subscriptionEnded:
            return encode(["event": .string("subscription"), "state": .string("ended")])
        }
    }

    static func raw(_ state: WorkspaceState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
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
