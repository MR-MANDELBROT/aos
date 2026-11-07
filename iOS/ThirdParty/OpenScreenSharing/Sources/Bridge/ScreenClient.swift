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

    /// What the selection view shows of a screen besides its picture, from what its sessions recorded.
    public static func record(of screen: UUID) -> ScreenRecord? {
        guard let computer = ComputerStore.shared.computer(screen) else { return nil }
        return ScreenRecord(model: computer.model, enclosureColor: computer.enclosureColor,
                            lastConnected: computer.lastConnected, knowsServerKey: !computer.trustedFingerprint.isEmpty,
                            lastConnectedText: computer.lastConnected == nil ? nil : computer.detailText)
    }

    /// Open Screen Sharing's resolutions (1x to 2x in quarter steps) and their names ("Native", "1.5x").
    nonisolated public static var resolutionScales: [Double] { VirtualDisplayMode.resolutionScales }
    nonisolated public static let defaultResolutionScale = VirtualDisplayMode.defaultResolutionScale
    public static func resolutionTitle(_ scale: Double) -> String { resolutionScaleTitle(scale) }

    /// The display a screen gets in the shape of `area` (points), as Open Screen Sharing sizes the Mac's virtual
    /// display: the same shape, at least 800 by 525 points, times the resolution scale, two pixels per point on a
    /// Retina screen. aOS sizes the workspace's display the same way.
    nonisolated public static func displaySize(fitting area: CGSize, screenScale: CGFloat, resolutionScale: Double)
        -> ScreenDisplaySize?
    {
        VirtualDisplayMode(matching: area, screenScale: screenScale, resolutionScale: resolutionScale)
            .map { ScreenDisplaySize(width: $0.width, height: $0.height, density: $0.density) }
    }

    /// Signs in once without a session (Open Screen Sharing's setup check) and keeps the screen sharing key the screen
    /// showed: through aOS's SSH tunnel, so a later direct connection can be checked against it. Also tells whether
    /// the Mac offers high performance.
    public static func checkServer(screen: UUID, name: String, host: String = "127.0.0.1", port: Int,
                                   login: ScreenLogin) async -> ScreenServerCheck {
        ScreenClientSession.prepare(screen: screen, name: name, sharesClipboard: true)
        let trusted = ComputerStore.shared.computer(screen)?.trustedFingerprint ?? ""
        let server = ProbedServer(
            address: ComputerAddress(host: host, port: port), remoteProtocol: .vnc,
            authentication: ServerAuthentication(account: true, requestPermission: false, vncPassword: false,
                                                 noPassword: false, grantsRequests: false),
            fingerprint: trusted)
        switch await ServerProber.checkLogin(server, credentials: login.credentials) {
        case .success(let check):
            if !check.fingerprint.isEmpty { try? ComputerStore.shared.setTrustedFingerprint(check.fingerprint, for: screen) }
            return .ok(highPerformance: check.supportsHighPerformance, knowsServerKey: !check.fingerprint.isEmpty)
        case .failure(let failure):
            return failure.kind == .authenticationFailed ? .loginRefused : .failed(failure.message)
        }
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

/// What a screen's sessions recorded: the device's look (the model the screen reported), when it was last
/// connected, whether its screen sharing key is known.
nonisolated public struct ScreenRecord: Sendable, Equatable {
    public var model: String
    public var enclosureColor: String
    public var lastConnected: Date?
    public var knowsServerKey: Bool
    /// "Last connected 5 minutes ago", as Open Screen Sharing's cards say it.
    public var lastConnectedText: String?
}

/// A display size in points and its pixels per point (1 or 2).
nonisolated public struct ScreenDisplaySize: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var density: Int
    public var pixelWidth: Int { width * density }
    public var pixelHeight: Int { height * density }

    public init(width: Int, height: Int, density: Int) {
        self.width = width
        self.height = height
        self.density = density
    }
}

/// What `ScreenClient.checkServer` found.
nonisolated public enum ScreenServerCheck: Sendable, Equatable {
    case ok(highPerformance: Bool, knowsServerKey: Bool)
    case loginRefused
    case failed(String)
}

/// How the picture reaches the iPhone on aOS's direct path to the Mac: high performance (UDP), tuned for the network
/// (Open Screen Sharing's "Network Quality").
nonisolated public enum ScreenNetwork: Sendable, Equatable {
    /// The same local network: four bands, 4:4:4, 60 frames a second.
    case localNetwork
    /// Through the internet (a tailnet): one band, 4:2:0, Open Screen Sharing's CoreDevice mode.
    case internet

    var quality: NetworkQuality { self == .localNetwork ? .localNetwork : .internet }
}

