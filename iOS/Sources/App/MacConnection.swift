import Foundation
import Network
import Observation
import os
import UIKit

private let log = Logger(subsystem: "dev.marquart.annex.ios", category: "mac")

/// The connection to the paired Mac: SSH (reconnecting on its own), and inside it the companion API.
@MainActor @Observable
final class MacConnection {
    enum State: Equatable {
        case idle
        case connecting
        case connected(host: String)
        /// Not reachable right now; tries again by itself.
        case unreachable(String)
        /// Needs the person (the Mac's key changed, or it no longer accepts this iPhone); no automatic retries.
        case needsAttention(String)
    }

    enum CompanionState: Equatable {
        case notStarted
        case starting
        case ready
        /// SSH works, but Annex on the Mac doesn't answer (not installed, too old, not running).
        case unavailable(String)
    }

    private(set) var mac: PairedMac
    private(set) var state: State = .idle
    private(set) var companionState: CompanionState = .notStarted
    private(set) var hello: HelloResult?
    private(set) var workspace: WorkspaceStatus?
    private(set) var ssh: SSHConnection?
    private(set) var companion: CompanionClient?
    /// When the next attempt runs, while unreachable.
    private(set) var nextAttempt: Date?

    /// Events from the Mac go to the app model.
    var onEvent: ((CompanionEvent) -> Void)?
    /// The Mac's record changed (the address that worked).
    var onMacChanged: ((PairedMac) -> Void)?

    private let key: DeviceKey
    private let deviceName: String
    private var loop: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?
    private var pathMonitor: NWPathMonitor?

    init(mac: PairedMac, key: DeviceKey, deviceName: String) {
        self.mac = mac
        self.key = key
        self.deviceName = deviceName
    }

    var isConnected: Bool { if case .connected = state { true } else { false } }

    /// Starts connecting (and keeps the connection up) until `stop()`.
    func start() {
        guard loop == nil else { retryNow(); return }
        if case .needsAttention = state { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        loop = Task { [weak self] in await self?.run(wakes: stream) }
        watchNetwork()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        wake?.finish()
        wake = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let ssh = self.ssh, companion = self.companion
        self.ssh = nil
        self.companion = nil
        companionState = .notStarted
        if case .needsAttention = state {} else { state = .idle }
        Task {
            await companion?.close()
            await ssh?.close()
        }
    }

    /// Tries again now instead of waiting (pull to refresh, the app came back, the network changed).
    func retryNow() {
        if case .needsAttention = state {
            state = .idle
            stop()
            start()
            return
        }
        wake?.yield()
    }

    // MARK: Requests for the views

    func screenEndpoint(_ target: ScreenTarget) async throws -> ScreenEndpoint {
        guard let companion, companionState == .ready else {
            // The Mac's own screen is screen sharing on the Mac itself; without the companion that's still known.
            if target == .mac { return ScreenEndpoint(host: "127.0.0.1", port: 5900) }
            throw CompanionError.closed
        }
        return try await companion.screen(target)
    }

    func answerSignIn(request: String, username: String, password: String, totp: String?) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.answerSignIn(request: request, username: username, password: password, totp: totp)
    }

    func declineSignIn(request: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.declineSignIn(request: request)
    }

    func helpDone(request: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.helpDone(request: request)
    }

    func refreshStatus() async {
        guard let companion, companionState == .ready else { return }
        if let status = try? await companion.status() { workspace = status }
    }

    // MARK: Running

