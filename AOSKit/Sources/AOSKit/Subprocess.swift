import Darwin
import Foundation

/// Runs a program and waits for it without Foundation's Process. Process notices a child's exit through the run loop
/// of the thread that started it; on Swift concurrency threads that run loop doesn't run, and `waitUntilExit` (seen
/// in SSH.run) waited forever for a program that had long ended. Here the child is started with posix_spawn (it
/// inherits nothing but stdin, stdout and stderr) and reaped with our own waitpid, on threads of its own.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        /// Ended by the timeout (then `status` is the signal's exit status).
        public let timedOut: Bool
    }

    public enum Failure: LocalizedError {
        case spawn(String, Int32)
        case wait(String, Int32)
        public var errorDescription: String? {
            switch self {
            case .spawn(let path, let code): return "\(path) could not be started (\(String(cString: strerror(code))))"
            case .wait(let path, let code): return "\(path) ended, but its result is unknown (\(String(cString: strerror(code))))"
            }
        }
    }

    /// Async: the waiting happens on a thread of its own, never on a Swift concurrency thread.
    public static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                           cwd: String? = nil, input: Data? = nil, timeout: TimeInterval) async throws -> Result {
        let outcome: Swift.Result<Result, Error> = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Swift.Result {
                    try runBlocking(path, arguments, environment: environment, cwd: cwd, input: input, timeout: timeout)
                })
            }
        }
        return try outcome.get()
    }

    /// Blocks the calling thread until the program ended (or the timeout ended it).
    public static func runBlocking(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                                   cwd: String? = nil, input: Data? = nil, timeout: TimeInterval) throws -> Result {
        // All six ends close on exec right away: a fork elsewhere in the process (a pseudo terminal for a session)
        // must not inherit them, or the reader here would wait for an end that never comes.
        let (inRead, inWrite) = try cloexecPipe(path)
        let outPipe: (Int32, Int32), errPipe: (Int32, Int32)
        do { outPipe = try cloexecPipe(path) } catch { close(inRead); close(inWrite); throw error }
        do { errPipe = try cloexecPipe(path) } catch {
            [inRead, inWrite, outPipe.0, outPipe.1].forEach { close($0) }
            throw error
        }
        // A child that exits without reading its input must not end us with SIGPIPE
        _ = fcntl(inWrite, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // dup2 onto 0, 1 and 2 clears close-on-exec for the child's copies (the pipe ends are all above 2)
        posix_spawn_file_actions_adddup2(&actions, inRead, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.1, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.1, 2)
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child, and it starts with every signal at its default and none
        // blocked (aos-session ignores SIGTERM itself; its children must not, or the timeout couldn't end them).
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, env)
        close(inRead); close(outPipe.1); close(errPipe.1)
        guard rc == 0 else {
            close(inWrite); close(outPipe.0); close(errPipe.0)
            throw Failure.spawn(path, rc)
        }

        let state = State()
        let stdinFD = inWrite, stdoutFD = outPipe.0, stderrFD = errPipe.0
        Thread.detachNewThread {
            if let input, !input.isEmpty { writeAll(stdinFD, input) }
            close(stdinFD)
        }
        let readers = DispatchGroup()
        let output = Output()
        readers.enter()
        Thread.detachNewThread { readAll(stdoutFD) { output.appendOut($0) }; close(stdoutFD); readers.leave() }
        readers.enter()
        Thread.detachNewThread { readAll(stderrFD) { output.appendErr($0) }; close(stderrFD); readers.leave() }

        // The timeout ends the child (SIGTERM, then SIGKILL). The signal goes out only while the child hasn't
        // exited, under the same lock that notes its exit, and the child is reaped only after that note: a pid that
        // was reaped and handed to another process never gets a signal from here.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard state.signalIfRunning(pid, SIGTERM, markTimeout: true) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = state.signalIfRunning(pid, SIGKILL) }
        }

        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        state.markExited()
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        let waitError = waited == -1 ? errno : 0
        // A grandchild may keep the output open; don't wait for it longer than a moment.
        _ = readers.wait(timeout: .now() + 2)
        guard waitError == 0 else { throw Failure.wait(path, waitError) }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: code, stdout: output.out, stderr: output.err, timedOut: state.timedOut)
    }

    /// A pipe whose two ends close on exec and are above 2 (so dup2 onto 0, 1 or 2 always makes a new descriptor).
    private static func cloexecPipe(_ path: String) throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Failure.spawn(path, errno) }
        var ends: [Int32] = []
        for fd in fds {
            if fd > 2 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                ends.append(fd)
            } else {
                let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
                close(fd)
                ends.append(moved)
            }
        }
        guard ends.allSatisfy({ $0 > 2 }) else {
            ends.filter { $0 >= 0 }.forEach { close($0) }
            throw Failure.spawn(path, EMFILE)
        }
        return (ends[0], ends[1])
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var timed = false
        private var exited = false
        var timedOut: Bool { lock.withLock { timed } }
        func markExited() { lock.withLock { exited = true } }
        /// Sends the signal if the child hasn't exited yet; true if it was sent.
        func signalIfRunning(_ pid: pid_t, _ signal: Int32, markTimeout: Bool = false) -> Bool {
            lock.withLock {
                guard !exited else { return false }
                if markTimeout { timed = true }
                kill(pid, signal)
                return true
            }
        }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        var out: Data { lock.withLock { o } }
        var err: Data { lock.withLock { e } }
        func appendOut(_ d: Data) { lock.withLock { o.append(d) } }
        func appendErr(_ d: Data) { lock.withLock { e.append(d) } }
    }

    /// Reads until the end, handing over every piece as it arrives (what came before a grandchild kept the pipe
    /// open is not lost).
    private static func readAll(_ fd: Int32, _ piece: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { piece(Data(buffer[0..<n])) } else if n == -1 && errno == EINTR { continue } else { break }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n } else if n == -1 && errno == EINTR { continue } else { return }
            }
        }
    }

    // MARK: Programs that ask questions

    /// Starts a program that asks its questions on a terminal (prompt libraries such as the one in Bitwarden's
    /// command line tool need one): its stdin and stderr are a pseudo terminal, its stdout stays a pipe, so the result
    /// arrives apart from the prompts. Read the terminal with `terminal`, answer with `send`, collect the end with
    /// `result()`. Nothing here keeps or logs what passes through.
    public static func interactive(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                                   cwd: String? = nil, timeout: TimeInterval) throws -> Interactive {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Failure.spawn(path, errno) }
        // Both ends above 2 and closed on exec (a fork elsewhere in the process must not inherit them).
        func aboveTwo(_ fd: Int32) -> Int32 {
            if fd > 2 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); return fd }
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 3)
            close(fd)
            return moved
        }
        master = aboveTwo(master)
        slave = aboveTwo(slave)
        let out: (Int32, Int32)
        do {
            guard master > 2, slave > 2 else { throw Failure.spawn(path, EMFILE) }
            out = try cloexecPipe(path)
        } catch {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, out.1, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK))
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, env)
        close(slave); close(out.1)
        guard rc == 0 else {
            close(master); close(out.0)
            throw Failure.spawn(path, rc)
        }
        return Interactive(pid: pid, master: master, stdout: out.0, path: path, timeout: timeout)
    }

    /// A running program with a terminal (see `interactive`).
    public final class Interactive: @unchecked Sendable {
        public let pid: pid_t
        /// What the program writes to its terminal (its prompts, the echo of what was typed), in pieces as it comes.
        /// Ends when the program closed the terminal.
        public let terminal: AsyncStream<Data>
        private let master: Int32
        private let lock = NSLock()
        private var masterOpen = true
        private var finished: Result?
        private var waiting: [CheckedContinuation<Result, Never>] = []
        private let state = State()

        fileprivate init(pid: pid_t, master: Int32, stdout: Int32, path: String, timeout: TimeInterval) {
            self.pid = pid
            self.master = master
            let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
            terminal = stream
            let output = Output()
            let readers = DispatchGroup()
            readers.enter()
            Thread.detachNewThread { [self] in
                // The terminal: once the program and everything it started closed it, read ends with an error.
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(master, &buffer, buffer.count)
                    if n > 0 { continuation.yield(Data(buffer[0..<n])) } else if n == -1 && errno == EINTR { continue } else { break }
                }
                continuation.finish()
                lock.withLock {
                    masterOpen = false
                    close(master)
                }
                readers.leave()
            }
            readers.enter()
            Thread.detachNewThread { Subprocess.readAll(stdout) { output.appendOut($0) }; close(stdout); readers.leave() }
            let state = self.state
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.signalIfRunning(pid, SIGTERM, markTimeout: true) else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = state.signalIfRunning(pid, SIGKILL) }
            }
            Thread.detachNewThread { [self] in
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                state.markExited()
                var status: Int32 = 0
                var waited: pid_t
                repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
                _ = readers.wait(timeout: .now() + 2)
                let code: Int32 = waited == -1 ? -1 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
                let result = Result(status: code, stdout: output.out, stderr: Data(), timedOut: state.timedOut)
                let resume = lock.withLock { () -> [CheckedContinuation<Result, Never>] in
                    finished = result
                    defer { waiting = [] }
                    return waiting
                }
                resume.forEach { $0.resume(returning: result) }
            }
        }

        /// Types into the program's terminal (an answer ends with "\r", like the Return key).
        public func send(_ data: Data) {
            lock.withLock {
                guard masterOpen else { return }
                Subprocess.writeAll(master, data)
            }
        }

        /// Ends the program (SIGTERM, then SIGKILL after 2 s).
        public func terminate() {
            let state = self.state, pid = self.pid
            guard state.signalIfRunning(pid, SIGTERM) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _ = state.signalIfRunning(pid, SIGKILL) }
        }

        /// Waits until the program ended: its exit status and what it wrote to stdout (stderr went to the terminal).
        public func result() async -> Result {
            await withCheckedContinuation { continuation in
                let ready: Result? = lock.withLock {
                    if let finished { return finished }
                    waiting.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
