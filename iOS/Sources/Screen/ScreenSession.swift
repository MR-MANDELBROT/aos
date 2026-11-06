import AOSRFB
import CoreGraphics
import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "screen")

/// How a screen connects: picture quality, pace, pointer, and (workspace) the display in the phone's shape.
struct ScreenOptions: Equatable, Sendable {
    var quality: RFBQuality = .best
    var interval: TimeInterval = 1.0 / 60
    var localCursor = true
    /// The workspace takes the phone's shape while the phone shows it.
    var matchShape = true
    var retina = true

    @MainActor
    init(settings: AppSettings, cellular: Bool) {
        quality = settings.screenQuality.resolved(cellular: cellular)
        interval = settings.frameRate.interval
        localCursor = settings.pointerStyle == .local
        matchShape = settings.matchWorkspaceShape
        retina = settings.retinaWorkspace
    }

    init() {}
}

/// Picture rate, data rate and round trip of a live screen, once a second.
struct ScreenStats: Equatable, Sendable {
    var framesPerSecond: Double = 0
    var kilobytesPerSecond: Double = 0
    var roundTrip: TimeInterval = 0
    var size: CGSize = .zero
    var quality: RFBQuality = .best
}

/// A live screen: the Mac's own or the workspace's, through the SSH connection (direct-tcpip to its screen sharing
/// port, bridged to a loopback listener for `RFBClient`). The picture itself goes straight from the client's
/// framebuffer to the view (`onFrame`), not through SwiftUI.
@MainActor @Observable
final class ScreenSession {
    enum Phase: Equatable {
        case idle
        /// The Mac's own screen needs the Mac account (name and password) once.
        case needsLogin
        case connecting
        case live
        case failed(String)
    }

    let target: ScreenTarget
    private(set) var phase: Phase = .idle
    /// Screen size in pixels (zero until the first picture).
    private(set) var size: CGSize = .zero
    /// Where the remote pointer is (pixels).
    private(set) var pointer: CGPoint = .zero
    /// The pointer's shape from the server (when the phone draws it).
    private(set) var cursor: RFBCursor?
    /// Screen sharing ignores input for a few seconds after connecting; until then input waits.
    private(set) var inputReady = false
    /// A short message for the person (a character that can't be typed, for example).
    var notice: String?
    /// Modifier keys from the key bar that apply to the next key or click.
    private(set) var stickyModifiers: [UInt32] = []
    /// Modifier keys locked on (double tap in the key bar) until tapped again.
    private(set) var lockedModifiers: [UInt32] = []
    private(set) var stats = ScreenStats()
    /// What the workspace's display was asked for (nil: its own size).
    private(set) var displayRequest: DisplayRequest?
    /// The connection the picture comes through now.
    private(set) var options = ScreenOptions()
    /// The left button is held (a drag).
    private(set) var dragging = false

    /// The framebuffer the view draws from (nil before connecting and in the demo).
    @ObservationIgnored private(set) var framebuffer: RFBFramebuffer?
    /// The view redraws: a new picture is in the framebuffer.
    @ObservationIgnored var onFrame: (() -> Void)?
    /// The demo's still picture.
    @ObservationIgnored private(set) var stillImage: CGImage?
    /// The viewer's size in points without the safe area, for a workspace in the phone's shape.
    @ObservationIgnored var viewerArea: CGSize = .zero {
        didSet { if viewerArea != oldValue { scheduleDisplayMatch() } }
    }

    @ObservationIgnored private var client: RFBClient?
    @ObservationIgnored private var forwarder: LocalForwarder?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var sender: InputSender?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private weak var mac: MacConnection?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var lastBytes = 0

    init(target: ScreenTarget) {
        self.target = target
    }

    var isRunning: Bool { phase == .connecting || phase == .live }
    /// A picture arrived (the first one can take a moment after connecting).
    private(set) var hasPicture = false

    // MARK: Connecting

    func showNeedsLogin() {
        stop()
        phase = .needsLogin
    }

