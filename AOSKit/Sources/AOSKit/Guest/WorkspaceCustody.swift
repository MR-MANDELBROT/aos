import Foundation

// The workspace's keys and disk in the custody of aOS's privileged helper (aos-powerd, root).
//
// A program that runs as the user (a coding agent with a shell) can read and change every file of the user. If the
// workspace's maintenance key, its account password or its disk image were such files, it could take the workspace
// over: log in as root over SSH or with the password over screen sharing, or change the disk while the workspace is
// off (a program in the account's login items), and then watch a sign-in that the person approved being typed.
// So the helper keeps them:
//   - the SSH keys, the pinned host key and the account password live in a folder of the hidden user
//     `_aosworkspace` (0700); `ssh` runs as that user, started by the helper. The app asks for a command to run in the
//     guest and gets its output; it never sees a key. It does get the account password (it types it into the guest
//     during the setup and logs in to screen sharing), held only in its memory;
//   - the disk image lives in a folder only root can open. The helper attaches it as a device (not mounted; mounting
//     its volumes is refused while it is attached) and hands the app an open descriptor of that device for the VM.
//     The device file belongs to root, so nothing else of the user can open it;
//   - the host key is pinned under a fixed name, so a VM someone else starts can't pass for the workspace, whatever
//     its address; only after the helper itself created or took over a disk may the first connection pin a new one.
// Only the signed aOS app may talk to the helper (PowerHelperService.appRequirement). `LocalWorkspaceKeys` (the files
// in Paths.keys) remains for the tests and the command line tool.

/// One request to the helper's workspace custody (JSON over its XPC connection).
public struct CustodyRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        /// What the helper holds: keys, a disk, whether it is attached, whether the host key is pinned.
        case status
        /// The hidden user, the folders, the keys and the password (each made once): the public keys.
        case prepare
        /// The guest account's password.
        case password
        /// A command in the guest over SSH (`host`, `user`, `key`, `command`, `input`, `timeout`).
        case ssh
        /// Keys, password and known hosts of an earlier aOS that kept them in the user's folder (`files`): they become
        /// the helper's, to be replaced at the next start. Only while the helper has none of its own.
        case importLegacy
        /// New keys and a new password beside the current ones (the same ones again while not committed), so the app
        /// can install them in the guest; `rotateCommit` makes them the current ones, `rotateAbort` drops them.
        case rotateBegin, rotateCommit, rotateAbort
        /// A fresh, empty disk (`gibibytes`) for a new workspace; `replace` drops one that exists.
        case createDisk
        /// Takes over the disk image of a workspace made by an earlier aOS (in the calling user's aOS folder).
        case adoptDisk
        /// Attaches the disk as a device and answers with an open descriptor of it.
        case attachDisk
        case detachDisk
        /// Removes the disk (the workspace is deleted).
        case eraseDisk
    }

    /// Which credential `ssh` uses.
    public enum Key: String, Codable, Sendable {
        /// Root, may run anything.
        case maintenance
        /// Root, may only run the orderly shutdown.
        case stop
        /// The maintenance key waiting in `rotateBegin`, to check it works before committing.
        case next
        /// The account's password (only before the bootstrap turned password logins off).
        case password
    }

    public var op: Op
    public var host: String?
    public var user: String?
    public var key: Key?
    public var command: String?
    public var input: Data?
    public var timeout: Double?
    public var gibibytes: UInt64?
    public var replace: Bool?
    /// For importLegacy: maintenance, maintenance.pub, stop, stop.pub, password, known_hosts.
    public var files: [String: Data]?
    /// For rotateCommit: the new password never reached the guest, the current one stays.
    public var keepPassword: Bool?

    public init(op: Op, host: String? = nil, user: String? = nil, key: Key? = nil, command: String? = nil,
                input: Data? = nil, timeout: Double? = nil, gibibytes: UInt64? = nil, replace: Bool? = nil,
                files: [String: Data]? = nil, keepPassword: Bool? = nil) {
        self.op = op
        self.host = host
        self.user = user
        self.key = key
        self.command = command
        self.input = input
        self.timeout = timeout
        self.gibibytes = gibibytes
        self.replace = replace
        self.files = files
        self.keepPassword = keepPassword
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> CustodyRequest? { try? JSONDecoder().decode(CustodyRequest.self, from: data) }
}

