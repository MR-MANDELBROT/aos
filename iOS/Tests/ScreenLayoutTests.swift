import SwiftUI
import Testing
import UIKit
@testable import aOS
@testable import ScreenClient

/// The session on the Screen tab, upright in the iPhone's shape (the demo's workspace, the app's real views in a
/// window): the picture and Open Screen Sharing's toolbar below the Dynamic Island.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ScreenLayoutTests {
    /// The app's root view with the demo in a window of its own, the workspace's session on screen.
    private func showWorkspace(_ model: AppModel) async throws -> (UIWindow, SessionController, RemoteScreenUIView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RootView().environment(model))
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .seconds(1.5))
        model.screenTarget = .workspace
        model.tab = .screen
        try await waitUntil(timeout: .seconds(30)) { model.workspaceScreen.client?.hasPicture == true }
        try? await Task.sleep(for: .seconds(1))
        let controller = try #require(model.workspaceScreen.client?.controller)
        return (window, controller, try #require(controller.screen))
    }

    @Test func thePictureAndTheToolbarStayBelowTheDynamicIsland() async throws {
        let model = AppModel(isDemo: true)
        let (window, controller, screen) = try await showWorkspace(model)
        defer {
            model.workspaceScreen.stop()
            window.isHidden = true
        }
        let top = window.safeAreaInsets.top
        try #require(top > 20, "an iPhone with a Dynamic Island or a notch, upright")
        // The picture fills the window below the top safe area (the display has that shape).
        #expect(abs(screen.imageRect.minY - top) < 1)
        #expect(abs(screen.imageRect.maxY - window.bounds.maxY) < 1)
        // The toolbar's handle starts at the picture's top edge, not behind the Dynamic Island.
        let handle = try #require(controller.toolbarHandleFrame)
        #expect(handle.minY >= top - 0.5)
        // Open, its bar comes below the handle: the top of the picture (the Mac's menu bar) stays free.
        controller.toggleToolbar()
        try await waitUntil { controller.toolbarBarFrame != nil }
        try? await Task.sleep(for: .milliseconds(500))
        let bar = try #require(controller.toolbarBarFrame)
        #expect(bar.minY >= handle.maxY - 0.5)
    }
}