    func start(mac: MacConnection, login: SecretStore.ScreenLogin?, options: ScreenOptions) async {
        // A workspace that stays in the phone's shape keeps its display (no flip back and forth).
        stop(keepDisplay: target == .workspace && options.matchShape)
        phase = .connecting
        self.options = options
        self.mac = mac
        do {
            guard let ssh = mac.ssh, ssh.isActive else { throw ScreenError.notConnected }
            let endpoint = try await mac.screenEndpoint(target)
            // The workspace in the phone's shape before the first picture, so it comes in the right shape.
            if target == .workspace, options.matchShape { await matchDisplay() }
            let username = target == .workspace ? (endpoint.username ?? "") : (login?.username ?? "")
            let password = target == .workspace ? (endpoint.password ?? "") : (login?.password ?? "")
            let forwarder = LocalForwarder(connection: ssh, targetHost: endpoint.host, targetPort: Int(endpoint.port))
            let port = try await forwarder.start()
            let client = RFBClient(host: "127.0.0.1", port: port, username: username, password: password,
                                   options: .viewer(options.quality, localCursor: options.localCursor))
            self.forwarder = forwarder
            self.client = client
            self.connection = ssh
            framebuffer = client.framebuffer
            stillImage = nil
            let sender = InputSender(client: client, typeText: Self.textTyper(for: target, mac: mac, ssh: ssh, client: client))
            sender.onTextFailed = { [weak self] text in
                self?.notice = String(localized: "Couldn't type \u{201E}\(text)\u{201C}.")
            }
            self.sender = sender
            inputReady = false
            frames = 0
            lastBytes = 0
            liveTask = Task { [weak self] in await self?.receive(client.events(minimumInterval: options.interval)) }
            statsTask = Task { [weak self] in await self?.measure(client) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(RFBClient.inputGrace))
                self?.inputReady = true
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    #if DEBUG
    /// Straight to a screen sharing server, without the Mac and SSH (see `Demo.directScreen`).
    func startDirect(host: String, port: UInt16, username: String, password: String, options: ScreenOptions) {
        stop()
        phase = .connecting
        self.options = options
        let client = RFBClient(host: host, port: port, username: username, password: password,
                               options: .viewer(options.quality, localCursor: options.localCursor))
        self.client = client
        framebuffer = client.framebuffer
        stillImage = nil
        sender = InputSender(client: client)
        inputReady = false
        frames = 0
        lastBytes = 0
        liveTask = Task { [weak self] in await self?.receive(client.events(minimumInterval: options.interval)) }
        statsTask = Task { [weak self] in await self?.measure(client) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(RFBClient.inputGrace))
            self?.inputReady = true
        }
    }
    #endif

    /// The demo shows a picture instead of a live screen.
    func showDemo(_ image: CGImage) {
        stop()
        stillImage = image
        hasPicture = true
        size = CGSize(width: image.width, height: image.height)
        pointer = CGPoint(x: size.width * 0.55, y: size.height * 0.45)
        phase = .live
        inputReady = true
        onFrame?()
    }

    func stop(keepDisplay: Bool = false) {
        liveTask?.cancel()
        liveTask = nil
        statsTask?.cancel()
        statsTask = nil
        displayTask?.cancel()
        displayTask = nil
        if let client { Task { await client.disconnect() } }
        client = nil
        forwarder?.stop()
        forwarder = nil
        sender = nil
        connection = nil
        dragging = false
        hasPicture = false
        // The workspace gets its own size back (if the phone can't say so, the Mac's lease runs out).
        if !keepDisplay {
            if displayRequest != nil, let companion = mac?.companion {
                Task { _ = try? await companion.display("reset") }
            }
            displayRequest = nil
        }
        if phase != .needsLogin { phase = .idle }
    }

    private func receive(_ events: AsyncThrowingStream<RFBEvent, Error>) async {
        do {
            for try await event in events {
                switch event {
                case .frame:
                    frames += 1
                    if !hasPicture { hasPicture = true }
                    if size == .zero, let s = framebuffer?.size, s.width > 0 {
                        size = s
                        pointer = CGPoint(x: s.width / 2, y: s.height / 2)
                    }
                    if phase != .live { phase = .live }
                    onFrame?()
                case .resized(let w, let h):
                    let newSize = CGSize(width: w, height: h)
                    if size != .zero, newSize != size, pointer != .zero {
                        // Keep the pointer at the same place relative to the screen.
                        pointer = CGPoint(x: pointer.x / size.width * newSize.width, y: pointer.y / size.height * newSize.height)
                    }
                    size = newSize
                    if pointer == .zero { pointer = CGPoint(x: newSize.width / 2, y: newSize.height / 2) }
                case .cursor(let c):
                    cursor = c.isEmpty ? nil : c
                case .pointer(let x, let y):
                    if !dragging { pointer = CGPoint(x: x, y: y) }
                case .clipboard, .bell:
                    break
                }
            }
            if !Task.isCancelled { phase = .failed(String(localized: "The screen connection ended.")) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { phase = .failed(describe(error)) }
        }
    }

    /// The first size comes with the connection (before the first update).
    private func measure(_ client: RFBClient) async {
        var lastFrames = 0
        var lastTime = Date()
        while !Task.isCancelled {
            if size == .zero {
                let w = await client.width, h = await client.height
                if w > 0, h > 0 {
                    size = CGSize(width: w, height: h)
                    if pointer == .zero { pointer = CGPoint(x: w / 2, y: h / 2) }
                }
            }
            try? await Task.sleep(for: .seconds(1))
            let s = await client.stats
            let now = Date()
            let dt = max(0.001, now.timeIntervalSince(lastTime))
            stats = ScreenStats(framesPerSecond: Double(frames - lastFrames) / dt,
                                kilobytesPerSecond: Double(max(0, s.bytes - lastBytes)) / 1024 / dt,
                                roundTrip: s.lastLatency, size: size, quality: options.quality)
            lastFrames = frames
            lastBytes = s.bytes
            lastTime = now
        }
    }

    enum ScreenError: LocalizedError {
        case notConnected
        var errorDescription: String? { String(localized: "Not connected to the Mac.") }
    }

    private func describe(_ error: Error) -> String {
        if let rfb = error as? RFBError {
            switch rfb {
            case .authFailed:
                return target == .mac
                    ? String(localized: "The Mac didn't accept the account name or password for screen sharing.")
                    : String(localized: "The workspace didn't accept the screen sharing login.")
            case .closed where forwarder?.lastError != nil || size == .zero:
                return target == .mac
                    ? String(localized: "The Mac's screen isn't shared. Turn on Screen Sharing on the Mac in System Settings > General > Sharing.")
                    : String(localized: "The workspace screen isn't available. Is the workspace open?")
            default:
                return rfb.localizedDescription
            }
        }
        if let companion = error as? CompanionError, case .refused(let message) = companion { return message }
        return error.localizedDescription
    }

    // MARK: The workspace in the phone's shape

    private func scheduleDisplayMatch() {
        guard target == .workspace, options.matchShape, isRunning else { return }
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            // Rotating sends a few sizes in a row: only the one it settles on counts.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.matchDisplay()
        }
    }

    /// Asks the Mac for the workspace's display in the viewer's shape, and keeps renewing it (the Mac gives it back
    /// to the workspace when the renewals stop).
    private func matchDisplay() async {
        guard let wanted = DisplayRequest.fitting(points: viewerArea, retina: options.retina),
              let companion = mac?.companion else { return }
        do {
            _ = try await companion.display(wanted.description)
            displayRequest = wanted
        } catch {
            // An older Mac or a closed workspace: the picture keeps the workspace's own shape.
            log.notice("Display request refused: \(String(describing: error), privacy: .public)")
            return
        }
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let request = self.displayRequest,
                      let companion = self.mac?.companion else { return }
                _ = try? await companion.display(request.description)
            }
        }
    }

    // MARK: Pointer

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), max(0, size.width - 1)), y: min(max(0, p.y), max(0, size.height - 1)))
    }

    private var heldButtons: Set<RFBClient.Button> { dragging ? [.left] : [] }

    private func sendPointer(buttons: Set<RFBClient.Button>? = nil) {
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: buttons ?? heldButtons))
    }

    /// Click (or right click) at a point; `count` 2 is a double click.
    func click(at point: CGPoint, button: RFBClient.Button = .left, count: Int = 1) {
        pointer = clamp(point)
        withModifiers {
            sendPointer(buttons: [])
            for _ in 0..<max(1, count) {
                sendPointer(buttons: [button])
                sendPointer(buttons: [])
            }
        }
    }

    func clickAtPointer(button: RFBClient.Button = .left, count: Int = 1) { click(at: pointer, button: button, count: count) }

    /// Trackpad mode: moves the pointer by a distance in screen pixels (with the button held while dragging).
    func movePointer(by delta: CGPoint) {
        pointer = clamp(CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y))
        sendPointer()
    }

    /// Moves the pointer to a point (direct touch, a hardware pointer).
    func movePointer(to point: CGPoint) {
        pointer = clamp(point)
        sendPointer()
    }

    /// A drag with the left button: down here, then moves, then `endDrag`.
    func beginDrag(at point: CGPoint? = nil) {
        if let point { pointer = clamp(point) }
        pressStickyModifiers()
        sendPointer(buttons: [])
        dragging = true
        sendPointer()
    }

    func endDrag(at point: CGPoint? = nil) {
        guard dragging else { return }
        if let point { pointer = clamp(point) }
        dragging = false
        sendPointer()
        releaseStickyModifiers()
    }

    /// Scroll wheel steps at the pointer (or a point): positive `dy` shows what's further down.
    func scroll(dx: Int, dy: Int, at point: CGPoint? = nil) {
        guard dx != 0 || dy != 0 else { return }
        let p = clamp(point ?? pointer)
        sender?.send(.wheel(x: Int(p.x), y: Int(p.y), dx: dx, dy: dy, buttons: heldButtons))
    }

    // MARK: Keyboard

    /// Tapping a modifier in the key bar: on for the next key; tapping it while on locks it; tapping a locked one
    /// turns it off.
    func toggleSticky(_ modifier: UInt32) {
        if let index = lockedModifiers.firstIndex(of: modifier) {
            lockedModifiers.remove(at: index)
        } else if let index = stickyModifiers.firstIndex(of: modifier) {
            stickyModifiers.remove(at: index)
            lockedModifiers.append(modifier)
        } else {
            stickyModifiers.append(modifier)
        }
    }

    func isModifierOn(_ modifier: UInt32) -> Bool { stickyModifiers.contains(modifier) || lockedModifiers.contains(modifier) }
    func isModifierLocked(_ modifier: UInt32) -> Bool { lockedModifiers.contains(modifier) }

    private var activeModifiers: [UInt32] {
        lockedModifiers + stickyModifiers.filter { !lockedModifiers.contains($0) }
    }

    /// One key (from the key bar or a hardware keyboard), with the modifiers that are on.
    func press(_ keysym: UInt32, modifiers: [UInt32] = []) {
        let all = activeModifiers + modifiers.filter { !activeModifiers.contains($0) }
        stickyModifiers = []
        for m in all { sender?.send(.key(m, down: true)) }
        sender?.send(.key(keysym, down: true))
        sender?.send(.key(keysym, down: false))
        for m in all.reversed() { sender?.send(.key(m, down: false)) }
    }

    /// A combination like cmd+shift+4 (the key bar's shortcuts).
    func press(combination keysyms: [UInt32]) {
        guard let key = keysyms.last else { return }
        press(key, modifiers: Array(keysyms.dropLast()))
    }

    /// A hardware key going down or up (held keys and modifiers stay down until released).
    func key(_ keysym: UInt32, down: Bool) {
        sender?.send(.key(keysym, down: down))
    }

    /// Text from the on-screen keyboard.
    func type(_ text: String) {
        let steps = KeyInput.steps(for: text)
        // The workspace types text with characters beyond ASCII itself (companion `type`), all of it, in order.
        if target == .workspace, activeModifiers.isEmpty, steps.contains(where: { if case .paste = $0 { true } else { false } }) {
            sender?.send(.text(text))
            return
        }
        for step in steps {
            switch step {
            case .keys(let strokes):
                for stroke in strokes {
                    if !activeModifiers.isEmpty {
                        // cmd+c and the like: the key itself (a capital letter as its lower case key)
                        press((0x41...0x5A).contains(stroke.keysym) ? stroke.keysym + 0x20 : stroke.keysym)
                        continue
                    }
                    if stroke.shift { sender?.send(.key(Keysyms.shift, down: true)) }
                    sender?.send(.key(stroke.keysym, down: true))
                    sender?.send(.key(stroke.keysym, down: false))
                    if stroke.shift { sender?.send(.key(Keysyms.shift, down: false)) }
                }
            case .paste(let text):
                sender?.send(.text(text))
            }
        }
    }

    func backspace() { press(KeyInput.backspace) }

    /// How text that can't be typed as keys gets there. On the Mac: its clipboard (pbcopy over SSH, as the Mac's own
    /// user), then cmd+v. In the workspace: the companion's `type`, which does the same inside the guest.
    private static func textTyper(for target: ScreenTarget, mac: MacConnection, ssh: SSHConnection,
                                  client: RFBClient) -> InputSender.TextTyper {
        switch target {
        case .workspace:
            return { [weak mac] text in
                guard let mac else { throw CompanionError.closed }
                try await mac.typeInWorkspace(text)
            }
        case .mac:
            return { text in
                let channel = try await ssh.exec("LC_ALL=en_US.UTF-8 /usr/bin/pbcopy")
                try await channel.write(Data(text.utf8))
                await channel.closeInput()
                for try await _ in channel.output {}
                try await client.key(Keysyms.command, down: true)
                try await client.key(0x76, down: true)
                try await client.key(0x76, down: false)
                try await client.key(Keysyms.command, down: false)
            }
        }
    }

    @ObservationIgnored private var heldStickyModifiers: [UInt32] = []

    private func pressStickyModifiers() {
        heldStickyModifiers = activeModifiers
        stickyModifiers = []
        for m in heldStickyModifiers { sender?.send(.key(m, down: true)) }
    }

    private func releaseStickyModifiers() {
        for m in heldStickyModifiers.reversed() { sender?.send(.key(m, down: false)) }
        heldStickyModifiers = []
    }

    private func withModifiers(_ body: () -> Void) {
        pressStickyModifiers()
        body()
        releaseStickyModifiers()
    }
}