    private func run(wakes: AsyncStream<Void>) async {
        var delay: TimeInterval = 1
        var wakeIterator = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            state = .connecting
            nextAttempt = nil
            do {
                let connection = try await SSHConnection.connect(
                    hosts: mac.hostsToTry, port: Int(mac.sshPort), login: SSHLogin(username: mac.user, key: key),
                    hostKey: .pinned(mac.hostKey))
                if Task.isCancelled { await connection.close(); return }
                ssh = connection
                state = .connected(host: connection.host)
                delay = 1
                if mac.lastHost != connection.host {
                    mac.lastHost = connection.host
                    onMacChanged?(mac)
                }
                await serve(connection)
                ssh = nil
                companion = nil
                if Task.isCancelled { return }
                log.info("Connection to the Mac ended; reconnecting")
                continue
            } catch is CancellationError {
                return
            } catch let error as SSHConnectError {
                switch error {
                case .hostKeyMismatch, .authenticationFailed:
                    state = .needsAttention(Self.message(for: error))
                    loop = nil
                    return
                default:
                    state = .unreachable(Self.message(for: error))
                }
            } catch {
                state = .unreachable(error.localizedDescription)
            }
            if Task.isCancelled { return }
            // Wait for the next attempt, or less when `retryNow()` wakes the loop.
            nextAttempt = Date().addingTimeInterval(delay)
            let wait = delay
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { self?.wake?.yield() }
            }
            _ = await wakeIterator.next(isolation: #isolation)
            timer.cancel()
            delay = min(delay * 2, 30)
        }
    }

    /// Runs the companion for as long as the SSH connection is up (its events end when the connection does);
    /// restarts it if it ends early.
    private func serve(_ connection: SSHConnection) async {
        while connection.isActive && !Task.isCancelled {
            companionState = .starting
            do {
                let channel = try await connection.exec(CompanionCommand.serve(path: mac.companionPath))
                let client = CompanionClient(transport: channel)
                await client.start()
                companion = client
                hello = try await client.hello(app: Self.appVersion, device: deviceName)
                try await client.subscribe()
                workspace = try await client.status()
                companionState = .ready
                for await event in client.events {
                    handle(event)
                }
                companion = nil
                if connection.isActive { companionState = .unavailable(String(localized: "Annex on the Mac stopped answering.")) }
            } catch {
                companion = nil
                companionState = .unavailable(Self.companionMessage(for: error))
                log.notice("Companion not available: \(String(describing: error), privacy: .public)")
            }
            // Try the companion again after a while (Annex on the Mac may be starting or updating).
            for _ in 0..<15 where connection.isActive && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handle(_ event: CompanionEvent) {
        if case .workspace(let state) = event {
            if workspace != nil { workspace?.state = state } else { workspace = WorkspaceStatus(state: state) }
            Task { await refreshStatus() }
        }
        onEvent?(event)
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in self?.pathChanged(to: status) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.marquart.annex.path"))
        pathMonitor = monitor
    }

    @ObservationIgnored private var lastPathStatus: NWPath.Status?

    private func pathChanged(to status: NWPath.Status) {
        defer { lastPathStatus = status }
        // A new network (or the VPN coming up) is a good moment to try again.
        if status == .satisfied, lastPathStatus != nil, !isConnected { retryNow() }
    }

    #if DEBUG
    /// The demo: shown as connected, the companion is the mock in memory.
    func runDemo(_ server: MockCompanionServer) async {
        state = .connected(host: mac.lastHost ?? mac.hosts.first ?? "")
        let client = CompanionClient(transport: server.makeTransport())
        await client.start()
        companion = client
        hello = try? await client.hello(app: Self.appVersion, device: deviceName)
        try? await client.subscribe()
        workspace = try? await client.status()
        companionState = .ready
        for await event in client.events { handle(event) }
    }
    #endif

    // MARK: Text

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func message(for error: SSHConnectError) -> String {
        switch error {
        case .hostKeyMismatch(let host, _):
            String(localized: "At \(host) a different computer answered, or the Mac's SSH key changed. If you set the Mac up again, pair it again.")
        case .authenticationFailed:
            String(localized: "The Mac no longer accepts this iPhone. Pair again in Annex on the Mac.")
        case .localNetworkDenied:
            String(localized: "Annex may not use the local network. Allow it in Settings > Privacy & Security > Local Network.")
        case .unreachable:
            String(localized: "The Mac isn't reachable. Outside your home network you need Tailscale or another VPN to reach it.")
        case .unknownHostKey:
            String(localized: "The Mac's key is unknown.")
        }
    }

    static func companionMessage(for error: Error) -> String {
        if let failure = error as? SessionChannel.Failure, case .exited(let status, _) = failure, status == 127 {
            return String(localized: "Annex isn't installed on the Mac where it was paired. Open Annex on the Mac and pair again.")
        }
        if let error = error as? CompanionError, error == .timeout {
            return String(localized: "Annex on the Mac doesn't answer.")
        }
        return String(localized: "Annex on the Mac isn't ready: \(error.localizedDescription)")
    }
}