/// The area a session shows its picture in: points, the screen's scale, the resolution scale.
nonisolated public struct ScreenArea: Sendable, Equatable {
    public var points: CGSize
    public var screenScale: CGFloat
    public var resolutionScale: Double

    public init(points: CGSize, screenScale: CGFloat, resolutionScale: Double) {
        self.points = points
        self.screenScale = screenScale
        self.resolutionScale = resolutionScale
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
/// (127.0.0.1 and the forwarded port, standard mode), or the Mac on aOS's direct path (its address on the network,
/// high performance with the virtual display). The login comes from aOS and is never kept.
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
    ///   - sharesClipboard: whether "Sync Clipboard" starts on for this screen (afterwards the person's choice in the
    ///     session's menu is remembered). Off for the workspace: what the iPhone copies (a password, a code) shouldn't
    ///     reach the agent's Mac unasked.
    ///   - highPerformance: aOS's direct path to the Mac: high performance and the virtual display in the window's
    ///     shape, tuned for this network. Nil: standard mode (the SSH tunnel carries TCP only).
    ///   - resolutionScale: the resolution the virtual display (or the workspace's display) starts with.
    public init(screen: UUID, name: String, host: String = "127.0.0.1", port: Int, login: ScreenLogin,
                followsWindowShape: Bool, sharesClipboard: Bool = true, highPerformance: ScreenNetwork? = nil,
                resolutionScale: Double = ScreenClient.defaultResolutionScale) {
        ScreenClientSession.prepare(screen: screen, name: name, sharesClipboard: sharesClipboard)
        // What Open Screen Sharing reads from the store when the session starts: high performance and its network,
        // the resolution (aOS's one setting for all screens).
        var record = Computer(name: name, address: ComputerAddress(host: "127.0.0.1"))
        record.id = screen
        _ = try? ComputerStore.shared.save(record) {
            $0.usesHighPerformance = highPerformance != nil
            $0.networkQuality = highPerformance?.quality ?? .localNetwork
            $0.resolutionScale = resolutionScale
        }
        controller = SessionController(route: SessionRoute(computerID: screen, name: name, host: host, port: port,
                                                           credentials: login.credentials,
                                                           followsWindowShape: followsWindowShape,
                                                           usesHighPerformance: highPerformance != nil))
    }

    /// The screen's record in the store (what a session remembers per screen goes there), made once.
    static func prepare(screen: UUID, name: String, sharesClipboard: Bool) {
        let store = ComputerStore.shared
        guard store.computer(screen) == nil else { return }
        var computer = Computer(name: name, address: ComputerAddress(host: "127.0.0.1"))
        computer.id = screen
        computer.sharesClipboard = sharesClipboard
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
    /// The session waits for the person or the Mac to decide (which session to share, a permission).
    public var waitsForPerson: Bool {
        switch controller.phase {
        case .waitingForPermission, .choosingSession: true
        default: controller.credentialPrompt != nil
        }
    }
    /// The picture's size in its pixels (zero before the first one).
    public var pictureSize: CGSize { controller.imageSize }
    /// The server is a Mac with Apple's screen sharing (not a plain VNC server).
    public var speaksApple: Bool { controller.info.dialect == .apple }
    /// "Sync Clipboard" is on.
    public var sharesClipboard: Bool { controller.clipboardSharing }
    /// High performance (the direct path).
    public var usesHighPerformance: Bool { controller.usesHighPerformance }
    /// The picture takes the window's shape (the virtual display, or the workspace's display from aOS).
    public var picturesFollowWindow: Bool { controller.picturesFollowWindow }
    /// The resolution scale the session uses now.
    public var resolutionScale: Double { controller.resolutionScale }

    /// The area the picture is shown in, whenever it or the resolution changes.
    public var onDisplayArea: ((ScreenArea) -> Void)? {
        didSet {
            let handler = onDisplayArea
            controller.onDisplayArea = handler.map { handler in
                { points, scale, resolution in
                    handler(ScreenArea(points: points, screenScale: scale, resolutionScale: resolution))
                }
            }
        }
    }

    /// The last picture (JPEG, at most 1280 pixels wide) when the session lets go of it: closing, reconnecting, the
    /// app going to the background.
    public var onPicture: ((Data) -> Void)? {
        get { controller.onThumbnail }
        set { controller.onThumbnail = newValue }
    }

    /// The person chose another resolution in the session's toolbar.
    public var onResolutionScale: ((Double) -> Void)? {
        get { controller.onResolutionScale }
        set { controller.onResolutionScale = newValue }
    }

    /// The direct path didn't work (with why, for the log): the session has ended, aOS goes through the SSH tunnel.
    /// Set it for a session with `highPerformance` only.
    public var onDirectPathFailed: ((String) -> Void)? {
        didSet {
            let handler = onDirectPathFailed
            controller.onDirectPathFailed = handler.map { handler in { failure in handler(failure.message) } }
        }
    }

    /// The screen refused the login; aOS ends the session and asks for a new one. Without it, the session shows the
    /// failure as Open Screen Sharing does.
    public var onLoginRefused: (() -> Void)? {
        didSet {
            let handler = onLoginRefused
            controller.onLoginRefused = handler.map { handler in { _ in handler() } }
        }
    }

    /// The session ended: closed here, or from its own close button or after a failure.
    public private(set) var isClosed = false

    /// Ends the session (once).
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        controller.close()
    }

    /// The session closed itself (its close button, the alert after a failure).
    fileprivate func closedBySession() {
        isClosed = true
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

/// A screen in the selection view: Open Screen Sharing's card (the last picture, or the device's icon, a dot that is
/// green while the screen can be reached, the name and one line below it).
public struct ScreenCard: View {
    public enum Availability: Sendable { case available, unavailable }

    private let name: String
    private let detail: String?
    private let model: String
    private let enclosureColor: String
    private let thumbnail: Data?
    private let availability: Availability?

    public static var aspectRatio: CGFloat { ComputerCard.aspectRatio }

    public init(name: String, detail: String?, model: String = "", enclosureColor: String = "", thumbnail: Data?,
                availability: Availability?) {
        self.name = name
        self.detail = detail
        self.model = model
        self.enclosureColor = enclosureColor
        self.thumbnail = thumbnail
        self.availability = availability
    }

    public var body: some View {
        ComputerCard(name: name, detail: detail, device: DeviceAppearance(model: model, enclosureColor: enclosureColor),
                     thumbnail: thumbnail,
                     availability: availability.map { $0 == .available ? .available : .unavailable })
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
        SessionView(controller: session.controller, hasOwnWindow: false) { [session, onClose] in
            session.closedBySession()
            onClose()
        }
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