/// Sends input to the screen strictly in order, one event at a time; pointer moves that pile up while the connection
/// is busy are merged into the newest (presses and releases never are).
final class InputSender: @unchecked Sendable {
    enum Event: Sendable {
        case pointer(x: Int, y: Int, buttons: Set<RFBClient.Button>)
        case key(UInt32, down: Bool)
        case wheel(x: Int, y: Int, dx: Int, dy: Int, buttons: Set<RFBClient.Button>)
        /// Text that can't be typed as keys (see `ScreenSession.textTyper`).
        case text(String)
    }

    typealias TextTyper = @Sendable @MainActor (String) async throws -> Void
    private let typeText: TextTyper?
    /// Called (on the main actor) when text couldn't be typed.
    var onTextFailed: (@Sendable @MainActor (String) -> Void)?

    private let client: RFBClient
    private let lock = NSLock()
    private var queue: [Event] = []
    private var running = false

    init(client: RFBClient, typeText: TextTyper? = nil) {
        self.client = client
        self.typeText = typeText
    }

    func send(_ event: Event) {
        let start: Bool = lock.withLock {
            switch (event, queue.last) {
            case (.pointer(_, _, let buttons), .pointer(_, _, let waiting)?) where buttons == waiting:
                queue[queue.count - 1] = event
            case (.wheel(let x, let y, let dx, let dy, let b), .wheel(let wx, let wy, let wdx, let wdy, let wb)?)
                where x == wx && y == wy && b == wb && (dx == 0 || wdx == 0 || (dx > 0) == (wdx > 0))
                    && (dy == 0 || wdy == 0 || (dy > 0) == (wdy > 0)):
                // Steps that pile up in the same direction go out together.
                queue[queue.count - 1] = .wheel(x: x, y: y, dx: dx + wdx, dy: dy + wdy, buttons: b)
            default:
                queue.append(event)
            }
            guard !running else { return false }
            running = true
            return true
        }
        if start { Task { await self.drain() } }
    }

