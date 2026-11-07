import AOSTailnet
import AuthenticationServices
import Foundation
import Observation
import os
import Tailnetkit
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "tailnet")

extension Notification.Name {
    /// aOS's tailnet node in this app is signed in and connected (the Mac connection tries again at once).
    static let aosTailnetReady = Notification.Name("dev.marquart.aos.tailnet.ready")
}

/// aOS's own Tailscale node in this app (Tailnetkit, built from Tailnet/tailnetkit with gomobile): no VPN profile,
/// no Tailscale app. The person signs it in once with their Tailscale account (the one of the Mac's tailnet) in a
/// web authentication session; from then on the app dials the Mac's tailnet address through it
/// (`SSHRoute.tailnet`). Its state, with its keys, is in the app's container: file protection until the first
/// unlock, not in backups.
@MainActor @Observable
final class EmbeddedTailnet {
    static let shared = EmbeddedTailnet()

    /// Its last status (nil while it doesn't run).
    private(set) var status: TailnetStatus?
    /// Why it doesn't run.
    private(set) var problem: String?
    /// The person set it up: it starts with the app until they sign out.
    private(set) var isSetUp: Bool
    private(set) var hostname: String?
    private(set) var working = false
    /// The sign-in page is open.
    private(set) var signingIn = false

    var isRunning: Bool { status?.isRunning == true }

    @ObservationIgnored private var node: TailnetNodeBox?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private let presenter = TailnetSignInPresenter()
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isDemo = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSetUp = defaults.bool(forKey: "tailnetSetUp")
        hostname = defaults.string(forKey: "tailnetHostname")
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            Task { @MainActor in EmbeddedTailnet.shared.startIfSetUp() }
        }
    }

    /// The node's folder: Application Support/Tailnet (protected until the first unlock, not backed up).
    nonisolated static var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tailnet", isDirectory: true)
    }

    /// Dials through the node (for SSHConnection).
    var dialer: TailnetDial {
        { [weak self] host, port, timeout in
            guard let node = await self?.runningNode() else { throw TailnetError.notRunning }
            return try await Task.detached { try node.dial(host: host, port: port, timeout: timeout) }.value
        }
    }

    private func runningNode() -> TailnetNodeBox? { isRunning ? node : nil }

    // MARK: Lifecycle

    /// Starts the node if the person set it up (at launch, when the app comes back).
    func startIfSetUp() {
        guard isSetUp, node == nil, !working, !isDemo else { return }
        Task { await start() }
    }

    /// The first time: a node named after this iPhone, then the sign-in.
    func setUp(deviceName: String) {
        guard !working else { return }
        let name = TailnetNames.hostname(device: deviceName, fallback: "iphone")
        hostname = name
        defaults.set(name, forKey: "tailnetHostname")
        isSetUp = true
        defaults.set(true, forKey: "tailnetSetUp")
        Task {
            await start()
            await signIn()
        }
    }

    /// Opens the sign-in page (a new one if needed) and waits until the node runs.
    func signIn() async {
        if node == nil { await start() }
        guard let node else { return }
        await refresh()
        if status?.isRunning == true { return }
        if status?.authURL == nil {
            try? await Task.detached { try node.login() }.value
            for _ in 0..<20 where status?.authURL == nil {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
            }
        }
        guard let text = status?.authURL, let url = Self.signInPage(text) else {
            problem = String(localized: "Tailscale didn't send a sign-in page. Try again in a moment.")
            return
        }
        signingIn = true
        presenter.show(url) { [weak self] in
            Task { @MainActor in self?.signingIn = false }
        }
    }

    func reconnect() {
        guard !working else { return }
        Task {
            stop()
            await start()
        }
    }

    /// Signs out: this iPhone's node leaves the tailnet, its state is deleted.
    func signOut() async {
        working = true
        defer { working = false }
        if let node {
            do {
                try await Task.detached { try node.logout() }.value
            } catch {
                log.notice("Signing out of the tailnet failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        stop()
        try? FileManager.default.removeItem(at: Self.stateDirectory)
        isSetUp = false
        defaults.set(false, forKey: "tailnetSetUp")
        status = nil
        problem = nil
    }

    private func start() async {
        guard node == nil, let hostname, !working else { return }
        working = true
        defer { working = false }
        do {
            let directory = try Self.prepareDirectory()
            let box = try await Task.detached { () throws -> TailnetNodeBox in
                let box = try TailnetNodeBox(directory: directory.path, hostname: hostname)
                try box.start()
                return box
            }.value
            node = box
            problem = nil
            log.info("Tailnet node started as \(hostname, privacy: .public)")
            poll()
        } catch {
            problem = error.localizedDescription
            log.error("Tailnet node didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() {
        polling?.cancel()
        polling = nil
        presenter.close()
        signingIn = false
        if let node { Task.detached { node.close() } }
        node = nil
        status = nil
    }

    /// The state folder with file protection, kept out of backups (keys must not move to another device).
    nonisolated static func prepareDirectory() throws -> URL {
        var url = stateDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    // MARK: Status

    func refresh() async {
        guard let node else { return }
        let json = try? await Task.detached { try node.statusJSON() }.value
        guard let json, let parsed = try? TailnetStatus(json: Data(json.utf8)) else { return }
        let wasRunning = status?.isRunning == true
        if parsed != status { status = parsed }
        if parsed.isRunning && !wasRunning {
            log.info("Tailnet node is connected")
            if signingIn {
                presenter.close()
                signingIn = false
            }
            NotificationCenter.default.post(name: .aosTailnetReady, object: nil)
        }
    }

    /// Every three seconds while it runs (every second while the sign-in page is open).
    private func poll() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.signingIn ? 1 : 3))
            }
        }
    }

    /// Only Tailscale's own sign-in pages open.
    nonisolated static func signInPage(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host == "tailscale.com" || host.hasSuffix(".tailscale.com") else { return nil }
        return url
    }

    #if DEBUG
    /// The demo: a signed in node with sample devices, nothing runs.
    func showDemo(_ status: TailnetStatus) {
        isDemo = true
        isSetUp = true
        hostname = status.device?.hostName
        self.status = status
    }
    #endif
}

