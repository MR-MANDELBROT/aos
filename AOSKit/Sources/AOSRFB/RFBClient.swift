import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a connection asks the server for: pixel format and encodings.
public struct RFBOptions: Equatable, Sendable {
    /// Picture encodings in order of preference; raw always works.
    public var encodings: [Int32]
    public var format: RFBPixelFormat
    /// The client draws the pointer: the server sends its shape and moves (and leaves it out of the picture).
    public var localCursor: Bool
    /// Send `encodings` exactly as given, no pseudo-encodings (the hypervisor's own VNC server crashed the VM on
    /// encodings it doesn't know).
    public var exact: Bool

    public init(encodings: [Int32], format: RFBPixelFormat = .rgb888, localCursor: Bool = false, exact: Bool = false) {
        self.encodings = encodings
        self.format = format
        self.localCursor = localCursor
        self.exact = exact
    }

    /// The agent's tools: lossless pictures with the pointer in them, sizes that follow the screen.
    public static let agent = RFBOptions(encodings: [RFBEncoding.zrle, RFBEncoding.zlib, RFBEncoding.copyRect])

    /// A live viewer on the iPhone. `localCursor`: the phone draws the pointer (it moves without delay, but the
    /// agent's moves don't show: screensharingd sends no pointer positions, measured macOS 27.2).
    public static func viewer(_ quality: RFBQuality, localCursor: Bool = true) -> RFBOptions {
        RFBOptions(encodings: quality.encodings, format: quality.format, localCursor: localCursor)
    }

    /// What SetEncodings says.
    var wireEncodings: [Int32] {
        if exact { return encodings }
        var list = encodings
        list += [RFBEncoding.desktopSize, RFBEncoding.extendedDesktopSize, RFBEncoding.lastRect]
        if localCursor { list += [RFBEncoding.richCursor, RFBEncoding.pointerPosition] }
        return list
    }
}

/// Picture quality of a live view. Sizes of one full 1280x800 picture of the workspace's photo desktop, measured
/// against screensharingd (macOS 27.2): best 1.7 MB, balanced 0.68 MB, saver 0.45 MB, gray 0.15 MB (raw: 4.1 MB).
public enum RFBQuality: String, CaseIterable, Identifiable, Sendable {
    /// All colours, lossless (ZRLE, 24 bits).
    case best
    /// Thousands of colours (Apple's 15-bit encoding; ZRLE with 16 bits where the server prefers it).
    case balanced
    /// 4096 colours (ZRLE, 12 bits): slight banding, for mobile connections.
    case saver
    /// 16 shades of gray (Apple's 4-bit encoding): for very slow connections; text stays sharp.
    case gray

    public var id: String { rawValue }

    public var format: RFBPixelFormat {
        switch self {
        case .best: .rgb888
        case .balanced: .rgb565
        case .saver, .gray: .rgb444
        }
    }

    public var encodings: [Int32] {
        let standard = [RFBEncoding.zrle, RFBEncoding.zlib, RFBEncoding.copyRect]
        switch self {
        case .best, .saver: return standard
        case .balanced: return [RFBEncoding.appleThousands] + standard
        case .gray: return [RFBEncoding.appleGray] + standard
        }
    }
}

/// What a live connection reports.
public enum RFBEvent: Sendable, Equatable {
    /// The framebuffer changed: `RFBFramebuffer.takeChanges` has what. Sent again only after a reader took them.
    case frame
    /// The screen has a new size (the framebuffer was cleared).
    case resized(width: Int, height: Int)
    /// The pointer's shape (empty: hidden).
    case cursor(RFBCursor)
    /// The server moved the pointer (the agent, or someone at the Mac).
    case pointer(x: Int, y: Int)
    /// Text the remote clipboard got (ServerCutText, Latin-1 by the standard).
    case clipboard(String)
    case bell
}

