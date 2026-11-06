import CryptoKit
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
@testable import Annex

// Servers for the network tests, all on 127.0.0.1 inside the test process. Nothing here touches the Mac's own sshd.

/// A port that was free a moment ago.
func freeLocalPort() async throws -> Int {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "127.0.0.1", port: 0).get()
    let port = channel.localAddress?.port ?? 0
    try await channel.close().get()
    return port
}

/// An SSH server on SwiftNIO SSH with what the Mac offers the app: `"<companion>" serve` in an exec channel (the mock
/// companion on stdin and stdout), a login shell in a pseudo terminal (an echo, recording its size), and direct-tcpip.
final class TestSSHServer: @unchecked Sendable {
    let port: Int
    let hostKeyLine: String
    let hostKeyFingerprint: String
    let companion: MockCompanionServer
    let log = ServerLog()
    private let channel: Channel

    static let companionPath = "/Applications/Annex.app/Contents/MacOS/annex-companion"

    static func start(username: String = "max", allowedKey: DeviceKey?, password: String? = nil,
                      companion: MockCompanionServer = MockCompanionServer(keepsSecrets: true)) async throws -> TestSSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let allowed = try allowedKey.map { try NIOSSHPublicKey(openSSHPublicKey: $0.publicKey) }
        let auth = ServerAuth(username: username, key: allowed, password: password)
        let log = ServerLog()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                // Initializers run on the channel's event loop: synchronous pipeline operations are right there.
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            switch type {
                            case .session:
                                return child.eventLoop.makeCompletedFuture {
                                    try child.pipeline.syncOperations.addHandler(SessionServer(companion: companion, log: log))
                                }
                            case .directTCPIP(let target):
                                log.add("direct-tcpip \(target.targetHost):\(target.targetPort)")
                                let (local, remote) = Glue.pair()
                                return ClientBootstrap(group: child.eventLoop)
                                    .channelInitializer { remoteChannel in
                                        remoteChannel.eventLoop.makeCompletedFuture {
                                            try remoteChannel.pipeline.syncOperations.addHandler(remote)
                                        }
                                    }
                                    .connect(host: target.targetHost, port: target.targetPort)
                                    .flatMapThrowing { _ in
                                        try child.pipeline.syncOperations.addHandlers([ChannelDataCodec(), local])
                                    }
                            default:
                                return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
                            }
                        }))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return TestSSHServer(channel: channel, hostKey: hostKey, companion: companion, log: log)
    }

    private init(channel: Channel, hostKey: NIOSSHPrivateKey, companion: MockCompanionServer, log: ServerLog) {
        self.channel = channel
        port = channel.localAddress?.port ?? 0
        hostKeyLine = String(openSSHPublicKey: hostKey.publicKey)
        hostKeyFingerprint = SSHKeyFormat.fingerprint(openSSHKey: hostKeyLine)!
        self.companion = companion
        self.serverLog = log
    }

    private let serverLog: ServerLog
    var events: [String] { serverLog.all }

    func stop() async {
        try? await channel.close().get()
    }
}

final class ServerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

private final class ServerAuth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPublicKey?
    let password: String?

    init(username: String, key: NIOSSHPublicKey?, password: String?) {
        self.username = username
        self.key = key
        self.password = password
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        password == nil ? [.publicKey] : [.publicKey, .password]
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == username else { return responsePromise.succeed(.failure) }
        switch request.request {
        case .publicKey(let offer):
            responsePromise.succeed(key != nil && offer.publicKey == key ? .success : .failure)
        case .password(let offer):
            responsePromise.succeed(password != nil && offer.password == password ? .success : .failure)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// A session channel on the server: exec of the companion, or a pseudo terminal with an echoing "shell".
private final class SessionServer: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    let companion: MockCompanionServer
    let log: ServerLog
    private var feeder: MockCompanionServer.Feeder?
    private var shell = false
    private var hasPTY = false

    init(companion: MockCompanionServer, log: ServerLog) {
        self.companion = companion
        self.log = log
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let channel = context.channel
        switch event {
        case let exec as SSHChannelRequestEvent.ExecRequest:
            log.add("exec \(exec.command)")
            if exec.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            guard exec.command == CompanionCommand.serve(path: TestSSHServer.companionPath) else {
                // Like a login shell that doesn't find the program
                write(channel, Data("zsh:1: no such file or directory: \(exec.command)\n".utf8), type: .stdErr)
                exit(channel, status: 127)
                return
            }
            let loop = channel.eventLoop
            let server = self
            feeder = companion.attach(write: { data in
                loop.execute { server.write(channel, data, type: .channel) }
            }, hangUp: {
                loop.execute { server.exit(channel, status: 0) }
            })
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            hasPTY = true
            log.add("pty \(pty.term) \(pty.terminalCharacterWidth)x\(pty.terminalRowHeight)")
            if pty.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let request as SSHChannelRequestEvent.ShellRequest:
            shell = hasPTY
            log.add("shell")
            if request.wantReply {
                if hasPTY {
                    channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                } else {
                    channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
            }
            if hasPTY { write(channel, Data("Welcome to the test shell\r\n$ ".utf8), type: .channel) }
        case let size as SSHChannelRequestEvent.WindowChangeRequest:
            log.add("size \(size.terminalCharacterWidth)x\(size.terminalRowHeight)")
        case ChannelEvent.inputClosed:
            if shell { exit(channel, status: 0) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, message.type == .channel else { return }
        let bytes = Data(buffer.readableBytesView)
        if shell {
            // Echo, with "exit\r" ending the shell
            write(context.channel, bytes, type: .channel)
            if String(decoding: bytes, as: UTF8.self).contains("exit\r") { exit(context.channel, status: 0) }
        } else {
            feeder?.feed(bytes)
        }
    }

    private func write(_ channel: Channel, _ data: Data, type: SSHChannelData.DataType) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: type, data: .byteBuffer(buffer)), promise: nil)
    }

    private func exit(_ channel: Channel, status: Int) {
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

/// SSH channel data <-> plain bytes, for the forwarded TCP connections.
private final class ChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, message.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))),
                      promise: promise)
    }
}

/// Forwards bytes between two channels (both carrying `ByteBuffer`s).
final class Glue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: Glue?
    private var context: ChannelHandlerContext?

    static func pair() -> (Glue, Glue) {
        let a = Glue(), b = Glue()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    private func write(_ buffer: ByteBuffer) {
        guard let context else { return }
        if context.eventLoop.inEventLoop {
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        } else {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.execute { bound.value.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil) }
        }
    }

    private func closeFromPartner() {
        guard let context else { return }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.eventLoop.execute { bound.value.close(promise: nil) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.write(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.closeFromPartner()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

