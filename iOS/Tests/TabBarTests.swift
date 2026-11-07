import SwiftUI
import Testing
import UIKit
@testable import aOS

/// The tab bar: the terminal and the screen in full screen take it while they are shown, and only then. On the
/// iPhone it was gone after a reload: the Screen tab, alive behind the others, started its screen when the Mac came
/// back, and its full screen hid the tab bar of the tab on screen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TabBarTests {
    /// The app's root view with the demo, in a window of its own.
    private func show(_ model: AppModel) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RootView().environment(model))
        window.makeKeyAndVisible()
        return window
    }

    private func tabBarController(in window: UIWindow) -> UITabBarController? {
        func find(_ controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(window.rootViewController)
    }

    private func hidden(_ tabs: UITabBarController) -> Bool {
        tabs.isTabBarHidden || tabs.tabBar.isHidden || tabs.tabBar.alpha < 0.01
    }

    private func settle(_ seconds: Double = 1) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func theScreenStartingBehindAnotherTabLeavesItsTabBar() async throws {
        let model = AppModel(isDemo: true)
        let window = try show(model)
        defer {
            model.workspaceScreen.stop()
            window.isHidden = true
        }
        await settle(1.5)
        let tabs = try #require(tabBarController(in: window))
        #expect(!hidden(tabs))

        // The Screen tab once, as the Overview's "Show the screen" opens it: the demo's workspace in full screen,
        // without the tab bar.
        model.screenTarget = .workspace
        model.tab = .screen
        try await waitUntil { model.workspaceScreen.phase == .running }
        await settle()
        #expect(hidden(tabs), "full screen")
        model.tab = .overview
        await settle()
        #expect(!hidden(tabs), "back on the Overview")

        // The screen starts again while the Overview is shown, as the Screen tab did by itself when the Mac or the
        // workspace came back.
        let picture = try #require(Demo.workspacePicture(fitting: window.bounds.size))
        let session = model.workspaceScreen
        Task { await session.startDemo(picture, name: "Workspace", screenID: UUID()) }
        try await waitUntil { session.phase == .running }
        await settle(1.5)
        #expect(!hidden(tabs), "the Overview keeps its tab bar")
        model.workspaceScreen.stop()
        await settle()
        #expect(!hidden(tabs))
    }

    @Test func aTerminalLeftForAnotherTabLeavesItsTabBar() async throws {
        let model = AppModel(isDemo: true)
        let window = try show(model)
        defer { window.isHidden = true }
        await settle(1.5)
        let tabs = try #require(tabBarController(in: window))
        let mac = try #require(model.activeMac)

        model.tab = .terminal
        await settle()
        model.openTerminal = .mac(mac.id)
        await settle(1.5)
        #expect(hidden(tabs), "the terminal takes the rows of the tab bar")
        // Another tab from the app itself (a help request, the Overview's Open Terminal elsewhere): its tab bar is there.
        model.tab = .overview
        await settle()
        #expect(!hidden(tabs))
        model.tab = .screen
        await settle(2)
        model.workspaceScreen.stop()
        await settle()
        #expect(!hidden(tabs), "the Screen tab's own page")
    }
}
