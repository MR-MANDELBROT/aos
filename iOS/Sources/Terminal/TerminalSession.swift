import Foundation
import Observation
import os
import SwiftTerm
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "terminal")

/// One terminal, shown by SwiftTerm. On the paired Mac it is a session that outlives the connection
/// (`aos-companion term attach`, TerminalAttach.swift): when the connection drops (the app in the background, a new
/// network) the shell keeps running on the Mac, and the terminal attaches again by itself as soon as the Mac is
/// reachable, getting exactly the output it missed. On other computers it is a login shell over SSH. The terminal
/// view lives here, so its contents survive leaving the screen and coming back.
@MainActor @Observable
final class TerminalSession: Identifiable, TerminalInteractionDelegate {
    enum Target: Hashable, Sendable {
        case mac(UUID)
        case host(UUID)

        /// For links and the Live Activity.
        var key: String {
            switch self {
            case .mac(let id): "mac-\(id.uuidString)"
            case .host(let id): "host-\(id.uuidString)"
            }
        }

        init?(key: String) {
            if key.hasPrefix("mac-"), let id = UUID(uuidString: String(key.dropFirst(4))) { self = .mac(id) }
            else if key.hasPrefix("host-"), let id = UUID(uuidString: String(key.dropFirst(5))) { self = .host(id) }
            else { return nil }
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// The connection dropped; on the Mac the shell keeps running and the terminal attaches again by itself.
        case reconnecting
        /// The person detached; the session keeps running on the Mac.
        case detached
        case ended
        case failed(String)
        /// First connection to an added host: the person checks the key and trusts it.
        case confirmHostKey(host: String, key: String, fingerprint: String)
        /// The host presents another key than the one trusted before.
        case hostKeyChanged(host: String, fingerprint: String)
    }

    /// Why the terminal ended.
    enum EndReason: Equatable, Sendable {
        /// The shell on another computer, or the connection to it, ended.
        case closed
        /// The shell on the Mac exited.
        case exited
        /// Someone ended the session (here, in the list, or on the Mac).
        case ended
        /// Another device attached to the session.
        case taken
    }

    /// A short message over the terminal ("Copied", the font size while pinching).
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    let id: Target
    var title: String
    private(set) var phase: Phase = .idle
    private(set) var endReason: EndReason = .closed
    /// Since when the terminal is connected (for the Live Activity).
    private(set) var connectedSince: Date?
    @ObservationIgnored let view: AOSTerminalView
    @ObservationIgnored private var bridge: Bridge!
    private var channel: SessionChannel?
    private var ownConnection: SSHConnection?
    private var readTask: Task<Void, Never>?
    /// Input goes out in order through one task (separate tasks per key press could overtake each other).
    @ObservationIgnored private var writer: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    /// The terminal's size in characters, as the view last reported it.
    @ObservationIgnored private var size: (columns: Int, rows: Int) = (80, 24)

    private(set) var notice: Notice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Text that would run as commands (no bracketed paste, line breaks in it): the screen asks first.
    var pendingPaste: String?
    /// The font size after the last change was finished (the screen keeps it in the settings).
    private(set) var fontSize: CGFloat
    private(set) var keyboardShown = false

    /// Phase or title changed (the app's Live Activity follows).
    @ObservationIgnored var onChange: ((TerminalSession) -> Void)?

    // MARK: The Mac's session

    /// The Mac connection to attach through (the app's current one).
    @ObservationIgnored var macConnection: () -> MacConnection? = { nil }
    /// The session on the Mac this terminal shows (kept across launches of the app).
    private(set) var holderID: String?
    /// False when aOS on the Mac can't hold sessions (an older version): a plain shell then.
    private(set) var holdsSession = true
    /// The offset after the last output byte the view has, and whether the view has the session's output at all
    /// (not after a launch: then the next attach starts afresh).
    @ObservationIgnored private var received: UInt64 = 0
    @ObservationIgnored private var viewHasOutput = false
    @ObservationIgnored private var filter = TermNoteFilter()
    /// The terminal should stay attached (until the person detaches or the session ends).
    @ObservationIgnored private var wantsAttached = false
    @ObservationIgnored private var reattach: Task<Void, Never>?
    @ObservationIgnored private var quickFailures = 0
    @ObservationIgnored private var gotEndNote = false
    @ObservationIgnored private var gotStartNote = false
    @ObservationIgnored private var channelOpened = Date.distantPast

