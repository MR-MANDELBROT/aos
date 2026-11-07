import AOSRFB
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import ScreenClient
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "screen")

/// What a screen starts with: the workspace in the iPhone's shape, and how sharp.
struct ScreenOptions: Equatable, Sendable {
    /// The workspace takes the iPhone's shape while the iPhone shows it.
    var matchShape = true
    var retina = true

    @MainActor
    init(settings: AppSettings) {
        matchShape = settings.matchWorkspaceShape
        retina = settings.retinaWorkspace
    }

    init() {}
}

/// Where a screen is reached and how its session signs in. The Mac forwards to `targetHost:targetPort` (as the Mac
/// sees it) through the SSH connection; the session itself connects to 127.0.0.1 and the forwarded port.
struct ScreenRoute: Equatable, Sendable {
    var target: ScreenTarget
    var name: String
    /// What the session remembers for this screen (quality, clipboard, the screen sharing key it trusts) is kept under
    /// this id, one per paired Mac and screen.
    var screenID: UUID
    var targetHost: String
    var targetPort: Int
    var login: ScreenLogin
    /// The picture takes the iPhone's shape (the workspace), instead of turning the iPhone to the picture's.
    var followsWindowShape: Bool
    /// "Sync Clipboard" starts on (the person's choice in the session's menu is remembered afterwards). Not for the
    /// workspace: what the iPhone copies (a password, a code) doesn't go to the agent's Mac unasked.
    var sharesClipboard: Bool { target == .mac }

    enum Problem: LocalizedError, Equatable {
        case noLogin
        var errorDescription: String? { String(localized: "aOS on the Mac sent no screen sharing login for the workspace.") }
    }

    /// The workspace: its address and its screen sharing account, as the Mac sealed them to this iPhone
    /// (`CompanionClient.workspaceLogin()`).
    static func workspace(_ login: ScreenEndpoint, mac: PairedMac, matchShape: Bool) throws -> ScreenRoute {
        guard let username = login.username, !username.isEmpty, let password = login.password, !password.isEmpty else {
            throw Problem.noLogin
        }
        return ScreenRoute(target: .workspace, name: String(localized: "Workspace"), screenID: screenID(.workspace, mac: mac),
                           targetHost: login.host, targetPort: Int(login.port),
                           login: .account(username: username, password: password), followsWindowShape: matchShape)
    }

    /// The Mac's own screen sharing (127.0.0.1:5900 on the Mac), with the Mac account the person entered.
    static func mac(_ endpoint: ScreenEndpoint, mac: PairedMac, login: SecretStore.ScreenLogin) -> ScreenRoute {
        ScreenRoute(target: .mac, name: mac.name, screenID: screenID(.mac, mac: mac), targetHost: endpoint.host,
                    targetPort: Int(endpoint.port), login: .account(username: login.username, password: login.password),
                    followsWindowShape: false)
    }

    /// A stable id for a paired Mac's screen (name-based, from the Mac's id).
    static func screenID(_ target: ScreenTarget, mac: PairedMac) -> UUID {
        screenID(named: "\(target.rawValue)\n\(mac.id.uuidString)")
    }

