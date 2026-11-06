import SwiftUI

@main
struct AnnexApp: App {
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
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(to: phase) }
        }
    }
}

/// The tabs, the sheets that can come up anywhere (sign-in requests, pairing) and the lock.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Overview", systemImage: "square.grid.2x2", value: AppModel.Tab.overview) {
                OverviewView()
            }
            .badge(model.signIns.count + model.helpRequests.count)
            Tab("Terminal", systemImage: "apple.terminal", value: AppModel.Tab.terminal) {
                TerminalTab()
            }
            Tab("Screen", systemImage: "display", value: AppModel.Tab.screen) {
                ScreenTab()
            }
            Tab("Vault", systemImage: "key.horizontal", value: AppModel.Tab.vault) {
                VaultTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // No requests and no pairing above the lock screen
        // The sheet goes away while the app is locked and comes back after unlocking; that isn't "Later".
        .sheet(item: Binding(get: { model.lock.isLocked ? nil : model.presentedSignIn },
                             set: { request in
                                 if let request { model.presentedSignIn = request } else if !model.lock.isLocked { model.closeSignInSheet() }
                             })) { request in
            SignInSheet(request: request)
        }
        .sheet(isPresented: unlockedBinding($model.isPairingPresented)) {
            PairingView(initialLink: model.incomingPairingLink)
                .onDisappear { model.incomingPairingLink = nil }
        }
        .overlay {
            if model.lock.isLocked {
                LockView().transition(.opacity)
            } else if scenePhase != .active && (model.settings.requireUnlock || model.tab == .vault) {
                // Nothing secret in the app switcher
                PrivacyCover()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.lock.isLocked)
        // Last, so sheets and overlays get the brand color too
        .tint(BrandColor.indigo)
    }

    private func unlockedBinding<T>(_ binding: Binding<T?>) -> Binding<T?> {
        Binding(get: { model.lock.isLocked ? nil : binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }

    private func unlockedBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !model.lock.isLocked && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
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
