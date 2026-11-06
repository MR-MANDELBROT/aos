import Foundation

/// The Mac's side of the companion API in memory: answers requests the way `annex-companion serve` does
/// (Docs/COMPANION.md) and sends events on demand. Used by the tests and by the app's demo mode.
final class MockCompanionServer: @unchecked Sendable {
    struct State: Sendable {
        var macName = "Max’s MacBook Pro"
        var annexVersion = "0.2.0"
        var workspace = WorkspaceStatus(state: .open, purpose: "Rechnungen herunterladen",
                                        until: Date().addingTimeInterval(25 * 60),
                                        sessions: [.init(id: 0, title: "Claude Code", state: "running")])
        var screens: [ScreenTarget: ScreenEndpoint] = [
            .mac: ScreenEndpoint(host: "127.0.0.1", port: 5900),
            .workspace: ScreenEndpoint(host: "192.168.64.5", port: 5900, username: "annex", password: "demo-only"),
        ]
        /// Requests the server answers with `ok: false` and this message.
        var refuse: [String: String] = [:]
    }

    /// A request as the server received it.
    struct Received: Equatable, Sendable {
        var op: String
        var fields: [String: JSONValue]
    }

    private let lock = NSLock()
    private var state: State
    private var subscribed = false
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
            if op == "subscribe" { subscribed = true }
            return self.state
        }
        if let message = state.refuse[op] {
            return Self.encode(["id": .number(Double(id)), "ok": .bool(false), "error": .string(message)])
        }
        var body: [String: JSONValue] = ["id": .number(Double(id)), "ok": .bool(true)]
        switch op {
        case "hello":
            body["mac"] = .string(state.macName)
            body["annex"] = .string(state.annexVersion)
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

    // MARK: Encoding

    static func line(for event: CompanionEvent) -> Data {
        switch event {
        case .signIn(let r):
            var object: [String: JSONValue] = ["event": .string("signin"), "request": .string(r.id),
                                               "agent": .string(r.agent), "host": .string(r.host),
                                               "purpose": .string(r.purpose)]
            if let expires = r.expires { object["expires"] = .string(ISO8601.format(expires)) }
            object["field"] = .string(r.field.rawValue)
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
