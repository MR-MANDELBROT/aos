import ScreenClient
import SwiftUI
import UIKit

/// The app delegate. A screen session turns the iPhone to its picture and holds it there (the Mac's screen in
/// landscape), as in Open Screen Sharing; otherwise the iPhone turns as it likes.
final class AOSAppDelegate: NSObject, UIApplicationDelegate {
    // TODO: Modernization - Consider adopting `prefersInterfaceOrientationLocked` (iOS 26+) as the modern replacement
    // for orientation locking via `supportedInterfaceOrientations`. Here the session turns the iPhone to its picture
    // (a request for one orientation, Open Screen Sharing's SessionOrientation), which a lock to the current one
    // doesn't express; on an iPad in a window, or a Mac's picture in the window's shape, nothing is locked.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ScreenClient.supportedOrientations(for: window?.windowScene)
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TerminalWindows.watch()
        return true
    }

    /// A window was closed for good: a terminal window's kept session id goes with it (Windows.swift).
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        for session in sceneSessions { TerminalWindows.discarded(session) }
    }
}

extension Scene {
    /// The screen session's menu commands (shortcuts on a hardware keyboard).
    func screenCommands() -> some Scene {
        commands { ScreenCommands() }
    }
}
