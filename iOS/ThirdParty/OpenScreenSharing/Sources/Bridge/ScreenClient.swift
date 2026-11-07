// aOS's interface to the screen client: Open Screen Sharing's session engine and session UI in this module (GPL-3.0,
// iOS/ThirdParty/OpenScreenSharing/LICENSE). Written for aOS on 2026-11-07; the rest of the module is Open Screen
// Sharing's code with aOS's changes marked "aOS:".

import Perception
import SwiftUI
import UIKit

/// The few things aOS needs from the module besides a session.
public enum ScreenClient {
    /// What the app delegate answers for `supportedInterfaceOrientationsFor`: a session turns the iPhone to its
    /// picture (the Mac's screen in landscape), as in Open Screen Sharing.
    public static func supportedOrientations(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        SessionOrientation.supportedOrientations(for: scene)
    }

    /// The screen's settings and what it remembers per screen stay in memory only (aOS's demo and its tests). Call
    /// before the first session or settings page.
    public static func useMemoryStore() {
        AppDatabase.keepsInMemory = true
    }

    /// What the screen remembers for one screen (quality, clipboard, the screen sharing key it trusts), forgotten
    /// when aOS forgets the Mac.
    public static func forget(screen id: UUID) {
        try? ComputerStore.shared.delete(id)
    }

    /// Open Screen Sharing's source code.
    public static var sourceCode: URL { URL(string: "https://github.com/nekohasekai/open-screen-sharing")! }

    /// Open Screen Sharing's license notice (its LICENSE file) and the GNU General Public License, version 3.
    public static var licenseNotice: String { resource("LICENSE") }
    public static var licenseText: String { resource("COPYING") }

    private final class Marker {}

    private static func resource(_ name: String) -> String {
        guard let url = Bundle(for: Marker.self).url(forResource: name, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

/// How a session signs in.
nonisolated public enum ScreenLogin: Sendable, Equatable {
    /// A macOS account (screen sharing's account login).
    case account(username: String, password: String)
    /// No login at all: aOS's demo and its tests (a server without authentication).
    case none

    var credentials: SessionCredentials {
        switch self {
        case .account(let username, let password): .account(username: username, password: password)
        case .none: .noAuthentication
        }
    }
}

/// One screen session: Open Screen Sharing's `SessionController` for a screen aOS reaches through its SSH tunnel
/// (127.0.0.1 and the forwarded port). High performance (UDP) is off; the login comes from aOS and is never kept.
@MainActor
public final class ScreenClientSession: Identifiable {
    nonisolated public enum State: Equatable, Sendable {
        case connecting
        case connected
        case reconnecting
        case failed(String)
        case ended
    }

    public let id = UUID()
    let controller: SessionController

    /// - Parameters:
    ///   - screen: which screen this is (what the session remembers is kept per screen: quality, clipboard, trusted key)
    ///   - followsWindowShape: the screen takes the iPhone's shape (aOS's display request), so the iPhone isn't turned
    ///     to the picture's orientation.
    public init(screen: UUID, name: String, host: String = "127.0.0.1", port: Int, login: ScreenLogin,
                followsWindowShape: Bool) {
        ScreenClientSession.prepare(screen: screen, name: name)
        controller = SessionController(route: SessionRoute(computerID: screen, name: name, host: host, port: port,
                                                           credentials: login.credentials,
                                                           followsWindowShape: followsWindowShape))
    }

    /// The screen's record in the store (what a session remembers per screen goes there), made once.
    private static func prepare(screen: UUID, name: String) {
        let store = ComputerStore.shared
        guard store.computer(screen) == nil else { return }
        var computer = Computer(name: name, address: ComputerAddress(host: "127.0.0.1"))
        computer.id = screen
        _ = try? store.save(computer) { _ in }
    }

    public var state: State {
        switch controller.phase {
        case .idle, .connecting, .authenticating, .waitingForPermission, .choosingSession, .preparingCursors: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .failed(let failure): .failed(failure.message)
        case .disconnected: .ended
        }
    }

    /// A picture is on the screen.
    public var hasPicture: Bool { controller.hasPicture }
    /// The picture's size in its pixels (zero before the first one).
    public var pictureSize: CGSize { controller.imageSize }
    /// The server is a Mac with Apple's screen sharing (not a plain VNC server).
    public var speaksApple: Bool { controller.info.dialect == .apple }

    /// The area the picture is shown in (points) and the screen's scale, whenever it changes.
    public var onDisplayArea: ((CGSize, CGFloat) -> Void)? {
        get { controller.onDisplayArea }
        set { controller.onDisplayArea = newValue }
    }

    /// The screen refused the login; aOS ends the session and asks for a new one. Without it, the session shows the
    /// failure as Open Screen Sharing does.
    public var onLoginRefused: (() -> Void)? {
        didSet {
            let handler = onLoginRefused
            controller.onLoginRefused = handler.map { handler in { _ in handler() } }
        }
    }

    /// Ends the session (the view calls this too, from its close button).
    public func close() {
        controller.close()
    }

    /// Zooms onto a region of the picture (its pixels), as for a help request.
    public func focus(on region: CGRect) {
        controller.screen?.focus(on: region)
    }

    /// Connects without a view (tests): the view does this when it appears.
    public func start() {
        controller.start()
    }
}

/// The session's full screen view: Open Screen Sharing's `SessionView` (picture, toolbar, menus, keyboard bar,
/// status) as in its iPhone app, and its tips the first time.
public struct ScreenClientView: View {
    private let session: ScreenClientSession
    private let onClose: () -> Void
    @State private var tutorials = SessionTutorial.unseen

    /// `onClose`: the session ended from its toolbar or after a failure (it is closed already).
    public init(session: ScreenClientSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }

    public var body: some View {
        SessionView(controller: session.controller, hasOwnWindow: false, onClose: onClose)
            .overlay {
                if !tutorials.isEmpty {
                    SessionTutorialView(pages: tutorials) { tutorials = [] }
                }
            }
            .modifier(StorageNoticeAlert())
    }
}

/// The screen's settings page (Open Screen Sharing's settings: general, keyboard, control, about), with aOS's own rows
/// on top.
public struct ScreenClientSettings<Extra: View>: View {
    private let extra: Extra

    public init(@ViewBuilder extra: () -> Extra) {
        self.extra = extra()
    }

    public var body: some View {
        SettingsView { extra }
            .modifier(StorageNoticeAlert())
    }
}

/// The session's menu commands (hardware keyboard shortcuts), as in Open Screen Sharing.
public struct ScreenCommands: Commands {
    public init() {}

    public var body: some Commands {
        AppCommands()
    }
}
