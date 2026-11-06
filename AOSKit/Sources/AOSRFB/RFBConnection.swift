import Foundation
import Network

public enum RFBError: LocalizedError {
    case closed
    case protocolError(String)
    case authFailed(String)
    case timeout(String)
    /// macOS' local network privacy blocks the connection (the user hasn't allowed the app, or a new build of it).
    case localNetworkDenied

    public var errorDescription: String? {
        switch self {
        case .closed: return "The screen connection closed."
        case .protocolError(let s): return "Screen sharing protocol error: \(s)"
        case .authFailed(let s): return "Screen sharing login failed: \(s)"
        case .timeout(let s): return "Screen sharing timed out (\(s))."
        case .localNetworkDenied: return "macOS doesn't allow connections to the local network."
        }
    }
}

/// A TCP byte stream with exact reads, on top of Network.framework.
public final class RFBStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.marquart.aos.rfb")
    private var buffer = Data()
    private let lock = NSLock()

    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    public func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Result<Void, Error>) -> Void = { result in
                if done { return }
                done = true
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { [connection] state in
                // Network.framework names the real reason: a "network is down" can also just mean the VM's network
                // bridge is still coming up.
                let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(denied ? RFBError.localNetworkDenied : e))
                case .cancelled: finish(.failure(RFBError.closed))
                case .waiting(let e): finish(.failure(denied ? RFBError.localNetworkDenied : e))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(RFBError.timeout("connect")))
            }
        }
    }

    public func close() { connection.cancel() }

    /// A send or receive that takes longer than this cancels the connection (its completion then fails), so a
    /// stalled screen sharing connection turns into an error and a reconnect instead of a hang.
    static let ioTimeout: TimeInterval = 20

    private func watchdog() -> DispatchWorkItem {
        let item = DispatchWorkItem { [connection] in connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.ioTimeout, execute: item)
        return item
    }

    func write(_ data: Data) async throws {
        let dog = watchdog()
        defer { dog.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receiveMore() async throws {
        let dog = watchdog()
        defer { dog.cancel() }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error {
                    cont.resume(throwing: { if case .posix(let code) = error, code == .ECANCELED { return RFBError.closed }; return error }())
                    return
                }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if complete { cont.resume(throwing: RFBError.closed); return }
                cont.resume(returning: Data())
            }
        }
        lock.withLock { buffer.append(chunk) }
    }

    func read(_ count: Int) async throws -> Data {
        while true {
            let out: Data? = lock.withLock {
                guard buffer.count >= count else { return nil }
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                return out
            }
            if let out { return out }
            try await receiveMore()
        }
    }

    func readLine() async throws -> Data {
        while true {
            let (line, tooLong): (Data?, Bool) = lock.withLock {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex...nl])
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return (line, false)
                }
                return (nil, buffer.count > 64)
            }
            if let line { return line }
            if tooLong { throw RFBError.protocolError("no version line") }
            try await receiveMore()
        }
    }

    func u8() async throws -> UInt8 { try await read(1)[0] }
    func u16() async throws -> UInt16 { let d = try await read(2); return UInt16(d[0]) << 8 | UInt16(d[1]) }
    func u32() async throws -> UInt32 {
        let d = try await read(4)
        return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