enum TailnetError: LocalizedError {
    case notRunning
    var errorDescription: String? { String(localized: "aOS's Tailscale isn't connected on this iPhone.") }
}

/// The gomobile node, called off the main thread (its calls block).
final class TailnetNodeBox: @unchecked Sendable {
    private let node: TailnetkitNode

    /// `controlURL` is empty for Tailscale's coordination server (the end-to-end test passes its own).
    init(directory: String, hostname: String, controlURL: String = "") throws {
        var error: NSError?
        guard let node = TailnetkitNewNode(directory, hostname, controlURL, &error) else {
            throw error ?? TailnetError.notRunning
        }
        self.node = node
    }

    func start() throws { try node.start() }

    func statusJSON() throws -> String {
        var error: NSError?
        let json = node.statusJSON(&error)
        if let error { throw error }
        return json
    }

    func login() throws { try node.login() }
    func logout() throws { try node.logout() }
    func close() { try? node.close() }

    func dial(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var descriptor = -1
        try node.dialFD(host, port: port, timeoutMillis: Int(timeout * 1000), ret0_: &descriptor)
        guard descriptor >= 0 else { throw TailnetError.notRunning }
        return Int32(descriptor)
    }
}

/// Tailscale's sign-in page in a web authentication session (it shares Safari's sign-ins, so a Google or Apple
/// account already signed in there helps). Tailscale's page doesn't lead back to the app: the session closes when the
/// node reports that it runs.
@MainActor
final class TailnetSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func show(_ url: URL, onClose: @escaping @Sendable () -> Void) {
        close()
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("aos-tailnet")) { _, _ in onClose() }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() { onClose() }
    }

    func close() {
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}
