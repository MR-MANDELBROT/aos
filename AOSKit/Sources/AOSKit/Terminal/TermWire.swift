import Darwin
import Foundation
import Security

// The terminal sessions of aOS (Docs/COMPANION.md, "Terminal sessions"): `aos-companion term attach` in the
// iPhone's SSH channel talks to a holder process that owns the shell's pseudo terminal and outlives the connection.
// Holder and client speak frames over a Unix socket in a private folder; the client tells the phone where the
// output starts with an OSC sequence on its terminal (the phone takes it out before the terminal sees it).

/// Where the sessions live: one socket per session, `<id>.sock`, in a folder only the user can open (0700).
public enum TermPlace {
    /// `AOS_TERM_DIR` (tests), otherwise run/terms in aOS's folder.
    public static func directory(paths: Paths = .default) -> URL {
        if let dir = ProcessInfo.processInfo.environment["AOS_TERM_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return paths.run.appendingPathComponent("terms", isDirectory: true)
    }

    /// Creates the folder (and its parents) if needed and makes it private.
    public static func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    public static func socket(_ dir: URL, _ id: String) -> URL { dir.appendingPathComponent("\(id).sock") }

    /// Eight lowercase hex characters.
    public static func isID(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The ids of the sockets in the folder (live or left over).
    public static func ids(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { $0.hasSuffix(".sock") ? String($0.dropLast(5)) : nil }.filter(isID).sorted()
    }

    /// At most this many sessions at a time: a runaway loop of new sessions stops here.
    public static let maxSessions = 16
}

// MARK: - Frames

/// One message between client and holder: a type byte, the payload's length (4 bytes, big endian), the payload.
public enum TermFrame: Equatable, Sendable {
    /// Client: what it wants (JSON `TermHello`), always first.
    case hello(Data)
    /// Client: typed bytes for the shell.
    case input([UInt8])
    /// Client: its terminal's size.
    case size(cols: UInt16, rows: UInt16)
    /// Client: it leaves; the session stays.
    case detach
    /// Holder: where the output starts (JSON `TermStart`).
    case start(Data)
    /// Holder: output, continuing at the offset after the previous output.
    case output([UInt8])
    /// Holder: the session is over for this client (JSON `TermEnd`).
    case end(Data)
    /// Holder: the answer to `info` or `end` (JSON).
    case reply(Data)

    static let maxPayload = 4 << 20

    var type: UInt8 {
        switch self {
        case .hello: 0x48
        case .input: 0x49
        case .size: 0x57
        case .detach: 0x44
        case .start: 0x53
        case .output: 0x4f
        case .end: 0x45
        case .reply: 0x52
        }
    }

    public var encoded: [UInt8] {
        let payload: [UInt8]
        switch self {
        case .hello(let d), .start(let d), .end(let d), .reply(let d): payload = Array(d)
        case .input(let b), .output(let b): payload = b
        case .size(let cols, let rows): payload = [UInt8(cols >> 8), UInt8(cols & 0xff), UInt8(rows >> 8), UInt8(rows & 0xff)]
        case .detach: payload = []
        }
        let n = UInt32(payload.count)
        return [type, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + payload
    }
}

/// Collects bytes and hands out whole frames.
public struct TermFrameReader: Sendable {
    public struct Malformed: Error {}
    private var buffer: [UInt8] = []
    private var position = 0

    public init() {}

    public mutating func append(_ bytes: ArraySlice<UInt8>) { buffer.append(contentsOf: bytes) }
    public mutating func append(_ bytes: [UInt8]) { buffer.append(contentsOf: bytes) }

    /// The next whole frame, nil if more bytes are needed.
    public mutating func next() throws -> TermFrame? {
        guard buffer.count - position >= 5 else { compact(); return nil }
        let type = buffer[position]
        let n = Int(buffer[position + 1]) << 24 | Int(buffer[position + 2]) << 16 | Int(buffer[position + 3]) << 8
            | Int(buffer[position + 4])
        guard n <= TermFrame.maxPayload else { throw Malformed() }
        guard buffer.count - position - 5 >= n else { compact(); return nil }
        let payload = Array(buffer[(position + 5)..<(position + 5 + n)])
        position += 5 + n
        switch type {
        case 0x48: return .hello(Data(payload))
        case 0x49: return .input(payload)
        case 0x57:
            guard n == 4 else { throw Malformed() }
            return .size(cols: UInt16(payload[0]) << 8 | UInt16(payload[1]), rows: UInt16(payload[2]) << 8 | UInt16(payload[3]))
        case 0x44: return .detach
        case 0x53: return .start(Data(payload))
        case 0x4f: return .output(payload)
        case 0x45: return .end(Data(payload))
        case 0x52: return .reply(Data(payload))
        default: throw Malformed()
        }
    }

    private mutating func compact() {
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
    }
}

// MARK: - Messages

/// The client's first frame.
public struct TermHello: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case attach, info, end }
    public var v = 1
    public var op: Op
    /// attach: the offset up to which the client's terminal already has the output (it gets only the rest).
    public var have: UInt64?
    public var cols: UInt16?
    public var rows: UInt16?
    /// Who attaches, for the list ("ssh 192.168.178.31").
    public var from: String?

    public init(op: Op, have: UInt64? = nil, cols: UInt16? = nil, rows: UInt16? = nil, from: String? = nil) {
        self.op = op
        self.have = have
        self.cols = cols
        self.rows = rows
        self.from = from
    }
}

/// The holder's answer to an attach.
public struct TermStart: Codable, Equatable, Sendable {
    public var v = 1
    public var session: String
    /// The offset of the first byte of output that follows.
    public var from: UInt64
    /// The client's terminal starts afresh, then takes `prefix` (base64), then the output.
    public var reset: Bool
    public var prefix: String
    public var created: Date