    init(id: Target, title: String, fontSize: CGFloat = TerminalFontSize.standard) {
        self.id = id
        self.title = title
        let size = TerminalFontSize.clamped(fontSize)
        self.fontSize = size
        view = AOSTerminalView(fontSize: size)
        bridge = Bridge(session: self)
        view.terminalDelegate = bridge
        view.interaction = self
        if case .mac = id { holderID = UserDefaults.standard.string(forKey: holderKey).flatMap { TermAttach.isID($0) ? $0 : nil } }
    }

    var isActive: Bool { phase == .connecting || phase == .connected || phase == .reconnecting }

    private var holderKey: String { "terminal.session.\(id.key)" }

    private func setPhase(_ new: Phase) {
        guard phase != new else { return }
        phase = new
        if new == .connected, connectedSince == nil { connectedSince = Date() }
        if new == .ended || new == .detached || new == .idle { connectedSince = nil }
        if case .failed = new { connectedSince = nil }
        onChange?(self)
    }

    private func remember(holder id: String?) {
        holderID = id
        if let id { UserDefaults.standard.set(id, forKey: holderKey) } else { UserDefaults.standard.removeObject(forKey: holderKey) }
    }

    // MARK: Connecting

    /// The terminal on the paired Mac, in the app's SSH connection: its session there, or a new one.
    func connect(mac: MacConnection) async {
        wantsAttached = true
        endReason = .closed
        quickFailures = 0
        if macConnection() == nil { macConnection = { [weak mac] in mac } }
        await attachToMac()
    }

    /// Attaches to the Mac's session (or starts one), or waits for the Mac if it isn't reachable now.
    private func attachToMac() async {
        guard wantsAttached else { return }
        reattach?.cancel()
        reattach = nil
        guard let mac = macConnection(), let ssh = mac.ssh, ssh.isActive else {
            setPhase(viewHasOutput ? .reconnecting : .connecting)
            waitForMac()
            return
        }
        if phase != .reconnecting { setPhase(.connecting) }
        do {
            let shell: SessionChannel
            if holdsSession {
                let command = TermAttach.attach(companion: mac.mac.companionPath, id: holderID,
                                                have: viewHasOutput ? received : nil)
                shell = try await ssh.terminal(command: command, columns: max(size.columns, 20), rows: max(size.rows, 5))
            } else {
                shell = try await ssh.shell(columns: max(size.columns, 20), rows: max(size.rows, 5))
            }
            guard wantsAttached else { await shell.close(); return }
            run(shell, held: holdsSession)
        } catch {
            log.notice("Attaching failed: \(String(describing: error), privacy: .public)")
            quickFailures += 1
            if quickFailures >= 4 {
                wantsAttached = false
                setPhase(.failed(error.localizedDescription))
                return
            }
            setPhase(viewHasOutput ? .reconnecting : .connecting)
            waitForMac(after: Double(quickFailures))
        }
    }

