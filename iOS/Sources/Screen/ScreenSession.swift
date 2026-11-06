import AOSRFB
import CoreGraphics
import Foundation
import Observation
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "screen")

/// A live screen: the Mac's own or the workspace's, through the SSH connection (direct-tcpip to its screen sharing
/// port, bridged to a loopback listener for `RFBClient`).
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
    private(set) var frame: CGImage?
    /// Screen size in pixels.
    private(set) var size: CGSize = .zero
    /// Where the remote pointer is (pixels).
    private(set) var pointer: CGPoint = .zero
    /// Screen sharing ignores input for a few seconds after connecting; until then input waits.
    private(set) var inputReady = false
    /// A short message for the person (a character that can't be typed, for example).
    var notice: String?
    /// Modifier keys from the key bar that apply to the next key.
    private(set) var stickyModifiers: [UInt32] = []

    private var client: RFBClient?
    private var forwarder: LocalForwarder?
    private var liveTask: Task<Void, Never>?
    private var sender: InputSender?
    private var connection: SSHConnection?
    private var startedAt = Date.distantPast

    init(target: ScreenTarget) {
        self.target = target
    }

    var isRunning: Bool { phase == .connecting || phase == .live }

    // MARK: Connecting

    func showNeedsLogin() {
        stop()
        phase = .needsLogin
    }

    func start(mac: MacConnection, login: SecretStore.ScreenLogin?, interval: TimeInterval) async {
        stop()
        phase = .connecting
        do {
            guard let ssh = mac.ssh, ssh.isActive else { throw ScreenError.notConnected }
            let endpoint = try await mac.screenEndpoint(target)
            let username = target == .workspace ? (endpoint.username ?? "") : (login?.username ?? "")
            let password = target == .workspace ? (endpoint.password ?? "") : (login?.password ?? "")
            let forwarder = LocalForwarder(connection: ssh, targetHost: endpoint.host, targetPort: Int(endpoint.port))
            let port = try await forwarder.start()
            let client = RFBClient(host: "127.0.0.1", port: port, username: username, password: password)
            self.forwarder = forwarder
            self.client = client
            self.connection = ssh
            let sender = InputSender(client: client, typeText: Self.textTyper(for: target, mac: mac, ssh: ssh, client: client))
            sender.onTextFailed = { [weak self] text in
                self?.notice = String(localized: "Couldn't type \u{201E}\(text)\u{201C}.")
            }
            self.sender = sender
            startedAt = Date()
            inputReady = false
            liveTask = Task { [weak self] in await self?.receive(client.liveFrames(minimumInterval: interval)) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(RFBClient.inputGrace))
                self?.inputReady = true
            }
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// The demo shows a picture instead of a live screen.
    func showDemo(_ image: CGImage) {
        stop()
        frame = image
        size = CGSize(width: image.width, height: image.height)
        pointer = CGPoint(x: size.width * 0.55, y: size.height * 0.45)
        phase = .live
        inputReady = true
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
        if let client { Task { await client.disconnect() } }
        client = nil
        forwarder?.stop()
        forwarder = nil
        sender = nil
        connection = nil
        if phase != .needsLogin { phase = .idle }
    }

    private func receive(_ frames: AsyncThrowingStream<CGImage, Error>) async {
        do {
            for try await image in frames {
                frame = image
                let newSize = CGSize(width: image.width, height: image.height)
                if newSize != size {
                    size = newSize
                    if pointer == .zero { pointer = CGPoint(x: newSize.width / 2, y: newSize.height / 2) }
                }
                if phase != .live { phase = .live }
            }
            if !Task.isCancelled { phase = .failed(String(localized: "The screen connection ended.")) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { phase = .failed(describe(error)) }
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
            case .closed where forwarder?.lastError != nil || frame == nil:
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

    // MARK: Pointer

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), max(0, size.width - 1)), y: min(max(0, p.y), max(0, size.height - 1)))
    }

    /// Click (or right click) at a point.
    func click(at point: CGPoint, button: RFBClient.Button = .left) {
        let p = clamp(point)
        pointer = p
        withModifiers {
            sender?.send(.pointer(x: Int(p.x), y: Int(p.y), buttons: []))
            sender?.send(.pointer(x: Int(p.x), y: Int(p.y), buttons: [button]))
            sender?.send(.pointer(x: Int(p.x), y: Int(p.y), buttons: []))
        }
    }

    func clickAtPointer(button: RFBClient.Button = .left) { click(at: pointer, button: button) }

    /// Trackpad mode: moves the pointer by a distance in screen pixels.
    func movePointer(by delta: CGSize) {
        pointer = clamp(CGPoint(x: pointer.x + delta.width, y: pointer.y + delta.height))
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: []))
    }

    /// Direct mode: a drag with the left button.
    func dragBegan(at point: CGPoint) {
        pointer = clamp(point)
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: []))
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: [.left]))
    }

    func dragMoved(to point: CGPoint) {
        pointer = clamp(point)
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: [.left]))
    }

    func dragEnded(at point: CGPoint) {
        pointer = clamp(point)
        sender?.send(.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: []))
    }

    /// Scrolls at the pointer; `steps` positive scrolls the content down (like a finger moving up).
    func scroll(vertical: Int, horizontal: Int, at point: CGPoint? = nil) {
        let p = clamp(point ?? pointer)
        if vertical != 0 {
            sender?.send(.scroll(x: Int(p.x), y: Int(p.y), direction: vertical > 0 ? .down : .up, steps: abs(vertical)))
        }
        if horizontal != 0 {
            sender?.send(.scroll(x: Int(p.x), y: Int(p.y), direction: horizontal > 0 ? .right : .left,
                                 steps: abs(horizontal)))
        }
    }

    // MARK: Keyboard

    func toggleSticky(_ modifier: UInt32) {
        if let index = stickyModifiers.firstIndex(of: modifier) {
            stickyModifiers.remove(at: index)
        } else {
            stickyModifiers.append(modifier)
        }
    }

    /// One key (from the key bar or a hardware keyboard), with the sticky modifiers.
    func press(_ keysym: UInt32, modifiers: [UInt32] = []) {
        let all = stickyModifiers + modifiers.filter { !stickyModifiers.contains($0) }
        stickyModifiers = []
        for m in all { sender?.send(.key(m, down: true)) }
        sender?.send(.key(keysym, down: true))
        sender?.send(.key(keysym, down: false))
        for m in all.reversed() { sender?.send(.key(m, down: false)) }
    }

    /// Text from the on-screen keyboard.
    func type(_ text: String) {
        let steps = KeyInput.steps(for: text)
        // The workspace types text with characters beyond ASCII itself (companion `type`), all of it, in order.
        if target == .workspace, stickyModifiers.isEmpty, steps.contains(where: { if case .paste = $0 { true } else { false } }) {
            sender?.send(.text(text))
            return
        }
        for step in steps {
            switch step {
            case .keys(let strokes):
                for stroke in strokes {
                    if !stickyModifiers.isEmpty {
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
                paste(text)
            }
        }
    }

    func backspace() { press(KeyInput.backspace) }

    /// Characters without a key symbol, in order with the keys around them (see `textTyper`).
    private func paste(_ text: String) {
        sender?.send(.text(text))
    }

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

    private func withModifiers(_ body: () -> Void) {
        let modifiers = stickyModifiers
        stickyModifiers = []
        for m in modifiers { sender?.send(.key(m, down: true)) }
        body()
        for m in modifiers.reversed() { sender?.send(.key(m, down: false)) }
    }
}

/// Sends input to the screen strictly in order, one event at a time; pointer moves that pile up while the connection
/// is busy are merged into the newest (presses and releases never are).
final class InputSender: @unchecked Sendable {
    enum Event: Sendable {
        case pointer(x: Int, y: Int, buttons: Set<RFBClient.Button>)
        case key(UInt32, down: Bool)
        case scroll(x: Int, y: Int, direction: RFBClient.ScrollDirection, steps: Int)
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
            if case .pointer(_, _, let buttons) = event, case .pointer(_, _, let waiting)? = queue.last, buttons == waiting {
                queue[queue.count - 1] = event
            } else {
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
                case .scroll(let x, let y, let direction, let steps):
                    try await client.scroll(x: x, y: y, direction: direction, steps: steps)
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
