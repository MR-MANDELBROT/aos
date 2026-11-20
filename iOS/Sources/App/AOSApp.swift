import SwiftUI

@main
struct AOSApp: App {
    @UIApplicationDelegateAdaptor(AOSAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        _model = State(initialValue: AppModel(isDemo: Demo.isRequested))
        #else
        _model = State(initialValue: AppModel())
        #endif
    }

    var body: some Scene {
        // The main window (an iPad opens more of them from the system's "New Window": each further one is a terminal
        // window, SceneRoot). One model and one connection to the Mac for all windows.
        WindowGroup(id: SceneRole.mainWindowID) {
            SceneRoot()
                .environment(model)
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(to: phase) }
        }
        .screenCommands()
        .commands { AOSCommands(model: model) }

        // A terminal window: one of the Mac's sessions (the value: its id, or none for a new one), on the iPad beside
        // the main window or another terminal. Opened from the Terminal tab's list or with New Terminal Window.
        WindowGroup("Terminal", id: SceneRole.terminalWindowID, for: TerminalWindowRequest.self) { $request in
            TerminalWindow(request: request)
                .environment(model)
                .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(to: phase) }
        }
    }
}

/// The tabs, the sheets that can come up anywhere (sign-in requests, pairing) and the lock.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppModel.Tab.overview) {
                OverviewView()
            }
            .badge(model.waitingCount)
            Tab("Terminal", systemImage: "apple.terminal", value: AppModel.Tab.terminal) {
                TerminalTab()
            }
            Tab("Screen", systemImage: "display", value: AppModel.Tab.screen) {
                // Only while it is the tab on screen. Behind the others it started the screen by itself when the Mac
                // or the workspace came back (after a reload, say), and its full screen took the tab bar away from
                // the tab on screen (TabBarTests).
                if model.tab == .screen {
                    ScreenTab()
                } else {
                    Color.clear
                }
            }
        }
        // A tab bar on an iPhone and in a narrow window; on an iPad the tabs can become a sidebar.
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .questionSheets()
        .sheet(isPresented: unlockedBinding($model.isPairingPresented)) {
            PairingView(initialLink: model.incomingPairingLink)
                .onDisappear { model.incomingPairingLink = nil }
                .presentationSizing(.form)
        }
        .lockCover()
    }

    private func unlockedBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !model.lock.isLocked && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }
}

extension View {
    /// Questions from the agent (sign-ins, approvals) as a form sheet. They go away while the app is locked and come
    /// back after unlocking; that isn't "Later".
    func questionSheets(when isEnabled: Bool = true) -> some View { modifier(QuestionSheets(isEnabled: isEnabled)) }

    /// The lock above everything, and a cover in the app switcher (nothing secret there). Every window has it.
    func lockCover() -> some View { modifier(LockCover()) }
}

private struct QuestionSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Only one window shows them (the main window, or a terminal window while there is none).
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.lock.isLocked || !isEnabled ? nil : model.presentedQuestion },
                                 set: { question in
                                     if let question { model.present(question) } else if !model.lock.isLocked, isEnabled { model.closeQuestionSheet() }
                                 })) { question in
                Group {
                    switch question {
                    case .signIn(let request): SignInSheet(request: request)
                    case .approval(let request): ApprovalSheet(request: request)
                    }
                }
                // A form sheet in the middle of an iPad's window; the usual sheet on an iPhone
                .presentationSizing(.form)
            }
    }
}

private struct LockCover: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.lock.isLocked {
                    LockView().transition(.opacity)
                } else if scenePhase != .active && model.settings.requireUnlock {
                    // Nothing secret in the app switcher
                    PrivacyCover()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.lock.isLocked)
            // Last, so sheets and overlays get the brand color too
            .tint(BrandColor.indigo)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            AppIconImage(size: 72)
        }
    }
}
