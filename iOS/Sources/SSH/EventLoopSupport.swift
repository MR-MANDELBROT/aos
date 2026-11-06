import Foundation
import NIOCore

/// Runs Swift tasks on a NIO event loop. Citadel's `SSHClient.connect(on:settings:)` sets up the channel pipeline
/// with synchronous pipeline operations, which must happen on the channel's event loop; with this executor as the
/// task's preference, its code runs there.
final class EventLoopTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let eventLoop: EventLoop

    init(_ eventLoop: EventLoop) { self.eventLoop = eventLoop }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        eventLoop.execute { job.runSynchronously(on: executor) }
    }
}

/// Holds the bytes that arrive before the SSH handler is in the pipeline (the server's version line comes right after
/// the TCP connection opens, and the SSH handler is added only afterwards). It lets them through as soon as the SSH
/// handler writes its own version line; from then on it only passes bytes along.
final class HoldUntilSSHStarts: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var held: [ByteBuffer] = []
    private var releasing = false
    private var released = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if released {
            context.fireChannelRead(data)
        } else {
            held.append(unwrapInboundIn(data))
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if released { context.fireChannelReadComplete() }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
        guard !released, !releasing else { return }
        releasing = true
        // After the current call returns: the SSH handler is busy writing right now.
        context.eventLoop.execute {
            self.released = true
            let held = self.held
            self.held.removeAll()
            for buffer in held { context.fireChannelRead(self.wrapInboundOut(buffer)) }
            if !held.isEmpty { context.fireChannelReadComplete() }
        }
    }
}
