import Foundation
import Observation
import os
import SwiftTerm
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "terminal")

/// The terminal on the paired Mac, shown by SwiftTerm: one of the Mac's sessions at a time, which outlive the
/// connection (`aos-companion term attach`, TerminalAttach.swift). When the connection drops (the app in the
/// background, a new network, the Mac asleep) the shell keeps running on the Mac, and the terminal attaches again by
/// itself as soon as the Mac is reachable, getting exactly the output it missed. "New Session" starts another shell
/// there, switching shows another one (the one before keeps running). This iPhone names itself when it attaches
/// (its phone id), so a newer connection of its own replaces an older one without a word: only another device
/// "takes" a session. The terminal view lives here, so its contents survive leaving the screen and coming back.
@MainActor @Observable
final class TerminalSession: Identifiable, TerminalInteractionDelegate {
    enum Target: Hashable, Sendable {
        case mac(UUID)

        /// For links and the Live Activity.
        var key: String {
            switch self {
            case .mac(let id): "mac-\(id.uuidString)"
            }
        }

        init?(key: String) {
            guard key.hasPrefix("mac-"), let id = UUID(uuidString: String(key.dropFirst(4))) else { return nil }
            self = .mac(id)
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// The connection dropped; on the Mac the shell keeps running and the terminal attaches again by itself.
        case reconnecting
        case ended
        case failed(String)
    }

    /// Why the terminal ended.
    enum EndReason: Equatable, Sendable {
        /// The shell, or the connection to it, ended (a plain shell: an older aOS on the Mac).
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
    /// This iPhone's id (`DeviceKey.phoneID`), named when attaching.
    @ObservationIgnored var phoneID: () -> String? = { nil }
    /// The session on the Mac this terminal shows (kept across launches of the app).
    private(set) var holderID: String?
    /// False when aOS on the Mac can't hold sessions (an older version): a plain shell then.
    private(set) var holdsSession = true
    /// The offset after the last output byte the view has, and whether the view has the session's output at all
    /// (not after a launch: then the next attach starts afresh).
    @ObservationIgnored private var received: UInt64 = 0
    @ObservationIgnored private var viewHasOutput = false
    @ObservationIgnored private var filter = TermNoteFilter()
    /// The terminal should stay attached (until it shows another session or the session ends).
    @ObservationIgnored private var wantsAttached = false
    @ObservationIgnored private var reattach: Task<Void, Never>?
    @ObservationIgnored private var quickFailures = 0
    @ObservationIgnored private var gotEndNote = false
    @ObservationIgnored private var gotStartNote = false
    @ObservationIgnored private var channelOpened = Date.distantPast
    /// Which channel is this terminal's: a new round after every drop and when it lets go. Output and notes of an
    /// older channel (one that lingers after a reconnect) are ignored: they are not this terminal's any more.
    @ObservationIgnored private var round = 0
    /// The round an attach is under way for (only one at a time).
    @ObservationIgnored private var attaching: Int?
    /// What the Mac wrote before the session started (why it didn't, if it doesn't).
    @ObservationIgnored private var beforeStart = Data()

    init(id: Target, title: String, fontSize: CGFloat = TerminalFontSize.standard) {
        self.id = id
        self.title = title
        let size = TerminalFontSize.clamped(fontSize)
        self.fontSize = size
        view = AOSTerminalView(fontSize: size)
        bridge = Bridge(session: self)
        view.terminalDelegate = bridge
        view.interaction = self
        holderID = Self.storedHolderID(for: id)
    }

    var isActive: Bool { phase == .connecting || phase == .connected || phase == .reconnecting }

    private var holderKey: String { Self.holderKey(id) }
    private static func holderKey(_ target: Target) -> String { "terminal.session.\(target.key)" }

    /// The session the terminal showed last (also before it exists in this launch: for the list).
    static func storedHolderID(for target: Target) -> String? {
        UserDefaults.standard.string(forKey: holderKey(target)).flatMap { TermAttach.isID($0) ? $0 : nil }
    }

    private func setPhase(_ new: Phase) {
        guard phase != new else { return }
        phase = new
        if new == .connected, connectedSince == nil { connectedSince = Date() }
        if new == .ended || new == .idle { connectedSince = nil }
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
        // Attached already, or an attach for this round is under way (two would start two new sessions).
        guard wantsAttached, channel == nil, attaching != round else { return }
        reattach?.cancel()
        reattach = nil
        guard let mac = macConnection(), let ssh = mac.ssh, ssh.isActive else {
            setPhase(viewHasOutput ? .reconnecting : .connecting)
            waitForMac()
            return
        }
        if phase != .reconnecting { setPhase(.connecting) }
        let mine = round
        attaching = mine
        defer { if attaching == mine { attaching = nil } }
        do {
            let shell: SessionChannel
            if holdsSession {
                let command = TermAttach.attach(companion: mac.mac.companionPath, id: holderID,
                                                have: viewHasOutput ? received : nil, client: phoneID())
                shell = try await ssh.terminal(command: command, columns: max(size.columns, 20), rows: max(size.rows, 5))
            } else {
                shell = try await ssh.shell(columns: max(size.columns, 20), rows: max(size.rows, 5))
            }
            // The terminal let go meanwhile, or shows another session now.
            guard wantsAttached, mine == round, channel == nil else { await shell.close(); return }
            run(shell, held: holdsSession, round: mine)
        } catch {
            guard wantsAttached, mine == round else { return }
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

    /// Reads and writes the channel until it ends.
    private func run(_ shell: SessionChannel, held: Bool, round mine: Int) {
        stopWriting()
        channel = shell
        channelOpened = Date()
        gotEndNote = false
        gotStartNote = false
        beforeStart = Data()
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
                    guard let self, self.round == mine else { return }
                    if held { self.receive(chunk) } else { self.view.feed(byteArray: ArraySlice(chunk)) }
                }
                self?.channelEnded(nil, held: held, round: mine)
            } catch {
                self?.channelEnded(error, held: held, round: mine)
            }
        }
    }

