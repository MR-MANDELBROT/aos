import AOSRFB
import AOSTailnet
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import ScreenClient
import UIKit
import os

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "screen")

/// What a screen starts with: one setting for both screens.
struct ScreenOptions: Equatable, Sendable {
    /// Both screens take the iPhone's shape: the workspace through aOS's display request, the Mac through Open Screen
    /// Sharing's virtual display (high performance, on the direct path).
    var matchesPhone = true
    /// Open Screen Sharing's resolution (1x to 2x): more room on the screen, less sharp.
    var resolutionScale = ScreenClient.defaultResolutionScale

    @MainActor
    init(settings: AppSettings) {
        matchesPhone = settings.screenMatchesPhone
        resolutionScale = settings.screenResolution
    }

    init(matchesPhone: Bool = true, resolutionScale: Double = ScreenClient.defaultResolutionScale) {
        self.matchesPhone = matchesPhone
        self.resolutionScale = resolutionScale
    }
}

/// Where a screen is reached and how its session signs in. The Mac forwards to `targetHost:targetPort` (as the Mac
/// sees it) through the SSH connection; the session itself connects to 127.0.0.1 and the forwarded port (or, on the
/// direct path, to the Mac's address in the network).
struct ScreenRoute: Equatable, Sendable {
    var target: ScreenTarget
    var name: String
    /// What the session remembers for this screen (quality, clipboard, the screen sharing key it trusts) is kept under
    /// this id, one per paired Mac and screen; its last picture too.
    var screenID: UUID
    var targetHost: String
    var targetPort: Int
    var login: ScreenLogin
    /// aOS gives the picture the iPhone's shape itself (the workspace's display request).
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

    /// The workspace's display for a picture area: sized as Open Screen Sharing sizes the Mac's virtual display (the
    /// area's shape, at least 800 by 525 points, times the resolution, 2 pixels per point on a Retina screen).
    static func display(for area: ScreenArea) -> DisplayRequest? {
        ScreenClient.displaySize(fitting: area.points, screenScale: area.screenScale, resolutionScale: area.resolutionScale)
            .map { DisplayRequest(width: $0.pixelWidth, height: $0.pixelHeight, scale: $0.density).clamped() }
    }
}

/// How a session reaches its screen.
enum ScreenPath: Equatable, Sendable {
    /// Through the SSH connection (a loopback listener, direct-tcpip to the screen as the Mac sees it): standard mode,
    /// TCP only.
    case tunnel
    /// Straight to the Mac's screen sharing at its address in the network: high performance with the virtual display.
    case direct(host: String, network: ScreenNetwork)

    var isDirect: Bool { if case .direct = self { true } else { false } }
}

/// A screen of the Screen tab: the Mac's own or the workspace's, shown with Open Screen Sharing's session (module
/// ScreenClient).
///
/// - It connects only when asked (a tap on its card). The Mac's login takes Face ID once per connect; it stays in
///   memory for that connect: reconnecting, going back to the SSH tunnel and returning from the background need no
///   second Face ID.
/// - The workspace asks for its display in the iPhone's shape and renews that lease while it is shown.
/// - The Mac goes the direct path when the iPhone's size is wanted and the Mac can be reached there (high
///   performance, Open Screen Sharing's virtual display); otherwise, and when that path fails, through the tunnel.
@MainActor @Observable
final class ScreenSession {
    enum Phase: Equatable {
        case idle
        /// The Mac's own screen needs the Mac account (name and password).
        case needsLogin
        /// Face ID, the login, the tunnel, the direct path.
        case preparing
        /// Open Screen Sharing's session is shown (it reports connecting, failures and reconnecting itself).
        case running
        /// The app went to the background with the session on screen: it comes back with the app (same login).
        case paused
        /// The session couldn't start.
        case failed(String)
    }

