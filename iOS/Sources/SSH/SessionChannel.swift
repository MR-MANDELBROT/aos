import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// An SSH session channel: a command (`exec`) or a login shell in a pseudo terminal. Bytes in both directions;
/// what the remote side writes arrives in `output`.
final class SessionChannel: @unchecked Sendable {
    enum Mode: Sendable {
        case exec(String)
        case shell(term: String, columns: Int, rows: Int)
    }

    enum Failure: LocalizedError {
        case refused(String)
        case exited(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .refused(let what): String(localized: "The Mac refused to start \(what).")
            case .exited(let status, let message):
                message.isEmpty ? String(localized: "The program ended (status \(status)).") : message
            }
        }
    }

    let channel: Channel
    /// Standard output (and for a shell, everything the terminal shows). Finishes when the channel closes.
    let output: AsyncThrowingStream<Data, Error>

    private init(channel: Channel, output: AsyncThrowingStream<Data, Error>) {
        self.channel = channel
        self.output = output
    }

    static func open(on connection: Channel, mode: Mode) async throws -> SessionChannel {
        let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let handler = SessionHandler(output: continuation, eventLoop: connection.eventLoop)
        let child: Channel = try await connection.eventLoop.flatSubmit {
            let promise = connection.eventLoop.makePromise(of: Channel.self)
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.pipeline.addHandler(handler)
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }.get()

        do {
            switch mode {
            case .exec(let command):
                try await handler.request({ SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true) },
                                          on: child, describing: command)
            case .shell(let term, let columns, let rows):
                try await handler.request({
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true, term: term, terminalCharacterWidth: columns, terminalRowHeight: rows,
                        terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
                }, on: child, describing: "terminal")
                try await handler.request({ SSHChannelRequestEvent.ShellRequest(wantReply: true) }, on: child,
                                          describing: "shell")
            }
        } catch {
            try? await child.close().get()
            throw error
        }
        return SessionChannel(channel: child, output: output)
    }

    /// Sends bytes to the remote program's standard input.
    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    /// Tells the pseudo terminal its new size.
    func resize(columns: Int, rows: Int) async throws {
        try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)).get()
    }

    /// Ends standard input (the remote program reads end of file).
    func closeInput() async {
        try? await channel.close(mode: .output).get()
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Turns SSH channel data into `Data` for the output stream and answers to channel requests into results.
private final class SessionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private let eventLoop: EventLoop
    /// Replies to requests with `wantReply`, in order.
    private var replies: [EventLoopPromise<Void>] = []
    private var exitStatus: Int?
    private var errorText = Data()

    init(output: AsyncThrowingStream<Data, Error>.Continuation, eventLoop: EventLoop) {
        self.output = output
        self.eventLoop = eventLoop
    }

    /// Sends a channel request with `wantReply` and waits for the server's yes or no.
    func request(_ makeEvent: @escaping @Sendable () -> Any, on channel: Channel, describing what: String) async throws {
        do {
            try await eventLoop.flatSubmit {
                let promise = self.eventLoop.makePromise(of: Void.self)
                self.replies.append(promise)
                let sent = self.eventLoop.makePromise(of: Void.self)
                sent.futureResult.whenFailure { error in promise.fail(error) }
                // On the event loop here, so the synchronous pipeline call is right (and takes non-Sendable events).
                channel.pipeline.syncOperations.triggerUserOutboundEvent(makeEvent(), promise: sent)
                // A server that never answers must not leave the app waiting.
                let timeout = self.eventLoop.scheduleTask(in: .seconds(15)) { promise.fail(ChannelFailureMarker()) }
                promise.futureResult.whenComplete { _ in timeout.cancel() }
                return promise.futureResult
            }.get()
        } catch is ChannelFailureMarker {
            throw SessionChannel.Failure.refused(what)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Keep reading after the remote side closes its output (exit status comes after that).
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            bound.value.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch message.type {
        case .channel:
            output.yield(bytes)
        case .stdErr:
            // Kept for an error message if the program fails; at most 4 KB.
            if errorText.count < 4096 { errorText.append(bytes.prefix(4096 - errorText.count)) }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !replies.isEmpty { replies.removeFirst().succeed(()) }
        case is ChannelFailureEvent:
            if !replies.isEmpty { replies.removeFirst().fail(ChannelFailureMarker()) }
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        case ChannelEvent.inputClosed:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        for reply in replies { reply.fail(ChannelError.ioOnClosedChannel) }
        replies.removeAll()
        if let status = exitStatus, status != 0 {
            let message = String(decoding: errorText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            output.finish(throwing: SessionChannel.Failure.exited(status: status, message: message))
        } else {
            output.finish()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        output.finish(throwing: error)
        context.close(promise: nil)
    }
}

private struct ChannelFailureMarker: Error {}