    static func screenID(named name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("aos-screen\n\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                           bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The area a session shows its picture in, in points: the window without the top safe area in portrait, without
    /// the side ones in landscape (Open Screen Sharing's `ScreenWindowTracker.screenArea` on an iPhone). The workspace
    /// takes this shape.
    static func pictureArea(window: CGSize, top: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGSize {
        window.width > window.height
            ? CGSize(width: max(0, window.width - leading - trailing), height: window.height)
            : CGSize(width: window.width, height: max(0, window.height - top))
    }
}

/// A screen of the Screen tab: the Mac's own or the workspace's, shown with Open Screen Sharing's session (module
/// ScreenClient). The session connects to a loopback listener whose connections go through the SSH connection to the
/// Mac (direct-tcpip to the screen's address as the Mac sees it). The workspace asks for its display in the iPhone's
/// shape and renews that lease while it is shown.
@MainActor @Observable
final class ScreenSession {
    enum Phase: Equatable {
        case idle
        /// The Mac's own screen needs the Mac account (name and password), once.
        case needsLogin
        /// Getting the login and opening the tunnel.
        case preparing
        /// Open Screen Sharing's session is shown (it reports connecting, failures and reconnecting itself).
        case running
        /// The session couldn't start.
        case failed(String)
    }

    let target: ScreenTarget
    private(set) var phase: Phase = .idle
    /// The session while running.
    private(set) var client: ScreenClientSession?
    /// Why the login form shows again (the Mac refused the account).
    private(set) var loginProblem: String?
    /// What the workspace's display was asked for (nil: its own size).
    private(set) var displayRequest: DisplayRequest?
    /// The route of the running session.
    private(set) var route: ScreenRoute?

    @ObservationIgnored private var forwarder: LocalForwarder?
    @ObservationIgnored private weak var mac: MacConnection?
    @ObservationIgnored private var options = ScreenOptions()
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var demoServer: DemoScreenServer?
    #endif

    init(target: ScreenTarget) {
        self.target = target
    }

    var isRunning: Bool { phase == .preparing || phase == .running }

    /// The local port the session connects to (tests).
    var localPort: UInt16? { forwarder?.port }

    /// Forgets what the sessions remembered for a Mac's two screens (unpairing).
    static func forget(_ mac: PairedMac) {
        for target in ScreenTarget.allCases { ScreenClient.forget(screen: ScreenRoute.screenID(target, mac: mac)) }
    }

    func showNeedsLogin(problem: String? = nil) {
        stop()
        loginProblem = problem
        phase = .needsLogin
    }

    /// Starts the screen: its login (the workspace's sealed one from the Mac, the Mac's from `login`), the tunnel, then
    /// the session. `area` is the iPhone's picture area in points: the workspace takes its shape before the first
    /// picture, so the picture comes in the right shape.
    func start(mac: MacConnection, login: SecretStore.ScreenLogin?, options: ScreenOptions, area: CGSize) async {
        stop(keepDisplay: target == .workspace && options.matchShape)
        phase = .preparing
        loginProblem = nil
        self.options = options
        self.mac = mac
        do {
            guard mac.ssh?.isActive == true else { throw ScreenError.notConnected }
            let route: ScreenRoute
            switch target {
            case .workspace:
                route = try ScreenRoute.workspace(try await mac.screenEndpoint(.workspace), mac: mac.mac,
                                                  matchShape: options.matchShape)
                if options.matchShape { await requestDisplay(for: area) }
            case .mac:
                guard let login else { throw ScreenError.noMacLogin }
                route = ScreenRoute.mac(try await mac.screenEndpoint(.mac), mac: mac.mac, login: login)
            }
            guard phase == .preparing else { return }  // stopped meanwhile
            let forwarder = LocalForwarder(targetHost: route.targetHost, targetPort: route.targetPort) { [weak mac] in
                try await Self.activeSSH(of: mac)
            }
            let port = try await forwarder.start()
            guard phase == .preparing else { forwarder.stop(); return }
            self.forwarder = forwarder
            run(route, port: Int(port))
        } catch {
            stop(keepDisplay: false)
            phase = .failed(describe(error))
        }
    }

    /// Opens the session for a route whose tunnel listens on `port`.
    private func run(_ route: ScreenRoute, host: String = "127.0.0.1", port: Int) {
        let client = ScreenClientSession(screen: route.screenID, name: route.name, host: host, port: port,
                                         login: route.login, followsWindowShape: route.followsWindowShape,
                                         sharesClipboard: route.sharesClipboard)
        client.onDisplayArea = { [weak self] area, _ in self?.pictureAreaChanged(area) }
        if route.target == .mac {
            client.onLoginRefused = { [weak self] in
                self?.showNeedsLogin(problem: String(localized: "The Mac didn't accept the account name or password for screen sharing."))
            }
        }
        self.route = route
        self.client = client
        phase = .running
        log.info("Screen \(route.target.rawValue, privacy: .public) through 127.0.0.1:\(port)")
    }

    /// The Mac's connection for a forwarded connection: the current one, waiting a moment while it is rebuilt.
    nonisolated private static func activeSSH(of mac: MacConnection?) async throws -> SSHConnection {
        for _ in 0..<40 {
            if let ssh = await mac?.ssh, ssh.isActive { return ssh }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ScreenError.notConnected
    }

    #if DEBUG
    /// Straight to a screen sharing server, without the Mac and SSH (`-AOSScreenDirect`, see `Demo.directScreen`).
    func startDirect(host: String, port: UInt16, username: String, password: String) {
        stop()
        run(ScreenRoute(target: target, name: target == .mac ? "Mac" : String(localized: "Workspace"),
                        screenID: ScreenRoute.screenID(named: "direct\n\(host)"), targetHost: host, targetPort: Int(port),
                        login: .account(username: username, password: password), followsWindowShape: false),
            host: host, port: Int(port))
    }

    /// The demo: a screen sharing server in the app that shows a picture (no Mac, no SSH).
    func startDemo(_ picture: CGImage, name: String) async {
        stop()
        phase = .preparing
        do {
            let server = try await DemoScreenServer.start(picture: picture, name: name)
            demoServer = server
            run(ScreenRoute(target: target, name: name, screenID: UUID(), targetHost: "127.0.0.1",
                            targetPort: Int(server.port), login: .none, followsWindowShape: target == .workspace),
                port: Int(server.port))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
    #endif

    func stop(keepDisplay: Bool = false) {
        let client = self.client
        self.client = nil
        displayTask?.cancel()
        displayTask = nil
        renewTask?.cancel()
        renewTask = nil
        forwarder?.stop()
        forwarder = nil
        route = nil
        #if DEBUG
        demoServer?.stop()
        demoServer = nil
        #endif
        // The workspace gets its own size back (if the phone can't say so, the Mac's lease runs out).
        if !keepDisplay {
            if displayRequest != nil, let companion = mac?.companion {
                Task { _ = try? await companion.display("reset") }
            }
            displayRequest = nil
        }
        if phase != .needsLogin { phase = .idle }
        // Last: closing calls back here (the view's onClose), which then finds nothing left to do.
        client?.close()
    }

    enum ScreenError: LocalizedError {
        case notConnected
        case noMacLogin
        var errorDescription: String? {
            switch self {
            case .notConnected: String(localized: "Not connected to the Mac.")
            case .noMacLogin: String(localized: "The Mac account for screen sharing is missing.")
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if let companion = error as? CompanionError, case .refused(let message) = companion { return message }
        return error.localizedDescription
    }

    // MARK: The workspace in the phone's shape

    private func pictureAreaChanged(_ area: CGSize) {
        guard target == .workspace, options.matchShape, phase == .running else { return }
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            // Turning the iPhone sends a few sizes in a row: only the one it settles on counts.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.requestDisplay(for: area)
        }
    }

    /// Asks the Mac for the workspace's display in the shape of `area` and keeps renewing it while the screen is shown
    /// (the Mac gives it back to the workspace when the renewals stop).
    private func requestDisplay(for area: CGSize) async {
        guard let wanted = DisplayRequest.fitting(points: area, retina: options.retina), wanted != displayRequest,
              let companion = mac?.companion else { return }
        do {
            _ = try await companion.display(wanted.description)
            displayRequest = wanted
        } catch {
            // An older Mac or a closed workspace: the picture keeps the workspace's own shape.
            log.notice("Display request refused: \(String(describing: error), privacy: .public)")
            return
        }
        guard renewTask == nil else { return }
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                // Only while the screen is shown: without renewals the Mac's lease runs out.
                guard !Task.isCancelled, let self, self.isRunning, let request = self.displayRequest,
                      let companion = self.mac?.companion else { return }
                _ = try? await companion.display(request.description)
            }
        }
    }
}