    /// Why the Mac went through the SSH tunnel although the iPhone's size was wanted (the card says so).
    enum TunnelReason: Equatable {
        /// The SSH connection doesn't go to an address in a network (a relay, for example).
        case noAddress
        /// SSH goes through aOS's own Tailscale node, which carries only SSH; the Tailscale app's VPN is off.
        case tailnetWithoutVPN
        /// Nothing answered at the Mac's address (another network, a firewall).
        case unreachable
        /// The Mac's screen sharing offers no high performance (macOS before 14).
        case noHighPerformance
        /// The direct connection didn't work (it broke, no picture came).
        case failed
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
    /// How the running session reaches its screen.
    private(set) var path: ScreenPath?
    /// Why the Mac's last session went through the tunnel although the iPhone's size was wanted.
    private(set) var tunnelReason: TunnelReason?
    /// What exactly went wrong on the direct path (shown on the card, for finding the cause).
    private(set) var tunnelDetail: String?

    /// The person changed the resolution in the session (aOS keeps one setting for both screens).
    @ObservationIgnored var onResolutionScale: ((Double) -> Void)?

    @ObservationIgnored private var forwarder: LocalForwarder?
    @ObservationIgnored private weak var mac: MacConnection?
    @ObservationIgnored private var options = ScreenOptions()
    /// The Mac's login for this connect (from Face ID or the form); gone when the person closes the screen.
    @ObservationIgnored private var login: SecretStore.ScreenLogin?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// When the direct path last failed, per address: not tried again for a while.
    @ObservationIgnored private var directFailures: [String: Date] = [:]
    @ObservationIgnored private var resuming = false
    /// Macs whose screen sharing offers no high performance (learned this run).
    @ObservationIgnored private var withoutHighPerformance: Set<UUID> = []
    #if DEBUG
    @ObservationIgnored private var demoServer: DemoScreenServer?
    #endif

    /// The Mac's screen login: Face ID once, then the keychain with that same authentication. Nil: none saved.
    /// (Tests count the asks.)
    static var unlockLogin: @MainActor (PairedMac) async throws -> SecretStore.ScreenLogin? = { mac in
        guard SecretStore.hasScreenLogin(for: mac) else { return nil }
        let context = try await Biometrics.authenticate(reason: String(localized: "Show the screen of \(mac.name)"))
        defer { context.invalidate() }
        return try SecretStore.screenLogin(for: mac, context: context)
    }

    /// Where to try the Mac directly (tests point it at their own servers): from the SSH connection's way.
    static var directCandidate: @MainActor (SSHConnection, PairedMac) async -> DirectPath.Candidate = { ssh, mac in
        DirectPath.candidate(route: ssh.route, remote: await ssh.remoteIP(),
                             tailnetHosts: ConnectionPlan.tailnetHosts(of: mac), systemVPN: TailnetVPN.isActive)
    }

    /// The Mac's screen sharing port on the direct path (tests: their own server's).
    static var directPort = DirectPath.screenSharingPort

    /// How long a direct session may take to show a picture before the tunnel takes over.
    static var directPictureTimeout: Duration = .seconds(15)

    init(target: ScreenTarget) {
        self.target = target
    }

    var isRunning: Bool { phase == .preparing || phase == .running }

    /// The local port of the tunnel (tests).
    var localPort: UInt16? { forwarder?.port }

    /// Forgets what the sessions remembered for a Mac's two screens and their pictures (unpairing).
    static func forget(_ mac: PairedMac) {
        for target in ScreenTarget.allCases {
            let id = ScreenRoute.screenID(target, mac: mac)
            ScreenClient.forget(screen: id)
            ScreenPictures.shared.forget(id)
        }
    }

    func showNeedsLogin(problem: String? = nil) {
        stop()
        loginProblem = problem
        phase = .needsLogin
    }

    /// The person closed the login form without a login.
    func cancelLogin() {
        guard phase == .needsLogin else { return }
        stop()
        loginProblem = nil
        phase = .idle
    }

    // MARK: Connecting

