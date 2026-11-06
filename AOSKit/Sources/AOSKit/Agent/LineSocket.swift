import Darwin
import Foundation

public enum SocketError: LocalizedError {
    case system(String, Int32)
    case notRunning(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .system(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        case .notRunning(let path): return "\(Brand.name) is not running (no agent at \(path)). Open the \(Brand.name) app."
        case .closed: return "The connection to \(Brand.name) closed."
        }
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
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

/// A Unix domain socket server that speaks JSON lines. Only processes of the same user may connect
/// (socket file 0600 in a 0700 folder, and the peer's uid is checked).
public final class LineSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: URL, handler: @escaping Handler) {
        self.path = path.path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = try makeAddress(path)
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { throw SocketError.system("bind \(path)", errno) }
        chmod(path, 0o600)
        // A burst of connections (several agents, a phone) must not be refused: a full backlog refuses Unix
        // socket connections at once. The listening socket doesn't block; each event takes every waiting connection.
        guard listen(fd, SOMAXCONN) == 0 else { throw SocketError.system("listen", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        let listening = fd
        src.setEventHandler { [weak self] in self?.acceptWaiting() }
        // The descriptor may only be closed once the source is cancelled (libdispatch requires it).
        src.setCancelHandler { close(listening) }
        src.resume()
        source = src
    }

    public func stop() {
        if let source {
            source.cancel()
            self.source = nil
        } else if fd >= 0 {
            close(fd)
        }
        fd = -1
        unlink(path)
    }

    private func acceptWaiting() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // EAGAIN: none left
            }
            // Accepted sockets inherit O_NONBLOCK on macOS; the connection thread reads blocking
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let handler = self.handler
        // One thread per connection with plain blocking reads. Not FileHandle.AsyncBytes: all of those share one
        // serial queue, and a connection that waits for its next line (an iPhone's long poll, an agent between
        // calls) blocked reading on every other connection.
        Thread.detachNewThread {
            defer { close(client) }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer.removeSubrange(buffer.startIndex...nl)
                    let reply = Self.wait { await handler(line) }
                    guard Self.writeAll(client, reply + Data([0x0A])) else { return }
                }
                let n = read(client, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    if buffer.count > 64 << 20 { return }  // no line is that long
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Runs the async handler and blocks this (connection) thread until it answers.
    private static func wait(_ body: @escaping @Sendable () async -> Data) -> Data {
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value ?? Data()
    }

    private final class ReplyBox: @unchecked Sendable { var value: Data? }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n } else if n == -1 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}

/// Client side: one request line, one response line.
public final class LineSocketClient: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    public init(path: URL) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = try makeAddress(path.path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw SocketError.notRunning(path.path) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Sends one line and blocks until the answer line arrives.
    public func roundTrip(_ line: Data) throws -> Data {
        try handle.write(contentsOf: line + Data([0x0A]))
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let out = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(out)
            }
            // availableData returns what has arrived (read(upToCount:) would wait for the full count).
            let chunk = handle.availableData
            guard !chunk.isEmpty else { throw SocketError.closed }
            buffer.append(chunk)
        }
    }
}

/// Typed client for the agent.
public final class AgentClient: @unchecked Sendable {
    private let socket: LineSocketClient
    private var nextID = 1
    private let lock = NSLock()

    public init(paths: Paths = .default) throws {
        socket = try LineSocketClient(path: paths.agentSocket)
    }

    /// Connects to the app; if it isn't running (and this is the real app folder), starts it in the background and
    /// waits up to 20 s for it.
    public static func connectStartingApp(paths: Paths = .default) throws -> AgentClient {
        do {
            return try AgentClient(paths: paths)
        } catch SocketError.notRunning(let path) {
            guard paths.root == Paths.default.root else { throw SocketError.notRunning(path) }
            _ = try? Subprocess.runBlocking("/usr/bin/open", ["-g", "-b", Brand.bundleIdentifierPrefix], timeout: 20)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                usleep(500_000)
                if let client = try? AgentClient(paths: paths) { return client }
            }
            throw SocketError.notRunning(path)
        }
    }

    public func send(_ build: (inout AgentRequest) -> Void) throws -> AgentResponse {
        try lock.withLock {
            var request = AgentRequest(id: nextID, op: "")
            nextID += 1
            build(&request)
            let line = try JSONEncoder().encode(request)
            let reply = try socket.roundTrip(line)
            return try JSONDecoder().decode(AgentResponse.self, from: reply)
        }
    }
}