    public init(session: String, from: UInt64, reset: Bool, prefix: [UInt8], created: Date) {
        self.session = session
        self.from = from
        self.reset = reset
        self.prefix = Data(prefix).base64EncodedString()
        self.created = created
    }
}

/// Why a client's session ended.
public struct TermEnd: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The shell exited.
        case exited
        /// Someone ended the session (the list on the iPhone, `term end`).
        case ended
        /// Another client attached (one at a time).
        case taken
    }
    public var reason: Reason
    public var status: Int32?

    public init(reason: Reason, status: Int32? = nil) {
        self.reason = reason
        self.status = status
    }
}

/// A session as `term list` shows it.
public struct TermInfo: Codable, Equatable, Sendable {
    public var id: String
    /// The holder's process and the shell's.
    public var pid: Int32
    public var shell: Int32
    public var created: Date
    public var attached: Bool
    /// When the client attached, or when the last one left (or since the start, if none ever attached).
    public var since: Date
    public var lastOutput: Date?
    /// Who is attached ("ssh 192.168.178.31").
    public var from: String?
    /// The program in the foreground ("zsh", "vim", "claude") and its folder.
    public var command: String?
    public var cwd: String?
    /// The window title the program set, if any.
    public var title: String?
    public var cols: UInt16
    public var rows: UInt16

    public init(id: String, pid: Int32, shell: Int32, created: Date, attached: Bool, since: Date,
                lastOutput: Date? = nil, from: String? = nil, command: String? = nil, cwd: String? = nil,
                title: String? = nil, cols: UInt16, rows: UInt16) {
        self.id = id
        self.pid = pid
        self.shell = shell
        self.created = created
        self.attached = attached
        self.since = since
        self.lastOutput = lastOutput
        self.from = from
        self.command = command
        self.cwd = cwd
        self.title = title
        self.cols = cols
        self.rows = rows
    }
}

enum TermJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - What the phone reads

/// The client's notes to the iPhone on its terminal: `ESC ] 7730 ; <JSON> BEL`. The phone takes them out of the
/// stream before its terminal sees them (other terminals ignore an OSC they don't know). After `start` the phone
/// counts the output bytes: that is the offset it asks for when it attaches again.
///
///     {"t":"start","id":"3fa9c1d2","from":12345,"reset":false,"prefix":"<base64>","created":"<ISO>","new":true,"gone":"<old id>"}
///     {"t":"end","why":"exited|ended|taken|lost","status":0}
public enum TermMarker {
    public static let introducer: [UInt8] = [0x1b, 0x5d] + Array("7730;".utf8)

    public static func start(_ s: TermStart, new: Bool, gone: String?) -> [UInt8] {
        var object: [String: Any] = ["t": "start", "id": s.session, "from": s.from, "reset": s.reset,
                                     "prefix": s.prefix, "created": ISO8601DateFormatter().string(from: s.created),
                                     "new": new]
        if let gone { object["gone"] = gone }
        return wrap(object)
    }

    public static func end(_ why: String, status: Int32?) -> [UInt8] {
        var object: [String: Any] = ["t": "end", "why": why]
        if let status { object["status"] = Int(status) }
        return wrap(object)
    }

    static func wrap(_ object: [String: Any]) -> [UInt8] {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return introducer + Array(data) + [0x07]
    }
}

// MARK: - Sockets

enum TermSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.system("socket path too long", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Connects to a session's socket. Throws ENOENT or ECONNREFUSED for a session that is gone.
    static func connect(_ path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("connect", code)
        }
        prepare(fd)
        return fd
    }

    /// Close on exec, no SIGPIPE.
    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Writes everything, false if the other side is gone. On a descriptor that doesn't block it waits for room,
    /// `timeout` seconds at most in all.
    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n == -1 && errno == EINTR { continue }
                if n == -1 && errno == EAGAIN {
                    let left = deadline.timeIntervalSinceNow
                    guard left > 0 else { return false }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
                    continue
                }
                return false
            }
            return true
        }
    }

    // Terminal ioctls (macros Swift doesn't import).
    static let ioctlGetWindowSize: UInt = 0x4008_7468   // TIOCGWINSZ
    static let ioctlSetWindowSize: UInt = 0x8008_7467   // TIOCSWINSZ

    static func windowSize(_ fd: Int32) -> (cols: UInt16, rows: UInt16)? {
        var ws = winsize()
        guard ioctl(fd, ioctlGetWindowSize, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return nil }
        return (ws.ws_col, ws.ws_row)
    }

    static func setWindowSize(_ fd: Int32, cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, ioctlSetWindowSize, &ws)
    }
}