    /// A tap on the screen's card: the workspace's sealed login from the Mac; the Mac's from the keychain, behind Face
    /// ID (once), or the login form if none is saved.
    func connect(mac: MacConnection, options: ScreenOptions, area: ScreenArea) async {
        guard target == .mac else {
            await start(mac: mac, login: nil, options: options, area: area)
            return
        }
        stop()
        phase = .preparing
        do {
            guard let login = try await Self.unlockLogin(mac.mac) else {
                showNeedsLogin()
                return
            }
            guard phase == .preparing else { return }  // closed meanwhile
            await start(mac: mac, login: login, options: options, area: area)
        } catch Biometrics.Failure.cancelled {
            phase = .idle
        } catch {
            showNeedsLogin(problem: String(localized: "The saved login couldn't be read. Enter it again."))
        }
    }

    /// Starts the screen: its login (the workspace's sealed one from the Mac, the Mac's from `login`), the tunnel, the
    /// direct path for the Mac if wanted and possible, then the session. `area` is the iPhone's picture area: the
    /// workspace takes its shape before the first picture, so the picture comes in the right shape.
    func start(mac: MacConnection, login: SecretStore.ScreenLogin?, options: ScreenOptions, area: ScreenArea) async {
        stop(keepDisplay: target == .workspace && options.matchesPhone)
        phase = .preparing
        loginProblem = nil
        self.options = options
        self.mac = mac
        self.login = login
        if target == .mac { tunnelReason = nil }
        do {
            guard let ssh = mac.ssh, ssh.isActive else { throw ScreenError.notConnected }
            let route: ScreenRoute
            switch target {
            case .workspace:
                route = try ScreenRoute.workspace(try await mac.screenEndpoint(.workspace), mac: mac.mac,
                                                  matchShape: options.matchesPhone)
                if options.matchesPhone { await requestDisplay(for: area) }
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
            let path = target == .mac && options.matchesPhone
                ? await directPath(for: route, ssh: ssh, mac: mac.mac, port: Int(port)) : .tunnel
            guard phase == .preparing else { return }
            run(route, path: path)
        } catch {
            stop(keepDisplay: false)
            phase = .failed(describe(error))
        }
    }

    /// Whether the Mac goes the direct path: an address in a network, the Mac's screen sharing key known (learned
    /// through the tunnel, once), high performance offered, the Mac answering there.
    private func directPath(for route: ScreenRoute, ssh: SSHConnection, mac: PairedMac, port: Int) async -> ScreenPath {
        let host: String
        switch await Self.directCandidate(ssh, mac) {
        case .address(let address): host = address
        case .noAddress:
            tunnelReason = .noAddress
            return .tunnel
        case .tailnetWithoutVPN:
            tunnelReason = .tailnetWithoutVPN
            return .tunnel
        }
        if let failed = directFailures[host], Date().timeIntervalSince(failed) < 10 * 60 {
            tunnelReason = .failed
            tunnelDetail = String(localized: "it failed a few minutes ago; tried again after 10 minutes")
            return .tunnel
        }
        guard !withoutHighPerformance.contains(route.screenID) else {
            tunnelReason = .noHighPerformance
            return .tunnel
        }
        // A direct connection is checked against the screen sharing key the Mac showed through SSH: without it a
        // stranger in the network could pose as the Mac and get the password.
        if ScreenClient.record(of: route.screenID)?.knowsServerKey != true {
            switch await ScreenClient.checkServer(screen: route.screenID, name: route.name, port: port, login: route.login) {
            case .ok(let highPerformance, let knowsKey):
                if !highPerformance { withoutHighPerformance.insert(route.screenID) }
                guard highPerformance, knowsKey else {
                    tunnelReason = highPerformance ? .failed : .noHighPerformance
                    tunnelDetail = highPerformance ? String(localized: "the Mac's screen sharing key couldn't be learned") : nil
                    return .tunnel
                }
            case .loginRefused:
                tunnelReason = .failed
                tunnelDetail = String(localized: "the Mac refused the login")
                return .tunnel
            case .failed:
                // The session through the tunnel says what's wrong (and asks for another login if it was refused).
                tunnelReason = .failed
                tunnelDetail = String(localized: "the check through SSH failed")
                return .tunnel
            }
        }
        guard await DirectPath.reachable(host: host, port: Self.directPort) else {
            tunnelReason = .unreachable
            return .tunnel
        }
        tunnelReason = nil
        tunnelDetail = nil
        return .direct(host: host, network: DirectPath.network(for: host))
    }

    /// Opens the session for a route: through the tunnel's listener, or on the direct path.
    private func run(_ route: ScreenRoute, path: ScreenPath, host: String = "127.0.0.1", port: Int? = nil) {
        let previous = client
        let highPerformance: ScreenNetwork?
        var host = host
        var port = port ?? Int(forwarder?.port ?? 0)
        if case .direct(let address, let network) = path {
            host = address
            port = Self.directPort
            highPerformance = network
        } else {
            highPerformance = nil
        }
        let client = ScreenClientSession(screen: route.screenID, name: route.name, host: host, port: port,
                                         login: route.login, followsWindowShape: route.followsWindowShape,
                                         sharesClipboard: route.sharesClipboard, highPerformance: highPerformance,
                                         resolutionScale: options.resolutionScale)
        client.onDisplayArea = { [weak self] area in self?.pictureAreaChanged(area) }
        client.onPicture = { picture in ScreenPictures.shared.save(picture, for: route.screenID) }
        client.onResolutionScale = { [weak self] scale in
            self?.options.resolutionScale = scale
            self?.onResolutionScale?(scale)
        }
        if route.target == .mac {
            client.onLoginRefused = { [weak self] in
                self?.showNeedsLogin(problem: String(localized: "The Mac didn't accept the account name or password for screen sharing."))
            }
        }
        if case .direct(let address, _) = path {
            client.onDirectPathFailed = { [weak self, weak client] reason in
                guard let self, let client, self.client === client else { return }
                self.leaveDirectPath(address: address, reason: reason)
            }
        }
        self.route = route
        self.path = path
        self.client = client
        phase = .running
        watchTask?.cancel()
        watchTask = path.isDirect ? watchDirectPicture(of: client, address: host) : nil
        // The one it replaces (the direct path that failed) lets go; its view's close comes back to nothing.
        previous?.close()
        log.info("Screen \(route.target.rawValue, privacy: .public) through \(host, privacy: .public):\(port)")
    }

    /// The direct session shows no picture in time (UDP blocked, for example): the tunnel takes over.
    private func watchDirectPicture(of client: ScreenClientSession, address: String) -> Task<Void, Never> {
        Task { [weak self] in
            var waited = Duration.zero
            let step = Duration.milliseconds(250)
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard let self, !Task.isCancelled, self.client === client else { return }
                if client.state == .connected, client.hasPicture { return }
                // Not while the Mac or the person decides something (which session, a permission)
                if !client.waitsForPerson { waited += step }
                if waited >= Self.directPictureTimeout {
                    self.leaveDirectPath(address: address, reason: "no picture within \(Self.directPictureTimeout)")
                    return
                }
            }
        }
    }

