import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

/// A VNC client for macOS screen sharing in the guest: Apple's RSA login, 32-bit RGBX pixels, raw and zlib
/// rectangles, pointer and key events. One connection is kept open: screensharingd drops input during the first
/// two seconds after a connection, so every reconnect costs that wait.
public actor RFBClient {
    public let host: String
    public let port: UInt16
    private let username: String
    private let password: String
    /// Encodings to ask for (zlib for screensharingd). Empty: raw only, nothing sent (the hypervisor's VNC server
    /// crashed the VM on encodings it doesn't know).
    private let encodings: [Int32]

    private var stream: RFBStream?
    private var connectedAt = Date.distantPast
    public private(set) var width = 0
    public private(set) var height = 0
    private var framebuffer = [UInt8]()
    private var zstream = z_stream()
    private var zstreamReady = false
    private var buttons: UInt8 = 0
    private var pointer = (x: 0, y: 0)
    /// Pressing input before this much time after connecting gets dropped by screensharingd.
    public static let inputGrace: TimeInterval =
        // screensharingd drops input until about 2 s after a viewer timestamp that comes later than our connect:
        // measured under macOS 27.2, 3 s too early, 4 s sometimes too early, 5 s reliable.
        Double(ProcessInfo.processInfo.environment["ANNEX_INPUT_GRACE"] ?? "") ?? 5.0

    public init(host: String, port: UInt16 = 5900, username: String, password: String, encodings: [Int32] = [6]) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encodings = encodings
    }

    deinit {
        if zstreamReady { inflateEnd(&zstream) }
    }

    public var isConnected: Bool { stream != nil }

    // MARK: Connection

    public func connect() async throws {
        if stream != nil { return }
        let s = RFBStream(host: host, port: port)
        do {
            // A connection that is still "waiting" keeps retrying on its own unless it is cancelled.
            try await s.open(timeout: 10)
            try await handshake(s)
            stream = s
            connectedAt = Date()
        } catch {
            s.close()
            throw error
        }
    }

    public func disconnect() {
        stream?.close()
        stream = nil
        if zstreamReady { inflateEnd(&zstream); zstreamReady = false }
        framebuffer = []
        buttons = 0
    }

    private func dbg(_ m: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["ANNEX_RFB_DEBUG"] != nil { FileHandle.standardError.write(Data(("rfb: " + m() + "\n").utf8)) }
    }

    private func handshake(_ s: RFBStream) async throws {
        let version = try await s.readLine()
        dbg("version \(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        guard version.starts(with: Data("RFB ".utf8)) else { throw RFBError.protocolError("not a VNC server") }
        try await s.write(Data("RFB 003.008\n".utf8))

        let count = Int(try await s.u8())
        if count == 0 {
            let len = Int(try await s.u32())
            let reason = String(decoding: try await s.read(min(len, 4096)), as: UTF8.self)
            throw RFBError.authFailed(reason)
        }
        let types = Set(try await s.read(count))
        dbg("types \(types.sorted())")
        if types.contains(33) {
            // appleRSA sends the type byte together with its first request
            try await RFBAuth.appleRSA(stream: s, username: username, password: password)
        } else if types.contains(2) {
            try await s.write(Data([2]))
            try await RFBAuth.vncPassword(stream: s, password: password)
        } else if types.contains(1) {
            try await s.write(Data([1]))
        } else {
            throw RFBError.protocolError("unsupported security types \(types.sorted())")
        }
        dbg("auth sent")
        let result = try await s.u32()
        dbg("result \(result)")
        if result != 0 {
            if result == 1 || result == 2 { throw RFBError.authFailed(result == 2 ? "too many attempts" : "rejected") }
            let reason = String(decoding: try await s.read(Int(min(result, 4096))), as: UTF8.self)
            throw RFBError.authFailed(reason)
        }

        try await s.write(Data([1]))  // ClientInit: shared
        width = Int(try await s.u16())
        height = Int(try await s.u16())
        _ = try await s.read(16)       // server pixel format
        let nameLength = Int(try await s.u32())
        _ = try await s.read(min(nameLength, 1 << 16))

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour, R at bit 0, G at 8, B at 16 -> RGBX bytes
        try await s.write(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 0, 8, 16, 0, 0, 0]))
        // SetEncodings (raw is always allowed)
        if !encodings.isEmpty {
            var enc = Data([2, 0])
            enc.appendBE(UInt16(encodings.count))
            for e in encodings { enc.appendBE(e) }
            try await s.write(enc)
        }

        framebuffer = [UInt8](repeating: 0, count: width * height * 4)
        zstream = z_stream()
        guard inflateInit_(&zstream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.protocolError("zlib")
        }
        zstreamReady = true
    }

    private func live() async throws -> RFBStream {
        if stream == nil { try await connect() }
        return stream!
    }

    /// Runs `body`; on a broken connection reconnects once and runs it again.
    private func withReconnect<T>(_ body: (RFBStream) async throws -> T) async throws -> T {
        do {
            return try await body(try await live())
        } catch let error as RFBError where error.isConnectionLoss {
            disconnect()
            return try await body(try await live())
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain || error.domain == "Network.NWError"
                    || error.domain == "NWErrorDomain" {
            disconnect()
            return try await body(try await live())
        }
    }

    // MARK: Screen

    /// A fresh picture of the whole screen.
    public func screenshot(timeout: TimeInterval = 15) async throws -> CGImage {
        try await withReconnect { s in
            var req = Data([3, 0])  // FramebufferUpdateRequest, not incremental
            req.appendBE(UInt16(0)); req.appendBE(UInt16(0))
            req.appendBE(UInt16(width)); req.appendBE(UInt16(height))
            try await s.write(req)
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if Date() > deadline { throw RFBError.timeout("screenshot") }
                let type = try await s.u8()
                switch type {
                case 0:
                    try await readUpdate(s)
                    return try makeImage()
                case 2:
                    continue  // bell
                case 3:
                    _ = try await s.read(3)
                    let len = Int(try await s.u32())
                    _ = try await s.read(len)
                case 1:
                    _ = try await s.read(3)
                    let n = Int(try await s.u16())
                    _ = try await s.read(n * 6)
                default:
                    throw RFBError.protocolError("unknown server message \(type)")
                }
            }
        }
    }

    private func readUpdate(_ s: RFBStream) async throws {
        _ = try await s.read(1)
        let rects = Int(try await s.u16())
        for _ in 0..<rects {
            let x = Int(try await s.u16()), y = Int(try await s.u16())
            let w = Int(try await s.u16()), h = Int(try await s.u16())
            let encoding = Int32(bitPattern: try await s.u32())
            switch encoding {
            case 0:
                let data = try await s.read(w * h * 4)
                blit(data, x: x, y: y, w: w, h: h)
            case 6:
                let len = Int(try await s.u32())
                let compressed = try await s.read(len)
                let data = try inflate(compressed, expected: w * h * 4)
                blit(data, x: x, y: y, w: w, h: h)
            case -223:  // DesktopSize
                width = w; height = h
                framebuffer = [UInt8](repeating: 0, count: w * h * 4)
            default:
                throw RFBError.protocolError("unexpected encoding \(encoding)")
            }
        }
    }

    private func inflate(_ input: Data, expected: Int) throws -> Data {
        var out = Data(count: expected)
        var status: Int32 = Z_OK
        input.withUnsafeBytes { (inp: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                zstream.next_in = UnsafeMutablePointer(mutating: inp.bindMemory(to: Bytef.self).baseAddress)
                zstream.avail_in = uInt(input.count)
                zstream.next_out = o.bindMemory(to: Bytef.self).baseAddress
                zstream.avail_out = uInt(expected)
                while zstream.avail_in > 0 || zstream.avail_out > 0 {
                    status = zlib.inflate(&zstream, Z_SYNC_FLUSH)
                    if status != Z_OK { break }
                    if zstream.avail_out == 0 { break }
                }
            }
        }
        guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else {
            throw RFBError.protocolError("zlib \(status)")
        }
        guard zstream.avail_out == 0 else { throw RFBError.protocolError("short zlib rectangle") }
        return out
    }

    private func blit(_ data: Data, x: Int, y: Int, w: Int, h: Int) {
        guard x + w <= width, y + h <= height else { return }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            framebuffer.withUnsafeMutableBytes { dst in
                for row in 0..<h {
                    let from = row * w * 4
                    let to = ((y + row) * width + x) * 4
                    dst.baseAddress!.advanced(by: to).copyMemory(from: src.baseAddress!.advanced(by: from),
                                                                  byteCount: w * 4)
                }
            }
        }
    }

    private func makeImage() throws -> CGImage {
        let data = Data(framebuffer) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw RFBError.protocolError("image")
        }
        return image
    }

    // MARK: Input

    private func waitForInputGrace() async {
        let wait = RFBClient.inputGrace - Date().timeIntervalSince(connectedAt)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    private func sendPointer(_ s: RFBStream, x: Int, y: Int, buttons: UInt8) async throws {
        let cx = max(0, min(x, width - 1)), cy = max(0, min(y, height - 1))
        var msg = Data([5, buttons])
        msg.appendBE(UInt16(cx)); msg.appendBE(UInt16(cy))
        try await s.write(msg)
        pointer = (cx, cy)
    }

    private func sendKey(_ s: RFBStream, _ keysym: UInt32, down: Bool) async throws {
        var msg = Data([4, down ? 1 : 0, 0, 0])
        msg.appendBE(keysym)
        try await s.write(msg)
    }

    public enum Button: Int, Sendable { case left = 0, middle = 1, right = 2 }

    /// Moves the pointer and clicks `count` times, with `modifiers` held.
    public func click(x: Int, y: Int, button: Button = .left, count: Int = 1, modifiers: [UInt32] = []) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            for m in modifiers { try await sendKey(s, m, down: true) }
            try await sendPointer(s, x: x, y: y, buttons: 0)
            try await Task.sleep(nanoseconds: 60_000_000)
            let bit: UInt8 = 1 << UInt8(button.rawValue)
            for i in 0..<max(1, min(count, 3)) {
                try await sendPointer(s, x: x, y: y, buttons: bit)
                try await Task.sleep(nanoseconds: 40_000_000)
                try await sendPointer(s, x: x, y: y, buttons: 0)
                if i < count - 1 { try await Task.sleep(nanoseconds: 80_000_000) }
            }
            for m in modifiers.reversed() { try await sendKey(s, m, down: false) }
        }
    }

    public func move(x: Int, y: Int) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            try await sendPointer(s, x: x, y: y, buttons: 0)
        }
    }

    /// Presses at one point, moves in steps, releases at the other.
    public func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            try await sendPointer(s, x: fromX, y: fromY, buttons: 0)
            try await Task.sleep(nanoseconds: 60_000_000)
            try await sendPointer(s, x: fromX, y: fromY, buttons: 1)
            try await Task.sleep(nanoseconds: 120_000_000)
            let steps = 12
            for i in 1...steps {
                let x = fromX + (toX - fromX) * i / steps, y = fromY + (toY - fromY) * i / steps
                try await sendPointer(s, x: x, y: y, buttons: 1)
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            try await sendPointer(s, x: toX, y: toY, buttons: 0)
        }
    }

    public enum ScrollDirection: String, Sendable { case up, down, left, right }

    /// Scroll wheel: buttons 4/5 (vertical) and 6/7 (horizontal), pressed and released per step.
    public func scroll(x: Int, y: Int, direction: ScrollDirection, steps: Int) async throws {
        let bit: UInt8
        switch direction {
        case .up: bit = 1 << 3
        case .down: bit = 1 << 4
        case .left: bit = 1 << 5
        case .right: bit = 1 << 6
        }
        try await withReconnect { s in
            await waitForInputGrace()
            try await sendPointer(s, x: x, y: y, buttons: 0)
            for _ in 0..<max(1, min(steps, 50)) {
                try await sendPointer(s, x: x, y: y, buttons: bit)
                try await sendPointer(s, x: x, y: y, buttons: 0)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// Presses a combination: all keys down in order, then up in reverse.
    public func press(_ keysyms: [UInt32]) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            for k in keysyms { try await sendKey(s, k, down: true); try await Task.sleep(nanoseconds: 20_000_000) }
            for k in keysyms.reversed() { try await sendKey(s, k, down: false); try await Task.sleep(nanoseconds: 15_000_000) }
        }
    }

    /// Types characters that have a key symbol (see `Keysyms.forText`).
    public func type(_ keysyms: [UInt32]) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            for k in keysyms {
                let shift = Keysyms.needsShift(k)
                if shift { try await sendKey(s, Keysyms.shift, down: true) }
                try await sendKey(s, k, down: true)
                try await sendKey(s, k, down: false)
                if shift { try await sendKey(s, Keysyms.shift, down: false) }
                try await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }
}

extension RFBError {
    var isConnectionLoss: Bool {
        if case .closed = self { return true }
        return false
    }
}

/// Image encoding for tool results.
public enum ScreenImage {
    public static func encode(_ image: CGImage, type: UTType = .jpeg, quality: Double = 0.8) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw RFBError.protocolError("encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RFBError.protocolError("encoder") }
        return data as Data
    }

    /// The part of `image` inside `rect` (pixels), clamped to the image.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return image.cropping(to: rect.integral.intersection(bounds))
    }
}
