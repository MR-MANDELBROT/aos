import Darwin
import Foundation

/// The client side of the terminal sessions: `attach` relays a terminal (the iPhone's SSH channel) to a session,
/// starting one if needed; `list` and `end` for the sessions the iPhone shows.
public enum TermClient {
    public enum Failure: LocalizedError {
        case tooMany(Int)
        case noHolder(String)
        public var errorDescription: String? {
            switch self {
            case .tooMany(let n):
                return "There are already \(n) terminal sessions on this Mac. End some of them first (in \(Brand.name) on the iPhone, or with `aos-companion term end <id>`)."
            case .noHolder(let why): return "The terminal session could not be started: \(why)"
            }
        }
    }

    /// How the iPhone (or anyone) sees an attached session end.
    public enum Exit: Int32 {
        case ended = 0
        case failed = 1
        case taken = 3
        case lost = 4
        /// The same device attached again: this was its old connection.
        case replaced = 5
    }

    // MARK: attach

    /// Attaches this process's terminal (stdin, stdout) to session `id`, or to a new session when there is no `id`
    /// or that session is gone. `have`: the offset the caller's terminal has the output up to (only for `id`).
    /// `client`: the device that attaches (the iPhone's id; its own old connection is replaced without a word).
    /// `holder`: the program that holds a new session (this executable, with `term hold`).
    public static func attach(dir: URL, id: String?, have: UInt64?, client: String? = nil, holder: String) -> Int32 {
        do { try TermPlace.prepare(dir) } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return Exit.failed.rawValue
        }
        let terminal = isatty(0) == 1
        let size = TermSocket.windowSize(0) ?? (80, 24)
        var fd: Int32 = -1
        var gone: String?
        var isNew = false
        if let id, TermPlace.isID(id) {
            if let connected = try? TermSocket.connect(TermPlace.socket(dir, id).path) {
                fd = connected
            } else {
                gone = id
                unlink(TermPlace.socket(dir, id).path)
            }
        }
        if fd < 0 {
            do {
                fd = try startSession(dir: dir, holder: holder, cols: size.cols, rows: size.rows)
                isNew = true
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                return Exit.failed.rawValue
            }
        }
        defer { close(fd) }
        let hello = TermHello(op: .attach, have: isNew || gone != nil ? nil : have, cols: size.cols, rows: size.rows,
                              from: origin(), client: client.flatMap { TermHello.isClientID($0) ? $0 : nil })
        guard TermSocket.writeAll(fd, TermFrame.hello(TermJSON.encode(hello)).encoded) else { return Exit.lost.rawValue }

