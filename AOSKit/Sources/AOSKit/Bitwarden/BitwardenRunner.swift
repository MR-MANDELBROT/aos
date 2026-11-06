import Foundation

// How aOS runs Bitwarden's `bw`. In the app it never starts `bw` itself: aOS's privileged helper (aos-powerd)
// runs it as a hidden user of its own (`_aosvault`), from a folder only root can change, with its files in a folder
// only that user can read. Processes of the user (a coding agent with a shell, for example) can read the
// environment of the user's own processes, but not of another user's; so the session key and the master password
// never sit where they could read them. The helper also keeps the session key itself: the app only ever sees
// `BitwardenCLI.heldSession` in its place. `LocalBitwardenRunner` runs `bw` directly (tests and development).

/// A running `bw login` with its terminal.
public protocol BitwardenTerminal: AnyObject, Sendable {
    /// What `bw` writes to its terminal, in pieces; ends when it closed it.
    var terminal: AsyncStream<Data> { get }
    func send(_ data: Data)
    func terminate()
    /// Waits for the end: exit status and stdout.
    func result() async -> Subprocess.Result
}

extension Subprocess.Interactive: BitwardenTerminal {}

public protocol BitwardenRunner: Sendable {
    /// The runner keeps the session key (the helper): commands get `BitwardenCLI.heldSession` instead, and replies
    /// carry that in place of a new key.
    var holdsSession: Bool { get }
    func run(_ arguments: [String], environment: [String: String], secret: Data?,
             timeout: TimeInterval) async throws -> Subprocess.Result
    func interactive(_ arguments: [String], environment: [String: String], secret: Data?,
                     timeout: TimeInterval) async throws -> BitwardenTerminal
}

/// `bw` started directly by this process.
public struct LocalBitwardenRunner: BitwardenRunner {
    public let executable: String
    public var holdsSession: Bool { false }

    public init(executable: String) { self.executable = executable }

    public func run(_ arguments: [String], environment: [String: String], secret: Data?,
                    timeout: TimeInterval) async throws -> Subprocess.Result {
        try await Subprocess.run(executable, arguments, environment: environment, secret: secret, timeout: timeout)
    }

    public func interactive(_ arguments: [String], environment: [String: String], secret: Data?,
                            timeout: TimeInterval) async throws -> BitwardenTerminal {
        try Subprocess.interactive(executable, arguments, environment: environment, secret: secret, timeout: timeout)
    }
}

// MARK: The helper's protocol

/// One request to the helper's vault (JSON over its XPC connection, which only aOS may open).
public struct VaultRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        /// The hidden user, the folders and `bw` (downloaded from Bitwarden and checked, if missing): version and state.
        case prepare
        /// Downloads `bw` again (newest release).
        case update
        /// One command, to its end.
        case run
        /// `bw login` with a terminal: returns an id for read, send, terminate and result.
        case start, read, send, terminate, result
        /// Forgets the session key the helper keeps (the vault locks).
        case forget
        /// Removes everything of the account: Bitwarden's files and the session key (after `bw logout`).
        case erase
    }

    public var op: Op
    public var arguments: [String]?
    public var environment: [String: String]?
    /// Goes to `bw` as descriptor 3 (the master password for `--passwordfile /dev/fd/3`).
    public var secret: Data?
    public var timeout: Double?
    public var id: String?
    /// For send: what to type.
    public var input: Data?
    /// For read: the terminal output from this byte on.
    public var offset: Int?

    public init(op: Op, arguments: [String]? = nil, environment: [String: String]? = nil, secret: Data? = nil,
                timeout: Double? = nil, id: String? = nil, input: Data? = nil, offset: Int? = nil) {
        self.op = op
        self.arguments = arguments
        self.environment = environment
        self.secret = secret
        self.timeout = timeout
        self.id = id
        self.input = input
        self.offset = offset
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> VaultRequest? { try? JSONDecoder().decode(VaultRequest.self, from: data) }
}

