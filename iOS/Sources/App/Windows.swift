import SwiftUI
import UIKit

/// The app's windows. An iPhone shows the main window (the tabs). An iPad, and Stage Manager, can show more: terminal
/// windows, each with one of the Mac's terminal sessions. All windows share the app's model and its one connection to
/// the Mac; the sessions are channels in it, as the Terminal tab's is. Only one terminal of the app shows a session at
/// a time: opening it in another window takes it from the one that showed it (iOS/NOTES.md, "iPad and iPhone Duo").
enum SceneRole {
    static let mainWindowID = "main"
    static let terminalWindowID = "terminal"
}

/// What a terminal window opens with: one of the Mac's sessions, or a new one. Kept with the window, so a window
/// that comes back (after a relaunch) shows its session again.
struct TerminalWindowRequest: Codable, Hashable {
    /// The session on the Mac (its `term list` id); nil: a new session.
    var session: String?
    /// The window's own name (its terminal's): two windows for new sessions are two windows.
    var window = UUID()
}

/// A window of the main kind: the tabs, or a terminal window when another window shows the tabs already (an iPad's
/// "New Window" opens a terminal beside them).
struct SceneRoot: View {
    @Environment(AppModel.self) private var model
    /// The window's name, kept with it.
    @SceneStorage("aos.scene") private var scene = ""
    /// This window became a terminal window (also after it comes back).
    @SceneStorage("aos.scene.terminal") private var isTerminal = false

    var body: some View {
        Group {
            if scene.isEmpty {
                Color.clear
            } else if isTerminal {
                TerminalWindow(scene: scene, initialSession: nil)
            } else {
                RootView()
                    .background { WindowReader { model.mainWindow = $0 } }
            }
        }
        .onAppear {
            if scene.isEmpty { scene = UUID().uuidString }
            if !isTerminal, !model.claimMainScene(scene) { isTerminal = true }
        }
        .onDisappear { model.releaseMainScene(scene) }
    }
}

/// A terminal window: the Mac's terminal, its menu and key bar, without the tabs.
struct TerminalWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let scene: String
    let initialSession: String?

    init(scene: String, initialSession: String?) {
        self.scene = scene
        self.initialSession = initialSession
    }

    /// A window opened with `openWindow(id:value:)`.
    init(request: TerminalWindowRequest?) {
        let request = request ?? TerminalWindowRequest()
        self.init(scene: request.window.uuidString, initialSession: request.session)
    }

    /// The window's terminal, once made (when the window appears, not while drawing).
    private var terminal: TerminalSession? {
        model.activeMac.flatMap { model.terminals[.window(mac: $0.id, scene: scene)] }
    }

    var body: some View {
        NavigationStack {
            if let terminal {
                TerminalScreen(session: terminal, inOwnWindow: true)
                    .toolbar {
                        // The tabs' window was closed: one tap opens it again.
                        if model.mainScene == nil {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Show aOS", systemImage: "square.grid.2x2") {
                                    openWindow(id: SceneRole.mainWindowID)
                                }
                            }
                        }
                    }
            } else if model.activeMac == nil {
                ContentUnavailableView {
                    Label("No Mac yet", systemImage: "apple.terminal")
                } description: {
                    Text("Pair your Mac to open a terminal on it.")
                }
            }
        }
        .onAppear {
            if let mac = model.activeMac {
                _ = model.windowTerminal(mac: mac, scene: scene, initialSession: initialSession)
            }
        }
        // The agent's questions come up here while no window shows the tabs.
        .questionSheets(when: model.mainScene == nil)
        .lockCover()
        .onDisappear {
            if let mac = model.activeMac { model.closeTerminalWindow(.window(mac: mac.id, scene: scene)) }
        }
    }
}

/// Hands the UIKit window a SwiftUI view is in to `changed`, now and whenever the view moves to another window.
struct WindowReader: UIViewRepresentable {
    let changed: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.changed = changed
    }

    final class ReaderView: UIView {
        var changed: ((UIWindow?) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            changed?(window)
        }
    }
}

/// A window a view keeps without holding on to it (in `@State`).
final class WeakWindow {
    weak var window: UIWindow?
}

extension FocusedValues {
    /// The terminal on screen in the window in front (the Terminal menu's commands act on it).
    @Entry var terminalSession: TerminalSession?
}

/// The app's commands: in the iPad's menu bar and as shortcuts on a hardware keyboard (hold ⌘ to see them).
struct AOSCommands: Commands {
    let model: AppModel
    @FocusedValue(\.terminalSession) private var terminal
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal Window") {
                openWindow(id: SceneRole.terminalWindowID, value: TerminalWindowRequest())
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!model.isPaired)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.tab = .overview
                model.isSettingsPresented = true
            }
            .keyboardShortcut(",")
        }

        // The tabs. Not while a screen fills the window: its Mac gets ⌘1 and ⌘R then.
        CommandGroup(before: .sidebar) {
            Group {
            Section {
                Button("Overview") { model.tab = .overview }.keyboardShortcut("1")
                Button("Terminal") { model.tab = .terminal }.keyboardShortcut("2")
                Button("Screen") { model.tab = .screen }.keyboardShortcut("3")
            }
            Section {
                Button("Show the Workspace") {
                    model.screenTarget = .workspace
                    model.tab = .screen
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(!model.isPaired)
                Button("Show the Mac's Screen") {
                    model.screenTarget = .mac
                    model.tab = .screen
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(!model.isPaired)
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isPaired)
            }
            }
            .disabled(model.isScreenShown)
        }

        CommandMenu("Terminal") {
            Section {
                Button("New Session") {
                    if let terminal { model.startNewSession(in: terminal) } else { model.openNewTerminal() }
                }
                .keyboardShortcut("t")
                .disabled(!model.isPaired || (terminal == nil && model.isScreenShown))
            }
            // ⌘+, ⌘- and ⌘0 are the terminal's own keys (AOSTerminalView.keyCommands, with ⌘K)
            Section {
                Button("Bigger Text") { terminal?.adjustFontSize(by: 1) }
                Button("Smaller Text") { terminal?.adjustFontSize(by: -1) }
                Button("Default Text Size") { terminal?.adjustFontSize(to: TerminalFontSize.standard) }
            }
            .disabled(terminal == nil)
            Section {
                Button("Copy Screen") { terminal?.copyScreen() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Copy Last Output") { terminal?.copyLastOutput() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(terminal?.keyboardShown == true ? "Hide Keyboard" : "Show Keyboard") { terminal?.toggleKeyboard() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
            }
            .disabled(terminal == nil)
        }
    }
}
