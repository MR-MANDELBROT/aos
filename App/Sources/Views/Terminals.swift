import AOSKit
import AppKit
import SwiftTerm
import SwiftUI

/// Runs one shell command visibly in a terminal (installing Claude Code, signing in, the session's first start).
/// The user sees exactly what the command prints and answers its questions themselves.
struct CommandTerminal: NSViewRepresentable {
    let command: String
    var directory: URL?
    var onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
        view.processDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let dir = directory?.path ?? home
        let script = "cd \(shellQuote(dir)) && \(command)"
        view.startProcess(executable: "/bin/zsh", args: ["-l", "-c", script],
                          environment: env.map { "\($0.key)=\($0.value)" }, execName: "zsh")
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onExit(exitCode) }
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// The running Claude Code session, attached through the supervisor's relay socket.
struct SessionTerminal: NSViewRepresentable {
    let socketURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view: view, socket: socketURL)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var socket: RawSocket?
        weak var view: TerminalView?

        func attach(view: TerminalView, socket url: URL) {
            self.view = view
            do {
                let s = try RawSocket(path: url)
                s.receive({ [weak self] data in
                    MainActor.assumeIsolated {
                        self?.view?.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                }, onClose: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.view?.feed(text: "\r\n[\(Brand.name): the session ended; it restarts by itself]\r\n")
                    }
                })
                socket = s
            } catch {
                view.feed(text: "The session is not running yet.\r\n")
            }
        }

        func detach() { socket?.close(); socket = nil }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { socket?.send(Data(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), url.scheme == "https" { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