    /// Back to the SSH tunnel after the direct path failed (same login, no Face ID).
    private func leaveDirectPath(address: String, reason: String) {
        guard let route, path?.isDirect == true else { return }
        log.notice("Direct path to \(address, privacy: .public) given up (\(reason, privacy: .public)); through SSH")
        directFailures[address] = Date()
        if reason.contains("no high performance") { withoutHighPerformance.insert(route.screenID) }
        tunnelReason = reason.contains("no high performance") ? .noHighPerformance : .failed
        tunnelDetail = reason
        watchTask?.cancel()
        watchTask = nil
        run(route, path: .tunnel)
    }

    /// The person closed the session (its toolbar, the alert after a failure). Only the shown one counts: a session
    /// that was replaced (the tunnel took over) closes without stopping its successor.
    func closed(_ closing: ScreenClientSession) {
        guard closing === client else { return }
        stop()
    }

    /// The Mac's connection for a forwarded connection: the current one, waiting a moment while it is rebuilt.
    nonisolated private static func activeSSH(of mac: MacConnection?) async throws -> SSHConnection {
        for _ in 0..<40 {
            if let ssh = await mac?.ssh, ssh.isActive { return ssh }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ScreenError.notConnected
    }

    // MARK: The background

    /// The app has been in the background for a while (`AppModel`): the session ends (its last picture is kept), and
    /// comes back with the app, with the same login.
    func pause() {
        guard phase == .running || phase == .preparing else { return }
        let keep = (mac, options, login)
        stop(keepDisplay: false)
        (mac, options, login) = keep
        phase = .paused
    }

    /// Back in the foreground after `pause()`: the same screen again, without Face ID, once the Mac is connected
    /// (`connection`: the app's connection to the Mac now).
    func resume(with connection: MacConnection?) async {
        guard phase == .paused, !resuming else { return }
        resuming = true
        defer { resuming = false }
        guard let mac = connection ?? self.mac, mac.mac.id == self.mac?.mac.id || self.mac == nil else {
            stop()
            return
        }
        for _ in 0..<60 where mac.ssh?.isActive != true {
            try? await Task.sleep(for: .milliseconds(250))
            guard phase == .paused else { return }
        }
        guard phase == .paused else { return }
        guard mac.ssh?.isActive == true else {
            stop()
            phase = .failed(ScreenError.notConnected.localizedDescription)
            return
        }
        await start(mac: mac, login: login, options: options, area: Self.currentArea(resolutionScale: options.resolutionScale))
    }

    // MARK: Without the Mac (debug)

    #if DEBUG
    /// Straight to a screen sharing server, without the Mac and SSH (`-AOSScreenDirect`, see `Demo.directScreen`).
    func startDirect(host: String, port: UInt16, username: String, password: String) {
        stop()
        run(ScreenRoute(target: target, name: target == .mac ? "Mac" : String(localized: "Workspace"),
                        screenID: ScreenRoute.screenID(named: "direct\n\(host)"), targetHost: host, targetPort: Int(port),
                        login: .account(username: username, password: password), followsWindowShape: false),
            path: .tunnel, host: host, port: Int(port))
    }

    /// The demo: a screen sharing server in the app that shows a picture (no Mac, no SSH).
    func startDemo(_ picture: CGImage, name: String, screenID: UUID) async {
        stop()
        phase = .preparing
        do {
            let server = try await DemoScreenServer.start(picture: picture, name: name)
            demoServer = server
            run(ScreenRoute(target: target, name: name, screenID: screenID, targetHost: "127.0.0.1",
                            targetPort: Int(server.port), login: .none, followsWindowShape: target == .workspace),
                path: .tunnel, port: Int(server.port))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
    #endif

    // MARK: Stopping

    func stop(keepDisplay: Bool = false) {
        let client = self.client
        self.client = nil
        watchTask?.cancel()
        watchTask = nil
        displayTask?.cancel()
        displayTask = nil
        renewTask?.cancel()
        renewTask = nil
        forwarder?.stop()
        forwarder = nil
        route = nil
        path = nil
        login = nil
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

    /// The area the session will show its picture in, from the key window (before the session's view measures it).
    static func currentArea(resolutionScale: Double) -> ScreenArea {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window else { return ScreenArea(points: .zero, screenScale: 3, resolutionScale: resolutionScale) }
        let insets = window.safeAreaInsets
        let points = ScreenRoute.pictureArea(window: window.bounds.size, top: insets.top, leading: insets.left,
                                             trailing: insets.right)
        return ScreenArea(points: points, screenScale: window.traitCollection.displayScale,
                          resolutionScale: resolutionScale)
    }

    private func pictureAreaChanged(_ area: ScreenArea) {
        guard target == .workspace, options.matchesPhone, phase == .running else { return }
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
    private func requestDisplay(for area: ScreenArea) async {
        guard let wanted = ScreenRoute.display(for: area), wanted != displayRequest, let companion = mac?.companion else {
            return
        }
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
