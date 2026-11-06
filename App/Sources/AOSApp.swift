import AOSKit
import SwiftUI

@main
struct AOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.power)
        } label: {
            // The label is the one view that exists from launch on: it hands over the openers.
            Image(systemName: model.menuSymbol)
                .accessibilityLabel(Brand.name)
                .registersOpeners(note: "menu bar")
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Welcome to \(Brand.name)"), id: WindowID.setup) {
            SetupView()
                .registersOpeners()
                .environmentObject(model)
                .environmentObject(model.setup)
                .environmentObject(model.power)
        }
        .defaultSize(width: 920, height: 660)
        .windowResizability(.contentMinSize)
        // Until the setup is done, it opens at launch.
        .defaultLaunchBehavior(model.setup.isComplete ? .suppressed : .presented)

        Window(Text("Workspace"), id: WindowID.workspace) {
            WorkspaceWindow()
                .registersOpeners()
                .environmentObject(model)
                .environmentObject(model.setup)
        }
        .defaultSize(width: 1280, height: 860)

        Window(Text("Session"), id: WindowID.session) {
            SessionWindow()
                .registersOpeners()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 640)

        Window(Text("Approve"), id: WindowID.approval) {
            ApprovalView()
                .registersOpeners()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        Window(Text("Sign In"), id: WindowID.signIn) {
            SignInView()
                .registersOpeners()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        Settings {
            SettingsView()
                .registersOpeners()
                .environmentObject(model)
                .environmentObject(model.power)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Every window hands the model SwiftUI's openers, so buttons and aos:// links work before the menu bar panel was
/// ever opened (during the first setup it usually wasn't).
struct RegistersOpeners: ViewModifier {
    var note: String?
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            model.openWindow = { openWindow(id: $0) }
            model.openSettingsAction = { openSettings() }
            if let note, !model.openersNoted {
                model.openersNoted = true
                model.append("window openers ready (\(note))")
            }
        }
    }
}

extension View {
    func registersOpeners(note: String? = nil) -> some View { modifier(RegistersOpeners(note: note)) }
}

enum WindowID {
    static let setup = "setup"
    static let workspace = "workspace"
    static let session = "session"
    static let approval = "approval"
    static let signIn = "signin"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerMoveToApplications() { return }
        Task { @MainActor in AppModel.shared.launched() }
    }

    /// aOS opened outside an Applications folder (on its disk image, in Downloads): it registers its programs by
    /// path, so it offers to move itself first. True when it moved and is about to open again from there.
    @MainActor private func offerMoveToApplications() -> Bool {
        let app = Bundle.main.bundleURL
        guard !AppLocation.isStable(app), !AppLocation.isDevelopmentBuild(app) else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move aOS to the Applications folder?")
        alert.informativeText = String(localized: "aOS keeps working in the background and registers itself with your agents and your iPhone. For that it needs a fixed place. It copies itself there and opens again.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let move = try AppLocation.moveToApplications(app)
            AppLocation.relaunch(move)
            NSApp.terminate(nil)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Close the workspace in order before quitting (shutdown or suspend), then quit.
        Task { @MainActor in
            await AppModel.shared.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { AppModel.shared.handle(url: $0) } }
    }
}
