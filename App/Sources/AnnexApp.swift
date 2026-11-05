import AnnexKit
import SwiftUI

@main
struct AnnexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
                .accessibilityLabel(Brand.name)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Welcome to \(Brand.name)"), id: WindowID.setup) {
            SetupView()
                .environmentObject(model)
                .environmentObject(model.setup)
        }
        .defaultSize(width: 920, height: 660)
        .windowResizability(.contentMinSize)
        // Until the setup is done, it opens at launch.
        .defaultLaunchBehavior(model.setup.isComplete ? .suppressed : .presented)

        Window(Text("Workspace"), id: WindowID.workspace) {
            WorkspaceWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 860)

        Window(Text("Session"), id: WindowID.session) {
            SessionWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 640)

        Window(Text("Approve"), id: WindowID.approval) {
            ApprovalView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

enum WindowID {
    static let setup = "setup"
    static let workspace = "workspace"
    static let session = "session"
    static let approval = "approval"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.launched() }
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
}