public struct CustodyReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    // ssh
    public var status: Int32?
    public var stdout: Data?
    public var stderr: String?
    public var timedOut: Bool?
    // secrets
    public var password: String?
    public var maintenancePublicKey: String?
    public var stopPublicKey: String?
    public var nextPassword: String?
    public var nextMaintenancePublicKey: String?
    public var nextStopPublicKey: String?
    // state
    public var hasKeys: Bool?
    public var hasDisk: Bool?
    public var attached: Bool?
    public var pinned: Bool?
    public var rotating: Bool?
    /// Keys taken over from an earlier aOS wait to be replaced.
    public var rotationNeeded: Bool?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }

    public static func failure(_ message: String) -> CustodyReply { CustodyReply(ok: false, message: message) }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8) }
    public static func decode(_ data: Data) -> CustodyReply {
        (try? JSONDecoder().decode(CustodyReply.self, from: data)) ?? .failure("unreadable answer")
    }
}

public enum CustodyError: LocalizedError {
    case helper(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .helper(let why): return "\(Brand.name)'s helper: \(why)"
        case .notLoaded: return "The workspace's password isn't loaded from \(Brand.name)'s helper yet."
        }
    }
}

/// The app's side: requests travel through `send` (the helper's XPC client; tests pass a host).
public struct WorkspaceCustodyClient: Sendable {
    public typealias Send = @Sendable (CustodyRequest) async -> (CustodyReply, FileHandle?)
    let send: Send

    public init(send: @escaping Send) { self.send = send }

    @discardableResult
    func call(_ request: CustodyRequest) async throws -> CustodyReply {
        let (reply, _) = await send(request)
        guard reply.ok else { throw CustodyError.helper(reply.message ?? "no answer") }
        return reply
    }

    public func status() async throws -> CustodyReply { try await call(CustodyRequest(op: .status)) }

    public func prepare() async throws -> (maintenance: String, stop: String) {
        let r = try await call(CustodyRequest(op: .prepare, timeout: 60))
        guard let m = r.maintenancePublicKey, let s = r.stopPublicKey else { throw CustodyError.helper("no public keys") }
        return (m, s)
    }

    public func password() async throws -> String {
        let r = try await call(CustodyRequest(op: .password))
        guard let p = r.password, !p.isEmpty else { throw CustodyError.helper("no password") }
        return p
    }

    public func ssh(host: String, user: String, key: CustodyRequest.Key, command: String, input: Data?,
                    timeout: TimeInterval) async throws -> Subprocess.Result {
        let (reply, _) = await send(CustodyRequest(op: .ssh, host: host, user: user, key: key, command: command,
                                                   input: input, timeout: timeout))
        guard reply.ok, let status = reply.status else {
            throw Subprocess.Failure.spawn("ssh (\(Brand.name)'s helper: \(reply.message ?? "no answer"))", EIO)
        }
        return Subprocess.Result(status: status, stdout: reply.stdout ?? Data(), stderr: Data((reply.stderr ?? "").utf8),
                                 timedOut: reply.timedOut ?? false)
    }

    public func importLegacy(_ files: [String: Data]) async throws {
        try await call(CustodyRequest(op: .importLegacy, files: files))
    }

    public func rotateBegin() async throws -> CustodyReply { try await call(CustodyRequest(op: .rotateBegin, timeout: 60)) }
    public func rotateCommit(keepPassword: Bool = false) async throws {
        try await call(CustodyRequest(op: .rotateCommit, keepPassword: keepPassword))
    }
    public func rotateAbort() async { _ = await send(CustodyRequest(op: .rotateAbort)) }

    public func createDisk(gibibytes: UInt64, replace: Bool) async throws {
        try await call(CustodyRequest(op: .createDisk, gibibytes: gibibytes, replace: replace))
    }
    public func adoptDisk() async throws { try await call(CustodyRequest(op: .adoptDisk, timeout: 120)) }

    /// The disk as an open device.
    public func attachDisk() async throws -> FileHandle {
        let (reply, handle) = await send(CustodyRequest(op: .attachDisk, timeout: 60))
        guard reply.ok, let handle else { throw CustodyError.helper(reply.message ?? "the disk wasn't attached") }
        return handle
    }

    public func detachDisk() async { _ = await send(CustodyRequest(op: .detachDisk, timeout: 60)) }
    public func eraseDisk() async throws { try await call(CustodyRequest(op: .eraseDisk, timeout: 60)) }
}

/// A value behind a lock (the custody client and the password the app holds in memory).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
