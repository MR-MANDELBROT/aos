import Foundation
import Network
import NIOCore
import os

private let log = Logger(subsystem: "dev.marquart.annex.ios", category: "forward")

/// `ssh -L` on the iPhone: a listener on 127.0.0.1 (random port) whose connections each open a direct-tcpip channel
/// through the SSH connection to `targetHost:targetPort` as seen from the Mac.
///
/// The screen sharing client (AnnexRFB's `RFBClient`) connects with Network.framework to a host and port, so it is
/// pointed at this listener. Only loopback connections are accepted, and the listener lives only while a screen is
/// open.
final class LocalForwarder: @unchecked Sendable {
    private let connection: SSHConnection
    private let targetHost: String
    private let targetPort: Int
    private let queue = DispatchQueue(label: "dev.marquart.annex.forward")
    private var listener: NWListener?
    private let lock = NSLock()
    private var bridges: [ObjectIdentifier: Bridge] = [:]
    private var _lastError: Error?

    /// Why the last forwarded connection couldn't be opened (the Mac refused, for example).
    var lastError: Error? { lock.withLock { _lastError } }

    init(connection: SSHConnection, targetHost: String, targetPort: Int) {
        self.connection = connection
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// Starts listening; returns the local port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.run { continuation.resume(returning: port) } }
                case .failed(let error):
                    once.run { continuation.resume(throwing: error) }
                case .cancelled:
                    once.run { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open = lock.withLock { () -> [Bridge] in
            defer { bridges.removeAll() }
            return Array(bridges.values)
        }
        open.forEach { $0.close() }
    }

    private func accept(_ nw: NWConnection) {
        let bridge = Bridge(nw: nw, queue: queue)
        let id = ObjectIdentifier(bridge)
        lock.withLock { bridges[id] = bridge }
        bridge.onClose = { [weak self] in _ = self?.lock.withLock { self?.bridges.removeValue(forKey: id) } }
        nw.start(queue: queue)
        Task {
            do {
                let channel = try await connection.directTCPIP(to: targetHost, port: targetPort) {
                    BridgeHandler(bridge: bridge)
                }
                bridge.attach(channel)
            } catch {
                log.error("Forwarding to \(self.targetHost, privacy: .public):\(self.targetPort) failed: \(String(describing: error), privacy: .public)")
                lock.withLock { _lastError = error }
                bridge.close()
            }
        }
    }
}

/// One forwarded connection: bytes from the local socket go into the SSH channel and back.
private final class Bridge: @unchecked Sendable {
    let nw: NWConnection
    let queue: DispatchQueue
    private let lock = NSLock()
    private var channel: Channel?
    private var closed = false
    var onClose: (@Sendable () -> Void)?

    init(nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
    }

    func attach(_ channel: Channel) {
        let alreadyClosed = lock.withLock { () -> Bool in
            self.channel = channel
            return closed
        }
        if alreadyClosed { channel.close(promise: nil); return }
        receive()
    }

    /// Local socket -> SSH channel, one chunk at a time (the next read waits for the write: back pressure).
    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let channel = self.lock.withLock({ self.channel }) else { return }
            if let data, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                channel.writeAndFlush(buffer).whenComplete { result in
                    switch result {
                    case .success:
                        if isComplete { channel.close(mode: .output, promise: nil) } else { self.receive() }
                    case .failure:
                        self.close()
                    }
                }
            } else if isComplete || error != nil {
                // The local side is done sending.
                channel.close(mode: .output, promise: nil)
                if error != nil { self.close() }
            } else {
                self.receive()
            }
        }
    }

    /// SSH channel -> local socket.
    func deliver(_ buffer: ByteBuffer) {
        nw.send(content: Data(buffer.readableBytesView), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    /// The remote side is done sending.
    func remoteFinished() {
        nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() {
        let (channel, handler): (Channel?, (@Sendable () -> Void)?) = lock.withLock {
            guard !closed else { return (nil, nil) }
            closed = true
            defer { onClose = nil }
            return (self.channel, onClose)
        }
        nw.cancel()
        channel?.close(promise: nil)
        handler?()
    }
}

/// Sits in the direct-tcpip channel (after Citadel's codec, so it sees `ByteBuffer`s).
private final class BridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let bridge: Bridge

    init(bridge: Bridge) { self.bridge = bridge }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        bridge.deliver(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { bridge.remoteFinished() }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        bridge.close()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        bridge.close()
        context.close(promise: nil)
    }
}

/// Runs a closure at most once (continuations must be resumed exactly once).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
