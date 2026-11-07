import ScreenClient
import SwiftUI
import UIKit

/// The app delegate. A screen session turns the iPhone to its picture and holds it there (the Mac's screen in
/// landscape), as in Open Screen Sharing; otherwise the iPhone turns as it likes.
final class AOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ScreenClient.supportedOrientations(for: window?.windowScene)
    }
}

extension Scene {
    /// The screen session's menu commands (shortcuts on a hardware keyboard).
    func screenCommands() -> some Scene {
        commands { ScreenCommands() }
    }
}