    /// Waits until the app's connection to the Mac is up again (it reconnects by itself), then attaches.
    private func waitForMac(after delay: TimeInterval = 0) {
        reattach?.cancel()
        reattach = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            while !Task.isCancelled {
                guard let self, self.wantsAttached else { return }
                if let ssh = self.macConnection()?.ssh, ssh.isActive {
                    await self.attachToMac()
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// A shell on an added host, in a connection of its own.
    func connect(host: SSHHost, key: DeviceKey?, password: String?) async {
        disconnect()
        setPhase(.connecting)
        endReason = .closed
        let policy: HostKeyPolicy = host.hostKey.map { .pinned($0) } ?? .askFirst
        do {
            let connection = try await SSHConnection.connect(
                hosts: [host.host], port: Int(host.port),
                login: SSHLogin(username: host.user, key: host.auth == .deviceKey ? key : nil,
                                password: host.auth == .password ? password : nil),
                hostKey: policy, perHostTimeout: 10)
            ownConnection = connection
            let shell = try await connection.shell(columns: max(size.columns, 20), rows: max(size.rows, 5))
            run(shell, held: false)
        } catch SSHConnectError.unknownHostKey(let h, let key, let fingerprint) {
            setPhase(.confirmHostKey(host: h, key: key, fingerprint: fingerprint))
        } catch SSHConnectError.hostKeyMismatch(let h, let fingerprint) {
            setPhase(.hostKeyChanged(host: h, fingerprint: fingerprint))
        } catch SSHConnectError.authenticationFailed {
            setPhase(.failed(host.auth == .password
                ? String(localized: "\(host.host) didn't accept the user name or password.")
                : String(localized: "\(host.host) didn't accept this iPhone's key. Add the key to ~/.ssh/authorized_keys there (Settings > This iPhone).")))
        } catch {
            setPhase(.failed(error.localizedDescription))
        }
    }

    /// Reads and writes the channel until it ends.
    private func run(_ shell: SessionChannel, held: Bool) {
        channel = shell
        channelOpened = Date()
        gotEndNote = false
        gotStartNote = false
        filter = TermNoteFilter()
        let (input, writer) = AsyncStream<Data>.makeStream()
        self.writer = writer
        writeTask = Task {
            for await data in input { try? await shell.write(data) }
        }
        // A plain shell is there at once; a held session once the Mac says where its output starts.
        if !held { setPhase(.connected) }
        readTask = Task { [weak self] in
            do {
                for try await chunk in shell.output {
                    guard let self else { return }
                    if held { self.receive(chunk) } else { self.view.feed(byteArray: ArraySlice(chunk)) }
                }
                self?.channelEnded(nil, held: held)
            } catch {
                self?.channelEnded(error, held: held)
            }
        }
    }

    private func receive(_ chunk: Data) {
        for piece in filter.feed(chunk) {
            switch piece {
            case .bytes(let data):
                view.feed(byteArray: ArraySlice(data))
                received &+= UInt64(data.count)
            case .note(let note):
                handle(note)
            }
        }
    }

    private func handle(_ note: TermNote) {
        switch note {
        case .start(let id, let from, let reset, let prefix, let new, let gone):
            gotStartNote = true
            if reset { view.startAfresh(prefix: prefix) }
            received = from
            viewHasOutput = true
            remember(holder: id)
            quickFailures = 0
            if new, gone != nil { show(String(localized: "The session on the Mac had ended. This is a new one.")) }
            setPhase(.connected)
        case .end(let why, _):
            gotEndNote = true
            switch why {
            case "taken":
                endReason = .taken
                wantsAttached = false
            case "lost":
                // The session's process on the Mac went away: the next attach starts a new one.
                remember(holder: nil)
                viewHasOutput = false
                gotEndNote = false
            default:
                endReason = why == "exited" ? .exited : .ended
                wantsAttached = false
                remember(holder: nil)
                viewHasOutput = false
            }
        }
    }

    private func channelEnded(_ error: Error?, held: Bool) {
        channel = nil
        stopWriting()
        if let ownConnection { Task { await ownConnection.close() } }
        ownConnection = nil
        guard held else {
            if phase == .connected { setPhase(.ended) }
            view.feed(text: "\r\n")
            return
        }
        if gotEndNote {
            setPhase(.ended)
            return
        }
        // aOS on the Mac without terminal sessions (exit status 2: its usage), or not there (127): a plain shell.
        if !gotStartNote, let failure = error as? SessionChannel.Failure, case .exited(let status, _) = failure,
           status == 2 || status == 127 {
            log.notice("The Mac can't hold terminal sessions (status \(status)); using a plain shell")
            holdsSession = false
            show(status == 2 ? String(localized: "Update aOS on the Mac to keep this terminal when the connection drops.")
                             : String(localized: "aOS isn't on the Mac where it was paired: this terminal ends with the connection."))
            Task { await attachToMac() }
            return
        }
        guard wantsAttached else { return }
        if !gotStartNote, Date().timeIntervalSince(channelOpened) < 3 { quickFailures += 1 }
        if quickFailures >= 4 {
            wantsAttached = false
            setPhase(.failed(error?.localizedDescription ?? String(localized: "The terminal on the Mac doesn't start.")))
            return
        }
        log.info("Terminal connection dropped; attaching again when the Mac is reachable")
        setPhase(.reconnecting)
        waitForMac(after: quickFailures > 0 ? 1 : 0)
    }

    /// Lets go of the terminal. On the Mac the session keeps running (detached); elsewhere the shell ends.
    func disconnect() {
        wantsAttached = false
        reattach?.cancel()
        reattach = nil
        readTask?.cancel()
        readTask = nil
        let channel = self.channel, connection = ownConnection
        self.channel = nil
        ownConnection = nil
        stopWriting()
        Task {
            await channel?.close()
            await connection?.close()
        }
        if case .mac = id, holdsSession, holderID != nil, isActive {
            setPhase(.detached)
        } else if isActive {
            setPhase(.ended)
        }
    }

    /// Ends the shell on the Mac (SIGHUP, like closing a terminal window), or disconnects elsewhere.
    func endSession() async {
        guard case .mac = id, holdsSession, let holderID else {
            disconnect()
            return
        }
        wantsAttached = false
        reattach?.cancel()
        if let mac = macConnection(), let ssh = mac.ssh, ssh.isActive,
           let command = TermAttach.end(companion: mac.mac.companionPath, id: holderID) {
            _ = try? await ssh.run(command, timeout: .seconds(10))
        }
        // The attached channel hears it too; without one the session is gone anyway.
        if channel == nil || !gotStartNote {
            remember(holder: nil)
            viewHasOutput = false
            endReason = .ended
            disconnect()
            setPhase(.ended)
        }
    }

    /// Switches this terminal to another session on the Mac (from the list).
    func switchTo(session id: String) async {
        guard case .mac = self.id, TermAttach.isID(id), id != holderID || !isActive else { return }
        disconnect()
        remember(holder: id)
        viewHasOutput = false
        holdsSession = true
        if let mac = macConnection() { await connect(mac: mac) }
    }

    /// The next connect starts a new session on the Mac (after this one ended).
    func forgetSession() {
        remember(holder: nil)
        viewHasOutput = false
    }

    /// Shows sample output (the demo).
    func showDemo(_ text: String) {
        setPhase(.connected)
        view.feed(text: text)
    }

    private func stopWriting() {
        writer?.finish()
        writer = nil
        writeTask = nil
    }

    // MARK: Copy, paste, font

    /// Pastes text: bracketed if the program asked for it; if not and the text has line breaks, the screen asks first.
    func paste(_ text: String) {
        let bracketed = view.terminalInputStateSnapshot()?.bracketedPasteMode ?? false
        if PasteEncoder.runsLines(text, bracketed: bracketed) {
            pendingPaste = text
        } else {
            sendPaste(text, bracketed: bracketed)
        }
    }

    /// After the person confirmed.
    func confirmPaste(_ text: String) {
        pendingPaste = nil
        sendPaste(text, bracketed: view.terminalInputStateSnapshot()?.bracketedPasteMode ?? false)
    }

    private func sendPaste(_ text: String, bracketed: Bool) {
        view.clearTextSelection()
        view.send(PasteEncoder.bytes(for: text, bracketed: bracketed))
    }

    func copyScreen() {
        Clipboard.copyPlain(view.screenText())
        terminalNotice(String(localized: "Screen copied"))
    }

    func copyLastOutput() {
        if let text = view.lastOutputText() {
            Clipboard.copyPlain(text)
            terminalNotice(String(localized: "Output copied"))
        } else {
            show(String(localized: "No output to copy"))
        }
    }

    func setFontSize(_ size: CGFloat) {
        view.setFontSize(size)
        fontSize = view.font.pointSize
    }

    /// From the menu: a step bigger or smaller, shown like a pinch.
    func adjustFontSize(by step: CGFloat) { adjustFontSize(to: fontSize + step) }

    func adjustFontSize(to size: CGFloat) {
        setFontSize(size)
        terminalFontSizeChanged(fontSize, done: true)
    }

    func toggleKeyboard() {
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    func show(_ text: String) {
        notice = Notice(text: text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: From the terminal view

    func terminalPaste(_ text: String) { paste(text) }

    func terminalNotice(_ text: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show(text)
    }

    func terminalFontSizeChanged(_ size: CGFloat, done: Bool) {
        let dimensions = view.terminalDimensions
        show(String(localized: "\(Int(size)) pt · \(dimensions.cols) × \(dimensions.rows)"))
        if done { fontSize = size }
    }

    func terminalFocusChanged(_ focused: Bool) { keyboardShown = focused }

    fileprivate func send(_ bytes: ArraySlice<UInt8>) {
        guard let writer else { return }
        writer.yield(Data(bytes))
        // Return at the shell: where the next command's output begins ("Copy last output").
        if bytes.count == 1, bytes.first == 0x0d { view.noteReturnSent() }
    }

    fileprivate func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        size = (columns, rows)
        guard let channel else { return }
        Task { try? await channel.resize(columns: columns, rows: rows) }
    }

    /// SwiftTerm's delegate, kept apart from the observable model.
    private final class Bridge: NSObject, TerminalViewDelegate {
        weak var session: TerminalSession?

        init(session: TerminalSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session?.send(data) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session?.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // Only web links, and only when the person taps them.
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { MainActor.assumeIsolated { Clipboard.copyPlain(text) } }
        }
    }
}
