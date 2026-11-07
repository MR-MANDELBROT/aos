import Darwin
import Foundation

/// One terminal session on the Mac: a login shell in a pseudo terminal, held by this object (in its own process,
/// `aos-companion term hold`) so it outlives the SSH connection that started it. One client at a time attaches over
/// the session's socket; a new one takes the session over. The output of the last while stays in a ring
/// (`TermRing`): a client that comes back gets what it missed, one that has nothing gets the last part and the
/// modes in effect, and the program in the foreground is asked to draw itself again. The session ends when the
/// shell exits or someone ends it (`TermHello.Op.end`): the shell gets SIGHUP, as when a terminal window closes,
/// and SIGKILL 3 s later if it is still there.
public final class TermHolder: @unchecked Sendable {
    public struct Config: Sendable {
        public var dir: URL
        public var id: String
        /// The shell and its argv[0] ("-zsh": a login shell, as sshd starts one).
        public var shell: String
        public var argv0: String
        public var environment: [String: String]
        public var home: String
        public var cols: UInt16
        public var rows: UInt16
        public var ringCapacity = 1 << 20
        /// What a client that starts afresh gets of the output (about).
        public var replayBudget = 256 * 1024

        public init(dir: URL, id: String, shell: String, argv0: String? = nil, environment: [String: String],
                    home: String, cols: UInt16, rows: UInt16) {
            self.dir = dir
            self.id = id
            self.shell = shell
            self.argv0 = argv0 ?? "-" + (shell as NSString).lastPathComponent
            self.environment = environment
            self.home = home
            self.cols = cols
            self.rows = rows
        }
    }

    public enum Failure: LocalizedError {
        case listen(String)
        case shell(Int32)
        public var errorDescription: String? {
            switch self {
            case .listen(let why): return "The session's socket could not be opened: \(why)"
            case .shell(let code): return "The shell could not be started (\(String(cString: strerror(code))))."
            }
        }
    }

    public let config: Config
    public var log: (String) -> Void = { _ in }

    private var ring: TermRing
    private var master: Int32 = -1
    private var masterOpen = false
    private var shellPID: pid_t = 0
    private var listenFD: Int32 = -1
    /// A byte here ends the session (the daemon's SIGTERM, `requestEnd()`).
    private var control: (read: Int32, write: Int32) = (-1, -1)
    private var client: Client?
    private var pending: [Pending] = []
    private var toShell: [UInt8] = []
    private var cols: UInt16
    private var rows: UInt16
    private let created = Date()
    private var since = Date()
    private var lastOutput: Date?
    private var endReason: TermEnd.Reason = .exited
    private var killAt: Date?

    private final class Client {
        let fd: Int32
        var reader = TermFrameReader()
        /// The offset of the next output byte this client gets.
        var sent: UInt64
        /// One encoded frame (or its rest) on its way out.
        var outbox: [UInt8]
        var outboxPosition = 0
        var from: String?

        init(fd: Int32, sent: UInt64, outbox: [UInt8], from: String?) {
            self.fd = fd
            self.sent = sent
            self.outbox = outbox
            self.from = from
        }
    }

    private struct Pending {
        let fd: Int32
        var reader = TermFrameReader()
        let deadline: Date
    }