        var saved = termios()
        if terminal, tcgetattr(0, &saved) == 0 {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(0, TCSANOW, &raw)
        }
        defer { if terminal { tcsetattr(0, TCSANOW, &saved) } }
        let signals = SignalPipe.install([SIGWINCH, SIGTERM, SIGHUP, SIGINT])
        return relay(fd: fd, signals: signals, isNew: isNew, gone: gone)
    }

    /// Bytes between the terminal and the session until either ends.
    private static func relay(fd: Int32, signals: Int32, isNew: Bool, gone: String?) -> Int32 {
        var reader = TermFrameReader()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var inputOpen = true
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: signals, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: inputOpen ? 0 : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, nfds_t(fds.count), -1) < 0 {
                if errno == EINTR { continue }
                return Exit.failed.rawValue
            }
            if fds[1].revents != 0 {
                for sig in SignalPipe.drain(signals) {
                    if sig == SIGWINCH {
                        if let size = TermSocket.windowSize(0) {
                            TermSocket.writeAll(fd, TermFrame.size(cols: size.cols, rows: size.rows).encoded)
                        }
                    } else {
                        // The connection went away (SIGHUP) or someone ends this client: the session stays.
                        return Exit.ended.rawValue
                    }
                }
            }
            if fds[0].revents != 0 {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 {
                    if n == -1 && errno == EINTR { continue }
                    writeOut(TermMarker.end("lost", status: nil))
                    return Exit.lost.rawValue
                }
                reader.append(buffer[0..<n])
                while true {
                    let frame: TermFrame?
                    do { frame = try reader.next() } catch { return Exit.lost.rawValue }
                    guard let frame else { break }
                    switch frame {
                    case .start(let data):
                        if let start = TermJSON.decode(TermStart.self, data) {
                            guard writeOut(TermMarker.start(start, new: isNew, gone: gone)) else { return Exit.ended.rawValue }
                        }
                    case .output(let bytes):
                        guard writeOut(bytes) else { return Exit.ended.rawValue }
                    case .end(let data):
                        let end = TermJSON.decode(TermEnd.self, data)
                        writeOut(TermMarker.end(end?.reason.rawValue ?? "ended", status: end?.status))
                        switch end?.reason {
                        case .taken: return Exit.taken.rawValue
                        case .replaced: return Exit.replaced.rawValue
                        default: return Exit.ended.rawValue
                        }
                    default:
                        break
                    }
                }
            }
            if inputOpen, fds[2].revents != 0 {
                let n = read(0, &buffer, buffer.count)
                if n > 0 {
                    guard TermSocket.writeAll(fd, TermFrame.input(Array(buffer[0..<n])).encoded) else {
                        writeOut(TermMarker.end("lost", status: nil))
                        return Exit.lost.rawValue
                    }
                } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                    // The terminal closed (the phone ended the channel): leave, the session stays.
                    TermSocket.writeAll(fd, TermFrame.detach.encoded, timeout: 1)
                    inputOpen = false
                    return Exit.ended.rawValue
                }
            }
        }
    }

    @discardableResult
    private static func writeOut(_ bytes: [UInt8]) -> Bool { TermSocket.writeAll(1, bytes, timeout: 60) }

    /// "ssh 192.168.178.31" for an SSH connection, else "this Mac".
    static func origin() -> String {
        let env = ProcessInfo.processInfo.environment
        if let client = env["SSH_CLIENT"] ?? env["SSH_CONNECTION"], let address = client.split(separator: " ").first {
            return "ssh \(address)"
        }
        return "local"
    }

    /// Starts a holder for a new session and connects to it.
    static func startSession(dir: URL, holder: String, cols: UInt16, rows: UInt16) throws -> Int32 {
        let live = list(dir: dir).count
        guard live < TermPlace.maxSessions else { throw Failure.tooMany(live) }
        let id = TermPlace.newID()
        let arguments = [holder, "term", "hold", "--dir", dir.path, "--id", id, "--cols", String(cols), "--rows", String(rows)]
        try spawnDetached(arguments)
        let path = TermPlace.socket(dir, id).path
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let fd = try? TermSocket.connect(path) { return fd }
            usleep(20_000)
        }
        throw Failure.noHolder("it didn't answer")
    }

    /// Starts a program in a session of its own (no controlling terminal: the connection closing doesn't reach it),
    /// with nothing but /dev/null for its standard descriptors.
    static func spawnDetached(_ arguments: [String]) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = arguments.map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, env)
        guard rc == 0 else { throw Failure.noHolder(String(cString: strerror(rc))) }
    }

    // MARK: list, end

    /// The live sessions in `dir`; sockets nobody answers on are removed.
    public static func list(dir: URL, timeout: TimeInterval = 1) -> [TermInfo] {
        TermPlace.ids(in: dir).compactMap { id in
            let path = TermPlace.socket(dir, id).path
            guard let fd = try? TermSocket.connect(path) else {
                unlink(path)
                return nil
            }
            defer { close(fd) }
            guard let data = request(fd: fd, TermHello(op: .info), timeout: timeout) else { return nil }
            return TermJSON.decode(TermInfo.self, data)
        }
    }

    /// Ends session `id` (its shell gets SIGHUP). False if there was no such session.
    @discardableResult
    public static func end(dir: URL, id: String, timeout: TimeInterval = 2) -> Bool {
        guard TermPlace.isID(id) else { return false }
        let path = TermPlace.socket(dir, id).path
        guard let fd = try? TermSocket.connect(path) else {
            unlink(path)
            return false
        }
        defer { close(fd) }
        return request(fd: fd, TermHello(op: .end), timeout: timeout) != nil
    }

    /// One hello, one reply.
    private static func request(fd: Int32, _ hello: TermHello, timeout: TimeInterval) -> Data? {
        guard TermSocket.writeAll(fd, TermFrame.hello(TermJSON.encode(hello)).encoded, timeout: timeout) else { return nil }
        var reader = TermFrameReader()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(deadline.timeIntervalSinceNow, 0.01) * 1000)) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            reader.append(buffer[0..<n])
            if case .reply(let data)? = try? reader.next() { return data }
        }
        return nil
    }
}

/// Signals as bytes in a pipe, for a poll loop (the handler only writes the signal's number).
enum SignalPipe {
    nonisolated(unsafe) private static var writeFD: Int32 = -1

    /// The read end; the signals' old handlers are replaced.
    static func install(_ signals: [Int32]) -> Int32 {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return -1 }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            TermSocket.setNonBlocking(fd)
        }
        writeFD = fds[1]
        for sig in signals {
            signal(sig) { number in
                var byte = UInt8(truncatingIfNeeded: number)
                _ = write(SignalPipe.writeFD, &byte, 1)
            }
        }
        signal(SIGPIPE, SIG_IGN)
        return fds[0]
    }

    static func drain(_ fd: Int32) -> [Int32] {
        var bytes = [UInt8](repeating: 0, count: 64)
        var result: [Int32] = []
        while true {
            let n = read(fd, &bytes, bytes.count)
            guard n > 0 else { break }
            result += bytes[0..<n].map { Int32($0) }
        }
        return result
    }
}