    private func next() -> Event? {
        lock.withLock {
            guard !queue.isEmpty else { running = false; return nil }
            return queue.removeFirst()
        }
    }

    private func drain() async {
        while let event = next() {
            do {
                switch event {
                case .pointer(let x, let y, let buttons): try await client.pointer(x: x, y: y, pressed: buttons)
                case .key(let keysym, let down): try await client.key(keysym, down: down)
                case .wheel(let x, let y, let dx, let dy, let buttons):
                    try await client.wheel(x: x, y: y, dx: dx, dy: dy, pressed: buttons)
                case .text(let text):
                    do {
                        try await typeText?(text)
                    } catch {
                        let report = onTextFailed
                        await MainActor.run { report?(text) }
                    }
                }
            } catch {
                log.notice("Input not sent: \(String(describing: error), privacy: .public)")
                lock.withLock { queue.removeAll() }
            }
        }
    }
}

/// Whether the phone is on a cellular (or otherwise metered) network now: picks the automatic picture quality.
final class NetworkKind: @unchecked Sendable {
    static let shared = NetworkKind()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.usesInterfaceType(.cellular)
            self?.lock.withLock { self?.expensive = metered }
        }
        monitor.start(queue: DispatchQueue(label: "dev.marquart.aos.network-kind"))
    }

    var isCellular: Bool { lock.withLock { expensive } }
}