public struct VaultReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public var status: Int32?
    public var stdout: Data?
    public var timedOut: Bool?
    public var id: String?
    /// For read: new terminal output, and where the next read starts.
    public var output: Data?
    public var offset: Int?
    public var ended: Bool?
    /// For prepare: `bw --version`, and whether the helper keeps a session key now.
    public var version: String?
    public var session: Bool?

    public init(ok: Bool, message: String? = nil, status: Int32? = nil, stdout: Data? = nil, timedOut: Bool? = nil,
                id: String? = nil, output: Data? = nil, offset: Int? = nil, ended: Bool? = nil, version: String? = nil,
                session: Bool? = nil) {
        self.ok = ok
        self.message = message
        self.status = status
        self.stdout = stdout
        self.timedOut = timedOut
        self.id = id
        self.output = output
        self.offset = offset
        self.ended = ended
        self.version = version
        self.session = session
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> VaultReply {
        (try? JSONDecoder().decode(VaultReply.self, from: data)) ?? VaultReply(ok: false, message: "unreadable answer")
    }
}

// MARK: The app's side

/// `bw` through aOS's helper. `send` is how requests travel (the helper's XPC client in the app; tests pass a host).
public struct HelperBitwardenRunner: BitwardenRunner {
    public typealias Send = @Sendable (VaultRequest) async -> VaultReply
    let send: Send
    public var holdsSession: Bool { true }

    public init(send: @escaping Send) { self.send = send }

    public func prepare() async -> VaultReply { await send(VaultRequest(op: .prepare, timeout: 600)) }
    public func update() async -> VaultReply { await send(VaultRequest(op: .update, timeout: 600)) }
    public func forget() async { _ = await send(VaultRequest(op: .forget)) }
    public func erase() async -> VaultReply { await send(VaultRequest(op: .erase)) }

    public func run(_ arguments: [String], environment: [String: String], secret: Data?,
                    timeout: TimeInterval) async throws -> Subprocess.Result {
        let reply = await send(VaultRequest(op: .run, arguments: arguments, environment: environment, secret: secret,
                                            timeout: timeout))
        guard reply.ok, let status = reply.status else {
            throw Subprocess.Failure.spawn("bw (aOS helper: \(reply.message ?? "no answer"))", EIO)
        }
        return Subprocess.Result(status: status, stdout: reply.stdout ?? Data(), stderr: Data(),
                                 timedOut: reply.timedOut ?? false)
    }

    public func interactive(_ arguments: [String], environment: [String: String], secret: Data?,
                            timeout: TimeInterval) async throws -> BitwardenTerminal {
        let reply = await send(VaultRequest(op: .start, arguments: arguments, environment: environment, secret: secret,
                                            timeout: timeout))
        guard reply.ok, let id = reply.id else {
            throw Subprocess.Failure.spawn("bw (aOS helper: \(reply.message ?? "no answer"))", EIO)
        }
        return HelperTerminal(id: id, send: send)
    }
}

/// A `bw login` in the helper: its terminal is read every quarter second.
final class HelperTerminal: BitwardenTerminal, @unchecked Sendable {
    let id: String
    let send: HelperBitwardenRunner.Send
    let terminal: AsyncStream<Data>
    private let poller: Task<Void, Never>

    init(id: String, send: @escaping HelperBitwardenRunner.Send) {
        self.id = id
        self.send = send
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        terminal = stream
        poller = Task {
            var offset = 0
            var quiet = 0
            while !Task.isCancelled {
                let r = await send(VaultRequest(op: .read, id: id, offset: offset))
                guard r.ok else {
                    quiet += 1
                    if quiet > 20 { break }  // the helper is gone for 5 s: end the conversation
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                quiet = 0
                if let out = r.output, !out.isEmpty { continuation.yield(out) }
                offset = r.offset ?? offset
                if r.ended == true { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            continuation.finish()
        }
    }

    deinit { poller.cancel() }

    func send(_ data: Data) {
        let id = self.id, send = self.send
        Task { _ = await send(VaultRequest(op: .send, id: id, input: data)) }
    }

    func terminate() {
        let id = self.id, send = self.send
        Task { _ = await send(VaultRequest(op: .terminate, id: id)) }
    }

    func result() async -> Subprocess.Result {
        let r = await send(VaultRequest(op: .result, timeout: 20 * 60, id: id))
        return Subprocess.Result(status: r.status ?? -1, stdout: r.stdout ?? Data(), stderr: Data(),
                                 timedOut: r.timedOut ?? false)
    }
}
