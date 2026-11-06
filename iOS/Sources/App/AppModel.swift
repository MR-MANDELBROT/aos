import Foundation
import Observation
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.marquart.annex.ios", category: "app")

/// The app's state: paired Macs, added hosts, requests from the agent, and the sessions the tabs show.
@MainActor @Observable
final class AppModel {
    enum Tab: String, Hashable, CaseIterable { case overview, terminal, screen, vault }

    let settings: AppSettings
    let lock: AppLock
    let vault: VaultModel
    let isDemo: Bool

    private(set) var macs: [PairedMac]
    private(set) var hosts: [SSHHost]
    private(set) var connection: MacConnection?
    private(set) var deviceKey: DeviceKey?
    private(set) var deviceKeyError: String?

    var tab: Tab = .overview

    // Requests from the agent
    private(set) var signIns: [SignInRequest] = []
    /// The request the sign-in sheet shows. Set it to open one; closing goes through `closeSignInSheet()`.
    var presentedSignIn: SignInRequest?
    /// Requests the person closed with "Later": they wait in the overview and don't pop up again.
    private var deferredSignIns: Set<String> = []
    /// How finished sign-in requests ended, for the sheet that is still open.
    private(set) var signInResults: [String: SignInResult] = [:]
    private(set) var helpRequests: [HelpRequest] = []
    /// The help request the screen tab shows (on the workspace).
    var activeHelp: HelpRequest?

    // Sessions
    var screenTarget: ScreenTarget = .workspace
    let macScreen = ScreenSession(target: .mac)
    let workspaceScreen = ScreenSession(target: .workspace)
    private(set) var terminals: [TerminalSession.Target: TerminalSession] = [:]

    // Pairing
    var isPairingPresented = false
    /// A pairing link that opened the app (annex-pair://).
    var incomingPairingLink: String?