/// Counters of one connection, for measurements and the viewer's statistics.
public struct RFBStats: Sendable, Equatable {
    public var bytes = 0
    public var updates = 0
    public var rects: [Int32: Int] = [:]
    public var rectBytes: [Int32: Int] = [:]
    /// Round trip of the last request the server had to answer at once (a full picture or the keep-alive).
    public var lastLatency: TimeInterval = 0

    public var summary: String {
        let parts = rects.keys.sorted().map { e in "\(RFBEncoding.name(e)) \(rects[e]!)x/\(rectBytes[e] ?? 0)B" }
        return "\(updates) updates, \(bytes) bytes; " + parts.joined(separator: ", ")
    }
}

/// A VNC client for macOS screen sharing: Apple's RSA login, ZRLE, zlib, CopyRect and raw pictures, the pointer's
/// shape, screens that change size, pointer and key events. One connection is kept open: screensharingd drops input
/// during the first seconds after a connection, so every reconnect costs that wait.
public actor RFBClient {
    public nonisolated let host: String
    public nonisolated let port: UInt16
    private let username: String
    private let password: String
    public nonisolated let options: RFBOptions
    /// The screen; readers on any thread may look at it (see `RFBFramebuffer`).
    public nonisolated let framebuffer = RFBFramebuffer()

    private var stream: RFBStream?
    private var connectedAt = Date.distantPast
    public private(set) var width = 0
    public private(set) var height = 0
    /// The desktop's name (ServerInit).
    public private(set) var serverName = ""
    /// The pixel format the server would use by itself.
    public private(set) var serverFormat = RFBPixelFormat.rgb888
    private var decoder = RFBDecoder(format: .rgb888)
    private var buttons: UInt8 = 0
    private var pointer = (x: 0, y: 0)
    private var counters = RFBStats()
    private var reading = false
    /// Pressing input before this much time after connecting gets dropped by screensharingd.
    public static let inputGrace: TimeInterval =
        // screensharingd drops input until about 2 s after a viewer timestamp that comes later than our connect:
        // measured under macOS 27.2, 3 s too early, 4 s sometimes too early, 5 s reliable.
        Double(ProcessInfo.processInfo.environment["AOS_INPUT_GRACE"] ?? "") ?? 5.0

    public init(host: String, port: UInt16 = 5900, username: String, password: String, options: RFBOptions = .agent) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.options = options
    }

    /// `encodings` sent exactly as given (empty: raw only, nothing sent).
    public init(host: String, port: UInt16 = 5900, username: String, password: String, encodings: [Int32]) {
        self.init(host: host, port: port, username: username, password: password,
                  options: RFBOptions(encodings: encodings, exact: true))
    }

    public var isConnected: Bool { stream != nil }

    public var stats: RFBStats {
        var s = counters
        s.bytes = stream?.bytesReceived ?? counters.bytes
        return s
    }

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
        if let stream { counters.bytes = stream.bytesReceived }
        stream?.close()
        stream = nil
        buttons = 0
    }

    private func dbg(_ m: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["AOS_RFB_DEBUG"] != nil { FileHandle.standardError.write(Data(("rfb: " + m() + "\n").utf8)) }
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
        serverFormat = RFBPixelFormat(wire: try await s.read(16))
        let nameLength = Int(try await s.u32())
        serverName = String(decoding: try await s.read(min(nameLength, 1 << 16)), as: UTF8.self)
        dbg("server \(width)x\(height) \(serverFormat.bitsPerPixel) bpp \"\(serverName)\"")

        try await s.write(options.format.message)
        decoder = RFBDecoder(format: options.format)
        let encodings = options.wireEncodings
        if !encodings.isEmpty {
            var enc = Data([2, 0])
            enc.appendBE(UInt16(encodings.count))
            for e in encodings { enc.appendBE(e) }
            try await s.write(enc)
        }
        framebuffer.resize(width: width, height: height)
        counters = RFBStats()
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

    private func request(_ s: RFBStream, incremental: Bool, _ rect: RFBRect? = nil) async throws {
        let r = rect ?? RFBRect(x: 0, y: 0, width: width, height: height)
        var req = Data([3, incremental ? 1 : 0])  // FramebufferUpdateRequest
        req.appendBE(UInt16(r.x)); req.appendBE(UInt16(r.y))
        req.appendBE(UInt16(max(1, r.width))); req.appendBE(UInt16(max(1, r.height)))
        try await s.write(req)
    }

    /// A fresh picture of the whole screen.
    public func screenshot(timeout: TimeInterval = 15) async throws -> CGImage {
        // A live viewer reads the stream already: its last picture is current.
        if liveActive, let image = framebuffer.makeImage() { return image }
        guard !reading else { throw RFBError.protocolError("the screen is being read already") }
        reading = true
        defer { reading = false }
        return try await withReconnect { s in
            try await request(s, incremental: false)
            let deadline = Date().addingTimeInterval(timeout)
            var resized = false
            while true {
                if Date() > deadline { throw RFBError.timeout("screenshot") }
                let type = try await s.u8()
                if type == 0 {
                    let result = try await readUpdate(s)
                    framebuffer.commit()
                    // After a new size the picture comes with the next update: ask once more for all of it.
                    if result.resized && !resized {
                        resized = true
                        try await request(s, incremental: false)
                        continue
                    }
                    guard let image = framebuffer.makeImage() else { throw RFBError.protocolError("image") }
                    return image
                }
                _ = try await readOtherMessage(type, s)
            }
        }
    }

    struct UpdateResult {
        var resized = false
        var cursor: RFBCursor?
        var pointer: (x: Int, y: Int)?
    }

    private func readUpdate(_ s: RFBStream) async throws -> UpdateResult {
        _ = try await s.read(1)
        let count = Int(try await s.u16())
        var result = UpdateResult()
        counters.updates += 1
        var index = 0
        // 0xFFFF with LastRect: as many rectangles as come until LastRect.
        while index < count || count == 0xFFFF {
            index += 1
            let header = [UInt8](try await s.read(12))
            let rect = RFBRect(x: Int(header[0]) << 8 | Int(header[1]), y: Int(header[2]) << 8 | Int(header[3]),
                               width: Int(header[4]) << 8 | Int(header[5]), height: Int(header[6]) << 8 | Int(header[7]))
            let encoding = Int32(bitPattern: UInt32(header[8]) << 24 | UInt32(header[9]) << 16 | UInt32(header[10]) << 8 | UInt32(header[11]))
            var size = 0
            switch encoding {
            case RFBEncoding.raw:
                size = decoder.rawSize(rect)
                decoder.raw(try await s.read(size), rect: rect, into: framebuffer)
            case RFBEncoding.copyRect:
                let src = [UInt8](try await s.read(4))
                size = 4
                framebuffer.copy(from: Int(src[0]) << 8 | Int(src[1]), Int(src[2]) << 8 | Int(src[3]), to: rect)
            case RFBEncoding.zlib:
                size = Int(try await s.u32())
                try decoder.zlib(try await s.read(size), rect: rect, into: framebuffer)
                size += 4
            case RFBEncoding.zrle:
                size = Int(try await s.u32())
                try decoder.zrle(try await s.read(size), rect: rect, into: framebuffer)
                size += 4
            case RFBEncoding.appleHalftone, RFBEncoding.appleGray, RFBEncoding.appleThousands:
                size = Int(try await s.u32())
                try decoder.apple(encoding, try await s.read(size), rect: rect, into: framebuffer)
                size += 4
            case RFBEncoding.desktopSize:
                resize(rect.width, rect.height, &result)
            case RFBEncoding.extendedDesktopSize:
                let n = Int(try await s.u8())
                _ = try await s.read(3 + 16 * n)
                size = 4 + 16 * n
                // y is the status: 0 means the size is in effect.
                if rect.y == 0 { resize(rect.width, rect.height, &result) }
            case RFBEncoding.lastRect:
                counters.rects[encoding, default: 0] += 1
                return result
            case RFBEncoding.richCursor:
                size = decoder.cursorSize(rect)
                result.cursor = decoder.cursor(try await s.read(size), rect: rect)
            case RFBEncoding.pointerPosition:
                result.pointer = (rect.x, rect.y)
                pointer = (rect.x, rect.y)
            default:
                throw RFBError.protocolError("unexpected encoding \(encoding)")
            }
            counters.rects[encoding, default: 0] += 1
            counters.rectBytes[encoding, default: 0] += size + 12
        }
        return result
    }

    private func resize(_ w: Int, _ h: Int, _ result: inout UpdateResult) {
        guard w > 0, h > 0, w != width || h != height else { return }
        dbg("new size \(w)x\(h)")
        width = w
        height = h
        framebuffer.resize(width: w, height: h)
        result.resized = true
    }

    /// Everything but a framebuffer update. Returns an event for a live viewer, if there is one.
    private func readOtherMessage(_ type: UInt8, _ s: RFBStream) async throws -> RFBEvent? {
        switch type {
        case 1:  // colour map entries (not used with true colour)
            _ = try await s.read(3)
            _ = try await s.read(Int(try await s.u16()) * 6)
            return nil
        case 2:
            return .bell
        case 3:  // server cut text
            _ = try await s.read(3)
            let length = Int(try await s.u32())
            let text = try await s.read(min(length, 1 << 24))
            if length > 1 << 24 { _ = try await s.read(length - (1 << 24)) }
            return .clipboard(String(decoding: text.map { UInt16($0) }, as: UTF16.self))
        default:
            throw RFBError.protocolError("unknown server message \(type)")
        }
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

    /// Low-level pointer event for live viewers (touch and trackpad): position and the buttons held now.
    public func pointer(x: Int, y: Int, pressed: Set<Button> = []) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            let mask = pressed.reduce(UInt8(0)) { $0 | (1 << UInt8($1.rawValue)) }
            try await sendPointer(s, x: x, y: y, buttons: mask)
        }
    }

    /// Low-level key event for live viewers (a hardware keyboard: down and up come separately).
    public func key(_ keysym: UInt32, down: Bool) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            try await sendKey(s, keysym, down: down)
        }
    }

    /// Wheel steps at a point with the buttons held: buttons 4/5 (vertical) and 6/7 (horizontal), each step a
    /// press and a release. Positive `dy` scrolls the content up (wheel down), positive `dx` to the left.
    public func wheel(x: Int, y: Int, dx: Int, dy: Int, pressed: Set<Button> = []) async throws {
        try await withReconnect { s in
            await waitForInputGrace()
            let held = pressed.reduce(UInt8(0)) { $0 | (1 << UInt8($1.rawValue)) }
            for (steps, bit) in [(dy, dy > 0 ? UInt8(1 << 4) : UInt8(1 << 3)), (dx, dx > 0 ? UInt8(1 << 6) : UInt8(1 << 5))] {
                for _ in 0..<min(abs(steps), 50) {
                    try await sendPointer(s, x: x, y: y, buttons: held | bit)
                    try await sendPointer(s, x: x, y: y, buttons: held)
                }
            }
        }
    }

    /// ClientCutText: puts text on the remote clipboard (Latin-1 only, by the standard).
    public func sendClipboard(_ text: String) async throws {
        let latin = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        try await withReconnect { s in
            var msg = Data([6, 0, 0, 0])
            msg.appendBE(UInt32(latin.count))
            msg.append(contentsOf: latin)
            try await s.write(msg)
        }
    }

    // MARK: Live

    private var liveActive = false
    private var liveInterval: TimeInterval = 0.05
    private var wantsFullUpdate = false

    /// The live view's pace: at most one update request per `interval`.
    public func setMinimumInterval(_ interval: TimeInterval) {
        liveInterval = max(0, interval)
    }

    /// The next update brings the whole screen (after the viewer was away, for example).
    public func refreshAll() { wantsFullUpdate = true }

    /// A live view: keeps asking for updates (at most every `minimumInterval`) and reports what happened; the
    /// picture itself is in `framebuffer`. Input methods keep working meanwhile; `screenshot` returns the current
    /// picture. Ending the stream (or cancelling its task) closes the connection.
    public nonisolated func events(minimumInterval: TimeInterval = 0.033) -> AsyncThrowingStream<RFBEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await self.runLive(minimumInterval, continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.disconnect() }  // a pending read only ends when the connection closes
            }
        }
    }

    /// Whole pictures for simple viewers and tests: one after each update, at most every `minimumInterval`.
    public nonisolated func liveFrames(minimumInterval: TimeInterval = 0.05) -> AsyncThrowingStream<CGImage, Error> {
        let events = self.events(minimumInterval: minimumInterval)
        let framebuffer = self.framebuffer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events where event == .frame {
                        framebuffer.takeChanges { _ in }
                        if let image = framebuffer.makeImage() { continuation.yield(image) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var outstanding = 0
    private var lastHeard = Date.distantPast
    private var probeSentAt: Date?

    /// A non-incremental request for one pixel: the server must answer it, so it shows that the connection lives
    /// (a quiet screen sends nothing, and the stream's watchdog would end it) and measures the round trip.
    private func keepAlive(_ s: RFBStream) async {
        guard liveActive, Date().timeIntervalSince(lastHeard) > 8 else { return }
        lastHeard = Date()
        probeSentAt = Date()
        outstanding += 1
        try? await request(s, incremental: false, RFBRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func runLive(_ interval: TimeInterval, _ out: AsyncThrowingStream<RFBEvent, Error>.Continuation) async {
        guard !liveActive, !reading else { out.finish(throwing: RFBError.protocolError("a live view is running already")); return }
        liveActive = true
        reading = true
        liveInterval = interval
        var keeper: Task<Void, Never>?
        defer { liveActive = false; reading = false; keeper?.cancel() }
        do {
            let s = try await live()
            // Requests not answered yet. One more goes out as soon as an update starts to arrive (when the pace
            // allows), so the server prepares the next picture while this one travels.
            outstanding = 0
            lastHeard = Date()
            var lastRequest = Date.distantPast
            var full = true
            keeper = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await self?.keepAlive(s)
                }
            }
            while !Task.isCancelled {
                if outstanding == 0 {
                    let wait = liveInterval - Date().timeIntervalSince(lastRequest)
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    full = full || wantsFullUpdate
                    wantsFullUpdate = false
                    if full { probeSentAt = Date() }
                    try await request(s, incremental: !full)
                    full = false
                    lastRequest = Date()
                    outstanding += 1
                }
                let type = try await s.u8()
                lastHeard = Date()
                guard type == 0 else {
                    if let event = try await readOtherMessage(type, s) { out.yield(event) }
                    continue
                }
                outstanding = max(0, outstanding - 1)
                if let sent = probeSentAt {
                    counters.lastLatency = Date().timeIntervalSince(sent)
                    probeSentAt = nil
                }
                if outstanding == 0, !wantsFullUpdate, Date().timeIntervalSince(lastRequest) >= liveInterval {
                    try await request(s, incremental: true)
                    lastRequest = Date()
                    outstanding += 1
                }
                let result = try await readUpdate(s)
                lastHeard = Date()
                if result.resized {
                    out.yield(.resized(width: width, height: height))
                    // The new picture: all of it, right away.
                    try await request(s, incremental: false)
                    lastRequest = Date()
                    outstanding += 1
                }
                if let cursor = result.cursor { out.yield(.cursor(cursor)) }
                if let p = result.pointer { out.yield(.pointer(x: p.x, y: p.y)) }
                if framebuffer.commit() { out.yield(.frame) }
            }
            out.finish()
        } catch is CancellationError {
            out.finish()
        } catch {
            out.finish(throwing: error)
        }
    }

    // MARK: The agent's input

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

    /// `image` scaled by `factor` (smaller than 1 shrinks), with good filtering.
    public static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        guard factor > 0, factor != 1 else { return image }
        let w = max(1, Int((Double(image.width) * factor).rounded())), h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