    public init(config: Config) {
        self.config = config
        ring = TermRing(capacity: config.ringCapacity)
        cols = max(config.cols, 2)
        rows = max(config.rows, 2)
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); TermSocket.setNonBlocking(fd) }
            control = (fds[0], fds[1])
        }
    }

    /// The socket's write end of the control pipe (for a signal handler: writing one byte ends the session).
    public var controlWriteFD: Int32 { control.write }

    /// Ends the session from another thread.
    public func requestEnd() {
        var byte: UInt8 = 1
        _ = write(control.write, &byte, 1)
    }

    // MARK: Running

    /// Opens the socket, starts the shell and serves until the session ends. Returns the shell's exit status.
    public func run() throws -> Int32 {
        try TermPlace.prepare(config.dir)
        guard control.read >= 0 else { throw Failure.listen("no pipe") }
        try listen()
        do {
            try spawnShell()
        } catch {
            closeListener()
            throw error
        }
        log("session \(config.id): \(config.shell) started (pid \(shellPID)), \(cols)x\(rows)")
        let status = serve()
        closeListener()
        log("session \(config.id) ended: \(endReason.rawValue), status \(status)")
        return status
    }

    private func serve() -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let status = reapShell() { return finish(status: status, buffer: &buffer) }
            if let killAt, Date() >= killAt {
                signalShell(SIGKILL)
                self.killAt = nil
            }
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: control.read, events: Int16(POLLIN), revents: 0)]
            let masterIndex = fds.count
            if masterOpen {
                fds.append(pollfd(fd: master, events: Int16(POLLIN) | (toShell.isEmpty ? 0 : Int16(POLLOUT)), revents: 0))
            }
            let clientIndex = fds.count
            if let client {
                let wantsOut = client.outboxPosition < client.outbox.count || client.sent < ring.end
                fds.append(pollfd(fd: client.fd, events: Int16(POLLIN) | (wantsOut ? Int16(POLLOUT) : 0), revents: 0))
            }
            let pendingIndex = fds.count
            for p in pending { fds.append(pollfd(fd: p.fd, events: Int16(POLLIN), revents: 0)) }

            let ready = poll(&fds, nfds_t(fds.count), 250)
            if ready < 0 && errno != EINTR { usleep(50_000) }

            if fds[1].revents != 0 { drainControl(); beginEnd() }
            if masterOpen {
                let r = fds[masterIndex].revents
                if r & Int16(POLLIN | POLLHUP | POLLERR) != 0 { readShell(&buffer) }
                if masterOpen, r & Int16(POLLOUT) != 0 { writeShell() }
            }
            if client != nil, fds.count > clientIndex, fds[clientIndex].fd == client?.fd {
                let r = fds[clientIndex].revents
                if r & Int16(POLLIN | POLLHUP | POLLERR) != 0 { readClient(&buffer) }
                if client != nil, r & Int16(POLLOUT) != 0 { writeClient() }
            }
            // Pending connections: read their hello (in reverse, so removing one keeps the indexes right).
            let waiting = pending
            for (k, p) in waiting.enumerated().reversed() where fds[pendingIndex + k].revents != 0 {
                readPending(index: k, fd: p.fd, buffer: &buffer)
            }
            pending.removeAll { p in
                guard Date() > p.deadline else { return false }
                close(p.fd)
                return true
            }
            if fds[0].revents & Int16(POLLIN) != 0 { acceptWaiting() }
        }
    }

    // MARK: The shell

    private func spawnShell() throws {
        var env = config.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["AOS_TERM_SESSION"] = config.id
        // The first client's terminal is gone soon; programs must not write there.
        env.removeValue(forKey: "SSH_TTY")
        let argv = [strdup(config.argv0)] + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(config.shell)
        let home = strdup(config.home)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path)
            free(home)
        }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        var none = sigset_t()
        sigemptyset(&none)
        let pid = forkpty(&fd, nil, nil, &size)
        if pid == 0 {
            // Only async-signal-safe calls until exec.
            for sig in 1..<NSIG { signal(sig, SIG_DFL) }
            sigprocmask(SIG_SETMASK, &none, nil)
            _ = chdir(home)
            execve(path, argv, envp)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.shell(errno) }
        shellPID = pid
        master = fd
        masterOpen = true
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        TermSocket.setNonBlocking(fd)
    }

    /// The shell's exit status once it ended.
    private func reapShell() -> Int32? {
        var status: Int32 = 0
        let r = waitpid(shellPID, &status, WNOHANG)
        guard r == shellPID else { return nil }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    private func readShell(_ buffer: inout [UInt8]) {
        // At most 256 KB per turn, so a flood of output doesn't keep clients and new connections waiting.
        var total = 0
        while total < 256 * 1024 {
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                buffer.withUnsafeBufferPointer { ring.append(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                total += n
                lastOutput = Date()
                continue
            }
            if n == -1 && errno == EINTR { continue }
            if n == -1 && errno == EAGAIN { return }
            // EIO: every process closed the terminal; the shell's exit follows.
            masterOpen = false
            return
        }
    }

    private func writeShell() {
        while !toShell.isEmpty {
            let n = toShell.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if n > 0 { toShell.removeFirst(n); continue }
            if n == -1 && errno == EINTR { continue }
            if n == -1 && errno != EAGAIN { toShell.removeAll() }
            return
        }
    }

    /// SIGHUP to the program in the foreground and to the shell, as when a terminal window closes; SIGKILL follows.
    private func beginEnd() {
        guard killAt == nil, endReason != .ended else { return }
        endReason = .ended
        log("session \(config.id): ending")
        signalShell(SIGHUP)
        killAt = Date().addingTimeInterval(3)
    }

    private func signalShell(_ sig: Int32) {
        if masterOpen {
            let foreground = tcgetpgrp(master)
            if foreground > 0, foreground != shellPID { killpg(foreground, sig) }
        }
        if killpg(shellPID, sig) != 0 { kill(shellPID, sig) }
    }

    private func setSize(cols: UInt16, rows: UInt16) -> Bool {
        let c = max(cols, 2), r = max(rows, 2)
        guard c != self.cols || r != self.rows else { return false }
        self.cols = c
        self.rows = r
        if masterOpen { TermSocket.setWindowSize(master, cols: c, rows: r) }
        return true
    }

    /// Asks the program in the foreground to draw itself again (full-screen programs do on SIGWINCH).
    private func redraw() {
        guard masterOpen else { return }
        let foreground = tcgetpgrp(master)
        if foreground > 0 { killpg(foreground, SIGWINCH) }
    }

    // MARK: The socket

    private func drainControl() {
        var bytes = [UInt8](repeating: 0, count: 64)
        while read(control.read, &bytes, bytes.count) > 0 {}
    }

    private func listen() throws {
        let path = TermPlace.socket(config.dir, config.id).path
        var addr = try TermSocket.address(path)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw Failure.listen(String(cString: strerror(errno))) }
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0, Darwin.listen(listenFD, 8) == 0 else {
            let why = String(cString: strerror(errno))
            close(listenFD)
            throw Failure.listen(why)
        }
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        TermSocket.setNonBlocking(listenFD)
    }

    private func closeListener() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(TermPlace.socket(config.dir, config.id).path)
        }
    }

    deinit {
        // The control pipe lives as long as the object: a late `requestEnd()` must not write into a reused descriptor.
        for fd in [control.read, control.write] where fd >= 0 { close(fd) }
    }

    private func acceptWaiting() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            TermSocket.prepare(fd)
            // Only the user (the folder is the user's alone; this is the second lock).
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), pending.count < 8 else {
                close(fd)
                continue
            }
            TermSocket.setNonBlocking(fd)
            pending.append(Pending(fd: fd, deadline: Date().addingTimeInterval(5)))
        }
    }

    private func readPending(index: Int, fd: Int32, buffer: inout [UInt8]) {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close(fd)
                pending.remove(at: index)
            }
            return
        }
        pending[index].reader.append(buffer[0..<n])
        let frame: TermFrame?
        do { frame = try pending[index].reader.next() } catch {
            close(fd)
            pending.remove(at: index)
            return
        }
        guard let frame else { return }
        let reader = pending[index].reader
        pending.remove(at: index)
        guard case .hello(let data) = frame, let hello = TermJSON.decode(TermHello.self, data) else {
            close(fd)
            return
        }
        switch hello.op {
        case .attach:
            attach(fd: fd, hello: hello, reader: reader)
        case .info:
            TermSocket.writeAll(fd, TermFrame.reply(TermJSON.encode(info())).encoded, timeout: 2)
            close(fd)
        case .end:
            TermSocket.writeAll(fd, TermFrame.reply(Data("{\"ok\":true}".utf8)).encoded, timeout: 2)
            close(fd)
            beginEnd()
        }
    }

    // MARK: Clients

    private func attach(fd: Int32, hello: TermHello, reader: TermFrameReader) {
        if let old = client {
            // One at a time: the newest wins (the phone after a network change, while the old connection lingers).
            send(.end(TermJSON.encode(TermEnd(reason: .taken))), to: old)
            drop(old, note: "taken over")
        }
        let resized = setSize(cols: hello.cols ?? cols, rows: hello.rows ?? rows)
        let plan = ring.replay(have: hello.have, budget: config.replayBudget)
        let start = TermStart(session: config.id, from: plan.from, reset: plan.reset, prefix: plan.prefix, created: created)
        let c = Client(fd: fd, sent: plan.from, outbox: TermFrame.start(TermJSON.encode(start)).encoded, from: hello.from)
        c.reader = reader
        client = c
        since = Date()
        log("session \(config.id): attached\(hello.from.map { " from \($0)" } ?? "") at \(plan.from)\(plan.reset ? " (afresh)" : "")")
        // Whatever came before the reset is gone on the client's side: the program draws itself again.
        if plan.reset && !resized { redraw() }
        // Bytes that came with the hello.
        drainFrames(c)
    }

    private func readClient(_ buffer: inout [UInt8]) {
        guard let c = client else { return }
        let n = read(c.fd, &buffer, buffer.count)
        if n > 0 {
            c.reader.append(buffer[0..<n])
            drainFrames(c)
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            drop(c, note: "left")
        }
    }

    private func drainFrames(_ c: Client) {
        while client === c {
            let frame: TermFrame?
            do { frame = try c.reader.next() } catch {
                drop(c, note: "sent something unreadable")
                return
            }
            guard let frame else { return }
            switch frame {
            case .input(let bytes):
                if toShell.count + bytes.count <= 4 << 20 { toShell += bytes }
                if masterOpen { writeShell() }
            case .size(let cols, let rows):
                _ = setSize(cols: cols, rows: rows)
            case .detach:
                drop(c, note: "detached")
            default:
                break
            }
        }
    }

    private func writeClient() {
        guard let c = client else { return }
        while true {
            if c.outboxPosition >= c.outbox.count {
                c.outbox.removeAll(keepingCapacity: true)
                c.outboxPosition = 0
                if c.sent < ring.start {
                    // Too slow: what it missed is gone from the ring. It starts afresh from what the ring has.
                    let plan = ring.replay(have: nil, budget: config.replayBudget)
                    let start = TermStart(session: config.id, from: plan.from, reset: true, prefix: plan.prefix,
                                          created: created)
                    c.outbox = TermFrame.start(TermJSON.encode(start)).encoded
                    c.sent = plan.from
                    redraw()
                } else if c.sent < ring.end {
                    let chunk = ring.bytes(from: c.sent, limit: 32 * 1024)
                    c.sent += UInt64(chunk.count)
                    c.outbox = TermFrame.output(chunk).encoded
                } else {
                    return
                }
            }
            let n = c.outbox.withUnsafeBytes { raw in
                write(c.fd, raw.baseAddress!.advanced(by: c.outboxPosition), raw.count - c.outboxPosition)
            }
            if n > 0 { c.outboxPosition += n; continue }
            if n == -1 && (errno == EAGAIN || errno == EINTR) { return }
            drop(c, note: "gone")
            return
        }
    }

    /// Sends a frame right away, after whatever is on its way (a client that is about to go).
    private func send(_ frame: TermFrame, to c: Client) {
        let rest = Array(c.outbox[min(c.outboxPosition, c.outbox.count)...])
        TermSocket.writeAll(c.fd, rest + frame.encoded, timeout: 1)
        c.outbox.removeAll()
        c.outboxPosition = 0
    }

    private func drop(_ c: Client, note: String) {
        close(c.fd)
        if client === c {
            client = nil
            since = Date()
            log("session \(config.id): client \(note)")
        }
    }

    // MARK: The end

    /// The shell ended: what it wrote last still goes out, then the client hears why.
    private func finish(status: Int32, buffer: inout [UInt8]) -> Int32 {
        let deadline = Date().addingTimeInterval(0.3)
        while masterOpen, Date() < deadline {
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { break }
            readShell(&buffer)
        }
        if masterOpen { close(master) }
        masterOpen = false
        if let c = client {
            TermSocket.setNonBlocking(c.fd)
            var frames = Array(c.outbox[min(c.outboxPosition, c.outbox.count)...])
            if c.sent < ring.start { c.sent = ring.start }
            while c.sent < ring.end {
                let chunk = ring.bytes(from: c.sent, limit: 32 * 1024)
                c.sent += UInt64(chunk.count)
                frames += TermFrame.output(chunk).encoded
            }
            frames += TermFrame.end(TermJSON.encode(TermEnd(reason: endReason, status: status))).encoded
            TermSocket.writeAll(c.fd, frames, timeout: 2)
            close(c.fd)
            client = nil
        }
        for p in pending { close(p.fd) }
        pending.removeAll()
        return status
    }

    // MARK: What `term list` shows

    func info() -> TermInfo {
        var command: String?, cwd: String?
        let foreground = masterOpen ? tcgetpgrp(master) : -1
        let pid = foreground > 0 ? foreground : shellPID
        command = Self.processName(pid) ?? Self.processName(shellPID)
        cwd = Self.currentDirectory(pid) ?? Self.currentDirectory(shellPID)
        return TermInfo(id: config.id, pid: getpid(), shell: shellPID, created: created, attached: client != nil,
                        since: since, lastOutput: lastOutput, from: client?.from, command: command, cwd: cwd,
                        title: ring.modesAtEnd.title, cols: cols, rows: rows)
    }

    static func processName(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }

    static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