    private func receive(_ chunk: Data) {
        for piece in filter.feed(chunk) {
            switch piece {
            case .bytes(let data):
                view.feed(byteArray: ArraySlice(data))
                received &+= UInt64(data.count)
                if !gotStartNote, beforeStart.count < 2048 { beforeStart.append(data.prefix(2048 - beforeStart.count)) }
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
            switch why {
            case "taken":
                // Another device: it shows the session now.
                gotEndNote = true
                endReason = .taken
                wantsAttached = false
            case "replaced":
                // This iPhone attached again over another connection (an older channel never gets here): this one
                // just goes, and the terminal attaches again if it still has to.
                break
            case "lost":
                // The session's process on the Mac went away: the next attach starts a new one.
                remember(holder: nil)
                viewHasOutput = false
            default:
                gotEndNote = true
                endReason = why == "exited" ? .exited : .ended
                wantsAttached = false
                remember(holder: nil)
                viewHasOutput = false
            }
        }
    }

    private func channelEnded(_ error: Error?, held: Bool, round mine: Int) {
        // An older channel ending is none of this terminal's business.
        guard mine == round else { return }
        channel = nil
        stopWriting()
        round += 1
        guard held else {
            if phase == .connected { setPhase(.ended) }
            view.feed(text: "\r\n")
            return
        }
        if gotEndNote {
            setPhase(.ended)
            return
        }
        if !gotStartNote, let failure = error as? SessionChannel.Failure, case .exited(let status, let message) = failure {
            // aOS on the Mac without terminal sessions (exit status 2: its usage), or not there (127): a plain shell.
            if status == 2 || status == 127 {
                log.notice("The Mac can't hold terminal sessions (status \(status)); using a plain shell")
                holdsSession = false
                show(status == 2 ? String(localized: "Update aOS on the Mac to keep this terminal when the connection drops.")
                                 : String(localized: "aOS isn't on the Mac where it was paired: this terminal ends with the connection."))
                Task { await attachToMac() }
                return
            }
            // The Mac said why it doesn't start one (too many sessions, for example): trying again won't help.
            if status == 1 {
                wantsAttached = false
                let said = message.isEmpty ? String(decoding: beforeStart, as: UTF8.self) : message
                let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
                setPhase(.failed(text.isEmpty ? String(localized: "The terminal on the Mac doesn't start.") : text))
                return
            }
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

    /// Lets go of the terminal: its channel closes. On the Mac the session keeps running; a plain shell ends.
    func disconnect() {
        wantsAttached = false
        round += 1
        reattach?.cancel()
        reattach = nil
        readTask?.cancel()
        readTask = nil
        let channel = self.channel
        self.channel = nil
        stopWriting()
        Task { await channel?.close() }
        if isActive { setPhase(holdsSession && holderID != nil ? .idle : .ended) }
    }

    /// Ends the shell on the Mac (SIGHUP, like closing a terminal window); a plain shell just closes.
    func endSession() async {
        guard holdsSession, let holderID else {
            disconnect()
            return
        }
        guard let mac = macConnection(), let ssh = mac.ssh, ssh.isActive,
              let command = TermAttach.end(companion: mac.mac.companionPath, id: holderID) else {
            show(String(localized: "The Mac isn't reachable right now. The session keeps running there."))
            return
        }
        let wanted = wantsAttached
        wantsAttached = false
        reattach?.cancel()
        guard (try? await ssh.run(command, timeout: .seconds(10))) != nil else {
            wantsAttached = wanted
            if wanted, channel == nil { waitForMac() }
            show(String(localized: "The Mac isn't reachable right now. The session keeps running there."))
            return
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

    /// Shows another session on the Mac (from the list); the one before keeps running there.
    func switchTo(session id: String) {
        guard TermAttach.isID(id), id != holderID || !isActive else { return }
        let same = id == holderID
        disconnect()
        remember(holder: id)
        // The same session again continues where the view is; another one starts afresh.
        if !same { viewHasOutput = false }
        holdsSession = true
        attachAgain()
    }

    /// Starts another shell on the Mac and shows it; the one before keeps running there.
    func startNewSession() {
        disconnect()
        forgetSession()
        holdsSession = true
        attachAgain()
    }

    /// Attaches from scratch: right away the terminal is "connecting" (so nothing else starts a second attach).
    private func attachAgain() {
        wantsAttached = true
        endReason = .closed
        quickFailures = 0
        setPhase(.connecting)
        Task { await attachToMac() }
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
