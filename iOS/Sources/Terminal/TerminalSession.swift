import Foundation
import Observation
import SwiftTerm
import UIKit

/// One terminal: a login shell in a pseudo terminal over SSH, shown by SwiftTerm. The terminal view lives here, so
/// its contents survive leaving the screen and coming back.
@MainActor @Observable
final class TerminalSession: Identifiable, TerminalInteractionDelegate {
    enum Target: Hashable, Sendable {
        case mac(UUID)
        case host(UUID)
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case ended
        case failed(String)
        /// First connection to an added host: the person checks the key and trusts it.
        case confirmHostKey(host: String, key: String, fingerprint: String)
        /// The host presents another key than the one trusted before.
        case hostKeyChanged(host: String, fingerprint: String)
    }

    /// A short message over the terminal ("Copied", the font size while pinching).
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    let id: Target
    var title: String
    private(set) var phase: Phase = .idle
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

    init(id: Target, title: String, fontSize: CGFloat = TerminalFontSize.standard) {
        self.id = id
        self.title = title
        let size = TerminalFontSize.clamped(fontSize)
        self.fontSize = size
        view = AOSTerminalView(fontSize: size)
        bridge = Bridge(session: self)
        view.terminalDelegate = bridge
        view.interaction = self
    }

    var isActive: Bool { phase == .connecting || phase == .connected }

    // MARK: Connecting

    /// A shell on the paired Mac, in the app's existing SSH connection.
    func connect(mac: MacConnection) async {
        guard let ssh = mac.ssh, ssh.isActive else {
            phase = .failed(String(localized: "Not connected to the Mac."))
            return
        }
        await open(on: ssh)
    }

    /// A shell on an added host, in a connection of its own.
    func connect(host: SSHHost, key: DeviceKey?, password: String?) async {
        disconnect()
        phase = .connecting
        let policy: HostKeyPolicy = host.hostKey.map { .pinned($0) } ?? .askFirst
        do {
            let connection = try await SSHConnection.connect(
                hosts: [host.host], port: Int(host.port),
                login: SSHLogin(username: host.user, key: host.auth == .deviceKey ? key : nil,
                                password: host.auth == .password ? password : nil),
                hostKey: policy, perHostTimeout: 10)
            ownConnection = connection
            await open(on: connection)
        } catch SSHConnectError.unknownHostKey(let h, let key, let fingerprint) {
            phase = .confirmHostKey(host: h, key: key, fingerprint: fingerprint)
        } catch SSHConnectError.hostKeyMismatch(let h, let fingerprint) {
            phase = .hostKeyChanged(host: h, fingerprint: fingerprint)
        } catch SSHConnectError.authenticationFailed {
            phase = .failed(host.auth == .password
                ? String(localized: "\(host.host) didn't accept the user name or password.")
                : String(localized: "\(host.host) didn't accept this iPhone's key. Add the key to ~/.ssh/authorized_keys there (Settings > This iPhone)."))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func open(on connection: SSHConnection) async {
        phase = .connecting
        do {
            let shell = try await connection.shell(columns: max(size.columns, 20), rows: max(size.rows, 5))
            channel = shell
            let (input, writer) = AsyncStream<Data>.makeStream()
            self.writer = writer
            writeTask = Task {
                for await data in input { try? await shell.write(data) }
            }
            phase = .connected
            readTask = Task { [weak self] in
                do {
                    for try await chunk in shell.output {
                        self?.view.feed(byteArray: ArraySlice(chunk))
                    }
                    self?.ended()
                } catch {
                    self?.ended(error)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func ended(_ error: Error? = nil) {
        channel = nil
        stopWriting()
        if let ownConnection { Task { await ownConnection.close() } }
        ownConnection = nil
        if case .connected = phase { phase = .ended }
        view.feed(text: "\r\n")
    }

    func disconnect() {
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
        if isActive { phase = .ended }
    }

    /// Shows sample output (the demo).
    func showDemo(_ text: String) {
        phase = .connected
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
            try? await Task.sleep(for: .seconds(1.6))
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
