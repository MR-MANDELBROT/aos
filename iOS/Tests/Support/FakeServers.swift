import Foundation
import NIOCore
import NIOPosix
@testable import Annex

// MARK: - Screen sharing

/// A minimal RFB 3.8 server: no authentication, a fixed picture, records pointer and key events.
final class FakeRFBServer: @unchecked Sendable {
    let port: Int
    let width: Int
    let height: Int
    let log: EventLog
    private let channel: Channel

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var pointer: [(buttons: UInt8, x: Int, y: Int)] = []
        private var keys: [(down: Bool, keysym: UInt32)] = []
        private var updates = 0
        func addPointer(_ b: UInt8, _ x: Int, _ y: Int) { lock.withLock { pointer.append((b, x, y)) } }
        func addKey(_ down: Bool, _ k: UInt32) { lock.withLock { keys.append((down, k)) } }
        func addUpdate() { lock.withLock { updates += 1 } }
        var pointerEvents: [(buttons: UInt8, x: Int, y: Int)] { lock.withLock { pointer } }
        var keyEvents: [(down: Bool, keysym: UInt32)] { lock.withLock { keys } }
        var updateCount: Int { lock.withLock { updates } }
    }

    static func start(width: Int = 64, height: Int = 48) async throws -> FakeRFBServer {
        let log = EventLog()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(RFBSession(width: width, height: height, log: log)) }
            .bind(host: "127.0.0.1", port: 0).get()
        return FakeRFBServer(channel: channel, width: width, height: height, log: log)
    }

    private init(channel: Channel, width: Int, height: Int, log: EventLog) {
        self.channel = channel
        port = channel.localAddress?.port ?? 0
        self.width = width
        self.height = height
        self.log = log
    }

    func stop() async { try? await channel.close().get() }
}

private final class RFBSession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum Phase { case version, security, clientInit, messages }

    let width: Int, height: Int
    let log: FakeRFBServer.EventLog
    var phase = Phase.version
    var buffer = ByteBuffer()

    init(width: Int, height: Int, log: FakeRFBServer.EventLog) {
        self.width = width
        self.height = height
        self.log = log
    }

    func channelActive(context: ChannelHandlerContext) {
        send(context, Array("RFB 003.008\n".utf8))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while step(context) {}
    }

    private func send(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
    }

    /// Handles one complete message if there is one.
    private func step(_ context: ChannelHandlerContext) -> Bool {
        switch phase {
        case .version:
            guard buffer.readSlice(length: 12) != nil else { return false }
            send(context, [1, 1])  // one security type: None
            phase = .security
        case .security:
            guard buffer.readInteger(as: UInt8.self) != nil else { return false }
            send(context, [0, 0, 0, 0])  // SecurityResult OK
            phase = .clientInit
        case .clientInit:
            guard buffer.readInteger(as: UInt8.self) != nil else { return false }
            var out = ByteBuffer()
            out.writeInteger(UInt16(width))
            out.writeInteger(UInt16(height))
            out.writeBytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            let name = Array("Fake".utf8)
            out.writeInteger(UInt32(name.count))
            out.writeBytes(name)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
            phase = .messages
        case .messages:
            guard let type = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return false }
            switch type {
            case 0:  // SetPixelFormat
                guard buffer.readSlice(length: 20) != nil else { return false }
            case 2:  // SetEncodings
                guard let count = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt16.self),
                      buffer.readSlice(length: 4 + Int(count) * 4) != nil else { return false }
            case 3:  // FramebufferUpdateRequest
                guard buffer.readSlice(length: 10) != nil else { return false }
                sendFrame(context)
            case 4:  // KeyEvent
                guard let message = buffer.readSlice(length: 8) else { return false }
                log.addKey(message.getInteger(at: message.readerIndex + 1, as: UInt8.self) == 1,
                           message.getInteger(at: message.readerIndex + 4, as: UInt32.self) ?? 0)
            case 5:  // PointerEvent
                guard let message = buffer.readSlice(length: 6) else { return false }
                log.addPointer(message.getInteger(at: message.readerIndex + 1, as: UInt8.self) ?? 0,
                               Int(message.getInteger(at: message.readerIndex + 2, as: UInt16.self) ?? 0),
                               Int(message.getInteger(at: message.readerIndex + 4, as: UInt16.self) ?? 0))
            case 6:  // ClientCutText
                guard let length = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt32.self),
                      buffer.readSlice(length: 8 + Int(length)) != nil else { return false }
            default:
                context.close(promise: nil)
                return false
            }
        }
        return true
    }

    private func sendFrame(_ context: ChannelHandlerContext) {
        log.addUpdate()
        var out = ByteBuffer()
        out.writeBytes([0, 0])
        out.writeInteger(UInt16(1))
        out.writeInteger(UInt16(0)); out.writeInteger(UInt16(0))
        out.writeInteger(UInt16(width)); out.writeInteger(UInt16(height))
        out.writeInteger(Int32(0))  // raw
        // Mint-colored pixels in the client's RGBX format
        for _ in 0..<(width * height) { out.writeBytes([0x3D, 0xD9, 0xB4, 0]) }
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}

// MARK: - Pairing listener

/// The Mac's pairing listener: checks the proof with the code and answers like Annex on the Mac.
final class FakePairingListener: @unchecked Sendable {
    enum Behavior: Sendable { case accept(user: String, companion: String), refuse(String), hangUp }

    let port: Int
    private let channel: Channel
    private let received: Received

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PairingRequest] = []
        func add(_ r: PairingRequest) { lock.withLock { items.append(r) } }
        var all: [PairingRequest] { lock.withLock { items } }
    }

    static func start(code: Data, behavior: Behavior) async throws -> FakePairingListener {
        let received = Received()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(PairingSession(code: code, behavior: behavior, received: received)) }
            .bind(host: "127.0.0.1", port: 0).get()
        return FakePairingListener(channel: channel, received: received)
    }

    private init(channel: Channel, received: Received) {
        self.channel = channel
        port = channel.localAddress?.port ?? 0
        self.received = received
    }

    var requests: [PairingRequest] { received.all }

    func stop() async { try? await channel.close().get() }
}

private final class PairingSession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let code: Data
    let behavior: FakePairingListener.Behavior
    let received: FakePairingListener.Received
    var buffer = ByteBuffer()

    init(code: Data, behavior: FakePairingListener.Behavior, received: FakePairingListener.Received) {
        self.code = code
        self.behavior = behavior
        self.received = received
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard let newline = buffer.readableBytesView.firstIndex(of: 0x0A) else { return }
        let line = Data(buffer.readableBytesView[buffer.readableBytesView.startIndex..<newline])
        if case .hangUp = behavior {
            context.close(promise: nil)
            return
        }
        guard let request = try? JSONDecoder().decode(PairingRequest.self, from: line) else {
            reply(context, #"{"ok":false,"error":"bad request"}"#)
            return
        }
        received.add(request)
        // Constant-time comparison isn't needed in a test; the Mac must use one.
        let expected = PairingRequest.proof(code: code, key: request.key, device: request.device)
        let answer: String
        switch behavior {
        case .accept(let user, let companion) where expected == request.proof:
            answer = #"{"ok":true,"user":"\#(user)","companion":"\#(companion)"}"#
        case .accept:
            answer = #"{"ok":false,"error":"wrong proof"}"#
        case .refuse(let reason):
            answer = #"{"ok":false,"error":"\#(reason)"}"#
        case .hangUp:
            return
        }
        reply(context, answer)
    }

    private func reply(_ context: ChannelHandlerContext, _ text: String) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: text + "\n"))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
