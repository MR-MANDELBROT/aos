#if DEBUG
import CoreGraphics
import Foundation
import Network

/// The demo's screen sharing server, in the app (debug builds only): plain RFB 3.8 on 127.0.0.1, no authentication,
/// one still picture in raw encoding, in the pixel format the client asks for (32 bits). The demo's Screen tab shows it
/// with the real screen client, without a Mac.
final class DemoScreenServer: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.marquart.aos.demo-screen")
    private let picture: Picture

    /// The picture as 8-bit RGBA rows.
    struct Picture: Sendable {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        let name: String

        init?(_ image: CGImage, name: String) {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.name = name
            rgba = bytes
        }
    }

    private init(listener: NWListener, port: UInt16, picture: Picture) {
        self.listener = listener
        self.port = port
        self.picture = picture
    }

    static func start(picture image: CGImage, name: String) async throws -> DemoScreenServer {
        guard let picture = Picture(image, name: name) else { throw CocoaError(.featureUnsupported) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.marquart.aos.demo-screen.listener")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if let port = listener.port?.rawValue { once.run { continuation.resume(returning: port) } }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = DemoScreenServer(listener: listener, port: port, picture: picture)
        listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        let client = Client(connection: connection, picture: picture)
        connection.start(queue: queue)
        client.begin()
    }

    /// One viewer: the handshake, then its messages; a full picture for every update request that isn't incremental
    /// (a still picture never changes, so incremental requests wait).
    private final class Client: @unchecked Sendable {
        private let connection: NWConnection
        private let picture: Picture
        private var buffer = Data()
        private var stage = Stage.version
        private var format = PixelFormat()
        private var sentFirst = false

        enum Stage { case version, security, clientInit, messages }

        /// The client's pixel format: 32 bits per pixel, true color (other depths get 32 bits anyway).
        struct PixelFormat {
            var bigEndian = false
            var redShift: UInt8 = 16, greenShift: UInt8 = 8, blueShift: UInt8 = 0
            var redMax: UInt16 = 255, greenMax: UInt16 = 255, blueMax: UInt16 = 255
        }

        init(connection: NWConnection, picture: Picture) {
            self.connection = connection
            self.picture = picture
        }

        func begin() {
            send(Data("RFB 003.008\n".utf8))
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
                if let data { buffer.append(data) }
                while step() {}
                if done || error != nil { connection.cancel() } else { receive() }
            }
        }

        private func send(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        /// Handles one complete step if the buffer has it.
        private func step() -> Bool {
            switch stage {
            case .version:
                guard buffer.count >= 12 else { return false }
                buffer.removeFirst(12)
                send(Data([1, 1]))  // one security type: None
                stage = .security
            case .security:
                guard buffer.count >= 1 else { return false }
                buffer.removeFirst(1)
                send(Data([0, 0, 0, 0]))  // SecurityResult OK
                stage = .clientInit
            case .clientInit:
                guard buffer.count >= 1 else { return false }
                buffer.removeFirst(1)
                var out = Data()
                out.append(u16: picture.width)
                out.append(u16: picture.height)
                out.append(contentsOf: [32, 24, 0, 1])  // BGRX little endian, true color
                out.append(u16: 255); out.append(u16: 255); out.append(u16: 255)
                out.append(contentsOf: [16, 8, 0, 0, 0, 0])
                let name = Data(picture.name.utf8)
                out.append(u32: name.count)
                out.append(name)
                send(out)
                stage = .messages
            case .messages:
                guard let type = buffer.first else { return false }
                switch type {
                case 0:  // SetPixelFormat
                    guard buffer.count >= 20 else { return false }
                    let f = [UInt8](buffer[buffer.startIndex + 4 ..< buffer.startIndex + 20])
                    format = PixelFormat(bigEndian: f[2] != 0, redShift: f[10], greenShift: f[11], blueShift: f[12],
                                         redMax: UInt16(f[4]) << 8 | UInt16(f[5]), greenMax: UInt16(f[6]) << 8 | UInt16(f[7]),
                                         blueMax: UInt16(f[8]) << 8 | UInt16(f[9]))
                    buffer.removeFirst(20)
                case 2:  // SetEncodings
                    guard buffer.count >= 4 else { return false }
                    let count = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                    guard buffer.count >= 4 + 4 * count else { return false }
                    buffer.removeFirst(4 + 4 * count)
                case 3:  // FramebufferUpdateRequest
                    guard buffer.count >= 10 else { return false }
                    let incremental = buffer[buffer.startIndex + 1] != 0
                    buffer.removeFirst(10)
                    if !incremental || !sentFirst { sendPicture() }
                case 4:  // KeyEvent
                    guard buffer.count >= 8 else { return false }
                    buffer.removeFirst(8)
                case 5:  // PointerEvent
                    guard buffer.count >= 6 else { return false }
                    buffer.removeFirst(6)
                case 6:  // ClientCutText
                    guard buffer.count >= 8 else { return false }
                    let b = [UInt8](buffer[buffer.startIndex + 4 ..< buffer.startIndex + 8])
                    let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                    guard buffer.count >= 8 + length else { return false }
                    buffer.removeFirst(8 + length)
                default:
                    // Not a message of plain RFB: the demo can't tell its length.
                    connection.cancel()
                    buffer.removeAll()
                    return false
                }
            }
            return true
        }

        private func sendPicture() {
            sentFirst = true
            var out = Data([0, 0])  // FramebufferUpdate
            out.append(u16: 1)
            out.append(u16: 0); out.append(u16: 0)
            out.append(u16: picture.width); out.append(u16: picture.height)
            out.append(u32: 0)  // raw
            var pixels = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
            let f = format
            for i in 0 ..< picture.width * picture.height {
                let r = UInt32(picture.rgba[i * 4]) * UInt32(f.redMax) / 255
                let g = UInt32(picture.rgba[i * 4 + 1]) * UInt32(f.greenMax) / 255
                let b = UInt32(picture.rgba[i * 4 + 2]) * UInt32(f.blueMax) / 255
                let value = r << f.redShift | g << f.greenShift | b << f.blueShift
                let bytes = f.bigEndian ? value.bigEndian : value.littleEndian
                withUnsafeBytes(of: bytes) { raw in
                    for k in 0 ..< 4 { pixels[i * 4 + k] = raw[k] }
                }
            }
            out.append(contentsOf: pixels)
            send(out)
        }
    }
}

private extension Data {
    mutating func append(u16 value: Int) {
        append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func append(u32 value: Int) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
#endif
