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
        public var errorDescription: String? {
            switch self {
            case .spawn(let path, let code): return "\(path) could not be started (\(String(cString: strerror(code))))"
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
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw Failure.spawn(path, errno) }
        // Our ends must not leak into other children
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A child that exits without reading its input must not end us with SIGPIPE
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, env)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw Failure.spawn(path, rc)
        }

        let state = State()
        let stdinFD = inPipe[1], stdoutFD = outPipe[0], stderrFD = errPipe[0]
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

        // The timeout ends the child (SIGTERM, then SIGKILL); waitpid below still reaps it.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard state.markTimedOut() else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !state.isReaped { kill(pid, SIGKILL) }
            }
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        state.markReaped()
        // A grandchild may keep the output open; don't wait for it longer than a moment.
        _ = readers.wait(timeout: .now() + 2)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: code, stdout: output.out, stderr: output.err, timedOut: state.timedOut)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var timed = false
        private var reaped = false
        var timedOut: Bool { lock.withLock { timed } }
        var isReaped: Bool { lock.withLock { reaped } }
        func markReaped() { lock.withLock { reaped = true } }
        /// True if the timeout came first.
        func markTimedOut() -> Bool { lock.withLock { if reaped { return false }; timed = true; return true } }
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
}