    var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "deviceName") }
    }

    private var backgroundTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        let settings = AppSettings()
        self.settings = settings
        lock = AppLock(settings: settings)
        deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? UIDevice.current.name
        if isDemo {
            #if DEBUG
            let demo = Demo.content()
            vault = VaultModel(store: MemoryVaultStore(entries: Demo.emptyVault ? [] : demo.vault),
                               requiresAuthentication: false)
            macs = Demo.unpaired ? [] : [demo.mac]
            hosts = Demo.unpaired ? [] : demo.hosts
            deviceKey = DeviceKey.ephemeral()
            #else
            fatalError("The demo exists in debug builds only")
            #endif
        } else {
            vault = VaultModel(store: KeychainVaultStore())
            macs = ConfigStore.loadMacs()
            hosts = ConfigStore.loadHosts()
            loadDeviceKey()
        }
        makeConnection()
    }

    var activeMac: PairedMac? { macs.first }
    var isPaired: Bool { !macs.isEmpty }

    func screen(for target: ScreenTarget) -> ScreenSession {
        target == .mac ? macScreen : workspaceScreen
    }

    // MARK: Device key

    @discardableResult
    func loadDeviceKey() -> DeviceKey? {
        if let deviceKey { return deviceKey }
        do {
            deviceKey = try DeviceKey.loadOrCreate()
            deviceKeyError = nil
        } catch {
            deviceKeyError = error.localizedDescription
            log.error("Device key: \(String(describing: error), privacy: .public)")
        }
        return deviceKey
    }

    // MARK: Connection

    private func makeConnection() {
        connection?.stop()
        connection = nil
        guard let mac = activeMac, let key = deviceKey else { return }
        let connection = MacConnection(mac: mac, key: key, deviceName: deviceName)
        connection.onEvent = { [weak self] event in self?.handle(event) }
        connection.onMacChanged = { [weak self] mac in self?.update(mac) }
        self.connection = connection
        #if DEBUG
        if isDemo { Demo.start(connection, model: self); return }
        #endif
        connection.start()
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        lock.scenePhaseChanged(to: phase)
        switch phase {
        case .active:
            backgroundTask?.cancel()
            backgroundTask = nil
            if !isDemo { connection?.start() }
        case .background:
            guard !isDemo, backgroundTask == nil else { return }
            // Keep the connection for a short while (a quick switch to another app), then let it go: iOS suspends
            // the app anyway, and a fresh connection on return is better than a dead one.
            let identifier = UIApplication.shared.beginBackgroundTask(withName: "Annex connection") {}
            backgroundTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                if !Task.isCancelled {
                    self?.connection?.stop()
                    self?.macScreen.stop()
                    self?.workspaceScreen.stop()
                }
                UIApplication.shared.endBackgroundTask(identifier)
            }
        default:
            break
        }
    }

    // MARK: Pairing

    enum PairingStep: Equatable {
        case contactingMac
        case checkingKey
        case done(PairedMac)
    }

    /// Pairs with the Mac in `link` (Docs/COMPANION.md, "Pairing"). Reports its steps for the progress view.
    func pair(with link: PairingLink, progress: @escaping @MainActor (PairingStep) -> Void) async throws -> PairedMac {
        guard let key = loadDeviceKey() else {
            throw PairingError.noKey(deviceKeyError ?? "")
        }
        let name = PairingRequest.sanitizedDeviceName(deviceName)
        progress(.contactingMac)
        let request = PairingRequest(device: name, key: key.publicKey, code: link.code)
        let (response, host) = try await PairingClient.send(request, link: link)

        progress(.checkingKey)
        let user = (response.user?.isEmpty == false ? response.user : nil) ?? link.user
        let ssh = try await SSHConnection.connect(
            hosts: [host] + link.hosts.filter { $0 != host }, port: Int(link.sshPort),
            login: SSHLogin(username: user, key: key), hostKey: .fingerprint(link.hostKeyFingerprint))
        await ssh.close()

        let mac = PairedMac(name: link.macName, hosts: link.hosts, sshPort: link.sshPort, user: user,
                            hostKey: ssh.hostKey, hostKeyFingerprint: ssh.hostKeyFingerprint,
                            companionPath: response.companion ?? CompanionCommand.defaultPath, lastHost: ssh.host)
        // The same Mac paired again replaces its old entry.
        var updated = macs.filter { $0.hostKeyFingerprint != mac.hostKeyFingerprint }
        updated.insert(mac, at: 0)
        try saveMacs(updated)
        makeConnection()
        progress(.done(mac))
        return mac
    }

    enum PairingError: LocalizedError {
        case noKey(String)
        var errorDescription: String? {
            switch self {
            case .noKey(let reason): String(localized: "This iPhone's key couldn't be created: \(reason)")
            }
        }
    }

    func unpair(_ mac: PairedMac) {
        SecretStore.deleteScreenLogin(for: mac)
        try? saveMacs(macs.filter { $0.id != mac.id })
        macScreen.stop()
        workspaceScreen.stop()
        terminals[.mac(mac.id)]?.disconnect()
        terminals[.mac(mac.id)] = nil
        signIns = []
        deferredSignIns = []
        helpRequests = []
        presentedSignIn = nil
        activeHelp = nil
        makeConnection()
    }

    /// Makes another paired Mac the one the app connects to.
    func makeActive(_ mac: PairedMac) {
        guard let index = macs.firstIndex(where: { $0.id == mac.id }), index != 0 else { return }
        var updated = macs
        updated.remove(at: index)
        updated.insert(mac, at: 0)
        try? saveMacs(updated)
        makeConnection()
    }

    private func update(_ mac: PairedMac) {
        guard let index = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        var updated = macs
        updated[index] = mac
        try? saveMacs(updated)
    }

    private func saveMacs(_ updated: [PairedMac]) throws {
        if !isDemo { try ConfigStore.saveMacs(updated) }
        macs = updated
    }

    // MARK: Hosts

    func save(_ host: SSHHost, password: String?) throws {
        if let password, host.auth == .password, !isDemo { try SecretStore.setPassword(password, for: host) }
        if host.auth == .deviceKey { SecretStore.deletePassword(for: host) }
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == host.id }) { updated[index] = host } else { updated.append(host) }
        if !isDemo { try ConfigStore.saveHosts(updated) }
        hosts = updated
    }

    func remove(_ host: SSHHost) {
        SecretStore.deletePassword(for: host)
        terminals[.host(host.id)]?.disconnect()
        terminals[.host(host.id)] = nil
        let updated = hosts.filter { $0.id != host.id }
        if !isDemo { try? ConfigStore.saveHosts(updated) }
        hosts = updated
    }

    /// The person checked the fingerprint and trusts this key from now on.
    func trust(key: String, for host: SSHHost) {
        var trusted = host
        trusted.hostKey = key
        try? save(trusted, password: nil)
    }

    /// Forgets a host's trusted key (after it changed and the person confirmed).
    func forgetKey(of host: SSHHost) {
        var updated = host
        updated.hostKey = nil
        try? save(updated, password: nil)
    }

    // MARK: Terminals

    func terminal(for target: TerminalSession.Target) -> TerminalSession {
        if let existing = terminals[target] { return existing }
        let title: String
        switch target {
        case .mac(let id): title = macs.first { $0.id == id }?.name ?? "Mac"
        case .host(let id): title = hosts.first { $0.id == id }?.displayName ?? "SSH"
        }
        let session = TerminalSession(id: target, title: title)
        terminals[target] = session
        return session
    }

    // MARK: Requests from the agent

    func handle(_ event: CompanionEvent) {
        switch event {
        case .signIn(let request):
            guard !signIns.contains(where: { $0.id == request.id }) else { return }
            signIns.append(request)
            if presentedSignIn == nil { presentedSignIn = request }
            schedulePruning()
        case .signInClosed(let id, let result):
            signInResults[id] = result
            signIns.removeAll { $0.id == id }
            deferredSignIns.remove(id)
            if presentedSignIn?.id == id {
                // The sheet shows the result for a moment, then closes.
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if self.presentedSignIn?.id == id { self.closeSignInSheet() }
                }
            }
        case .help(let request):
            guard !helpRequests.contains(where: { $0.id == request.id }) else { return }
            helpRequests.append(request)
            showHelp(request)
        case .helpClosed(let id):
            helpRequests.removeAll { $0.id == id }
            if activeHelp?.id == id { activeHelp = helpRequests.last }
        case .workspace:
            break
        }
    }

    func showHelp(_ request: HelpRequest) {
        activeHelp = request
        screenTarget = .workspace
        tab = .screen
    }

    /// The sign-in sheet closed (answered, declined, "Later" or swiped away). A request that is still open stays in
    /// the overview without popping up again; the next new one comes up.
    func closeSignInSheet() {
        if let id = presentedSignIn?.id, signIns.contains(where: { $0.id == id }) { deferredSignIns.insert(id) }
        presentedSignIn = nil
        guard let next = signIns.first(where: { !deferredSignIns.contains($0.id) && !isExpired($0) }) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if self.presentedSignIn == nil, self.signIns.contains(where: { $0.id == next.id }) { self.presentedSignIn = next }
        }
    }

    func isExpired(_ request: SignInRequest) -> Bool {
        guard let expires = request.expires else { return false }
        return expires <= Date()
    }

    /// Forgets expired requests now and then (the Mac closes them too, with `signin.closed`).
    private func schedulePruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            while let self, !self.signIns.isEmpty {
                try? await Task.sleep(for: .seconds(5))
                self.signIns.removeAll { request in
                    guard let expires = request.expires else { return false }
                    return expires.addingTimeInterval(30) < Date() && self.presentedSignIn?.id != request.id
                }
                self.deferredSignIns.formIntersection(self.signIns.map(\.id))
            }
            self?.pruneTask = nil
        }
    }

    func finishHelp(_ request: HelpRequest) async {
        try? await connection?.helpDone(request: request.id)
        helpRequests.removeAll { $0.id == request.id }
        if activeHelp?.id == request.id { activeHelp = nil }
    }

    // MARK: Links

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == PairingLink.scheme else { return }
        incomingPairingLink = url.absoluteString
        isPairingPresented = true
    }
}
