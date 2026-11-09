import AOSTailnet
import Foundation
import Network
import Observation
import os
import UIKit

private let log = Logger(subsystem: "dev.marquart.aos.ios", category: "mac")

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
        /// SSH works, but aOS on the Mac doesn't answer (not installed, too old, not running).
        case unavailable(String)
        /// The Mac has no signing key for this iPhone and refuses its requests: pair again.
        case needsPairing
    }

    private(set) var mac: PairedMac
    private(set) var state: State = .idle
    private(set) var companionState: CompanionState = .notStarted
    private(set) var hello: HelloResult?
    private(set) var workspace: WorkspaceStatus? {
        didSet { updateWorkspaceOperation() }
    }
    /// Set while `aos-companion` can't reach the aOS app on the Mac (it keeps trying): what it said.
    private(set) var macAppProblem: String?
    private(set) var ssh: SSHConnection?
    /// How the Mac was reached (same network, tailnet, Bonjour), while connected.
    var route: SSHRoute? { ssh?.route }
    private(set) var companion: CompanionClient?
    /// When the next attempt runs, while unreachable.
    private(set) var nextAttempt: Date?

    /// Events from the Mac go to the app model.
    var onEvent: ((CompanionEvent) -> Void)?
    /// The Mac's record changed (the address that worked).
    var onMacChanged: ((PairedMac) -> Void)?

    private let key: DeviceKey
    /// Signs every companion request (the Mac refuses unsigned ones); nil only in tests of old behavior.
    private let signer: CompanionSigner?
    private let deviceName: String
    private var loop: Task<Void, Never>?
    private var wake: AsyncStream<Void>.Continuation?
    private var pathMonitor: NWPathMonitor?
    private var tailnetObserver: NSObjectProtocol?

    init(mac: PairedMac, key: DeviceKey, signer: CompanionSigner?, deviceName: String) {
        self.mac = mac
        self.key = key
        self.signer = signer
        self.deviceName = deviceName
    }

    var isConnected: Bool { if case .connected = state { true } else { false } }

    /// Starts connecting (and keeps the connection up) until `stop()`.
    func start() {
        guard loop == nil else {
            // Back in the foreground with a connection that may have died meanwhile (the Mac slept, the network
            // changed while the app was suspended): a quick question tells, before the terminal waits on it.
            if isConnected { probe() } else { retryNow() }
            return
        }
        if case .needsAttention = state { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        loop = Task { [weak self] in await self?.run(wakes: stream) }
        watchNetwork()
        // aOS's Tailscale on this iPhone came up: a new way to the Mac.
        tailnetObserver = NotificationCenter.default.addObserver(forName: .aosTailnetReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.isConnected == false { self?.retryNow() } }
        }
        EmbeddedTailnet.shared.startIfSetUp()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        wake?.finish()
        wake = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let tailnetObserver { NotificationCenter.default.removeObserver(tailnetObserver) }
        tailnetObserver = nil
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

    // Sign-in answers name the request's website too: the signature covers it and the Mac checks it.

    func answerSignIn(request: String, host: String, login: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.answerSignIn(request: request, host: host, login: login)
    }

    func answerSignIn(request: String, host: String, username: String, password: String, totp: String?) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.answerSignIn(request: request, host: host, username: username, password: password, totp: totp)
    }

    func declineSignIn(request: String, host: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.declineSignIn(request: request, host: host)
    }

    func answerSignInCode(request: String, host: String, code: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.answerSignInCode(request: request, host: host, code: code)
    }

    func helpDone(request: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.helpDone(request: request)
    }

    func answerApproval(request: String, allowed: Bool) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.answerApproval(request: request, allowed: allowed)
    }

    /// Types text into the running workspace (for characters screen sharing can't type as keys).
    func typeInWorkspace(_ text: String) async throws {
        guard let companion else { throw CompanionError.closed }
        try await companion.type(text)
    }

    func refreshStatus() async {
        guard let companion, companionState == .ready else { return }
        if let status = try? await companion.status() { workspace = status }
    }

    // MARK: The Overview (the Mac and aOS)

    /// The Mac's battery, lid, staying awake, workspace, Claude Code and Bitwarden, as `mac.status` reported it.
    private(set) var macStatus: MacStatus? {
        didSet { updateWorkspaceOperation() }
    }
    /// aOS on the Mac is older and doesn't know these ops.
    var macStatusUnsupported: Bool {
        guard let hello, companionState == .ready else { return false }
        return !hello.features.contains(MacAction.status.rawValue)
    }

    func refreshMacStatus() async {
        guard let companion, companionState == .ready, !macStatusUnsupported else { return }
        if let result = try? await companion.mac(.status), let status = result.status { macStatus = status }
    }

    /// An action of the Overview (signed like every request). The status that comes back is shown at once. Starting
    /// and closing the workspace stay under way until the Mac reports it done (`workspaceOperation`).
    @discardableResult
    func perform(_ action: MacAction, value: String? = nil) async throws -> MacActionResult {
        guard let companion, companionState == .ready else { throw CompanionError.closed }
        let operation = WorkspaceOperation(action, from: reportedWorkspaceState)
        if let operation {
            workspaceTimeout = nil
            workspaceOperation = operation
        }
        let result: MacActionResult
        do {
            result = try await companion.mac(action, value: value)
        } catch {
            // Refused or no answer: nothing under way (the card says what went wrong).
            if let operation, workspaceOperation?.since == operation.since { workspaceOperation = nil }
            throw error
        }
        if let status = result.status { macStatus = status }
        if let chats = result.chats { self.chats = chats }
        if operation != nil, workspaceOperation != nil { watchWorkspaceOperation() }
        if action == .sleep, let after = result.sleepsIn { macGoesToSleep(after: after) }
        if action.changesChat {
            // The answer has the new choice; aOS's keeper on the Mac starts or ends the chat a moment later.
            Task { [weak self] in
                for pause in [2.0, 5.0] {
                    try? await Task.sleep(for: .seconds(pause))
                    await self?.refreshChats()
                }
            }
        }
        return result
    }

    // MARK: Chats (the Claude Code conversations aOS keeps reachable)

    /// The chats as `chats.list` reported them last; nil before, and from a Mac that doesn't have them.
    private(set) var chats: ChatList?

    /// aOS on the Mac lists its chats (an older one only counts the kept ones in `mac.status`).
    var chatsSupported: Bool {
        companionState == .ready && hello?.features.contains(MacAction.chatsList.rawValue) == true
    }

    func refreshChats() async {
        guard let companion, chatsSupported else { return }
        guard let result = try? await companion.mac(.chatsList) else { return }
        if let chats = result.chats { self.chats = chats }
        if let status = result.status { macStatus = status }
    }

    // MARK: Starting and closing the workspace

    /// A start or close of the workspace from this iPhone that the Mac hasn't finished yet. aOS on the Mac answers at
    /// once, with the state before, and starts or closes the workspace afterwards; meanwhile the Overview and the
    /// Screen tab show it under way and offer neither again.
    private(set) var workspaceOperation: WorkspaceOperation?
    /// The last start or close took too long (until the next one, or until the workspace gets there after all).
    private(set) var workspaceTimeout: WorkspaceOperation?
    @ObservationIgnored private var operationWatch: Task<Void, Never>?

    /// The workspace's state as the Mac reports it: mac.status if this Mac knows it, else the older status; nil before
    /// either answered.
    var reportedWorkspaceState: String? {
        macStatus?.workspace?.state ?? workspace?.state.name
    }

    /// The workspace's state to show: as reported, or "starting" or "closing" while a start or close from here is under
    /// way (so the cards don't jump back to the state before while the Mac is still at it).
    var workspaceState: String? {
        workspaceOperation?.shownState ?? reportedWorkspaceState
    }

    /// After every new state: whether the start or close under way is done, failed (the state says so) or took too
    /// long.
    private func updateWorkspaceOperation(now: Date = Date()) {
        let state = reportedWorkspaceState
        if let timeout = workspaceTimeout, timeout.arrived(at: state) { workspaceTimeout = nil }
        guard var operation = workspaceOperation else { return }
        switch operation.observe(state, at: now) {
        case .underWay:
            if operation != workspaceOperation { workspaceOperation = operation }
            return
        case .done, .failed:
            workspaceOperation = nil
        case .timedOut:
            // Only from what the Mac says: not while it can't be asked (it may be done by the time it answers).
            guard companionState == .ready else { return }
            workspaceOperation = nil
            workspaceTimeout = operation
        }
        operationWatch?.cancel()
        operationWatch = nil
    }

    /// Asks for the Mac's status every 3 s while a start or close is under way (its events say so too, when they come).
    private func watchWorkspaceOperation() {
        operationWatch?.cancel()
        operationWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.workspaceOperation != nil else { return }
                await self.refreshMacStatus()
                self.updateWorkspaceOperation()
            }
        }
    }

    /// Since when the Mac sleeps: it was put to sleep from here and hasn't answered since (nil again once it does).
    private(set) var sleepingSince: Date?
    /// Until then no attempt to connect: the Mac is falling asleep (an attempt could still reach it, or wake it).
    @ObservationIgnored private var sleepGrace: Date?
    static let sleepGraceSeconds: TimeInterval = 20

    /// The Mac sleeps in `after` s. Its connection then dies without a word (the phone would notice only minutes
    /// later), so it is closed here: the app shows at once that the Mac sleeps, and the terminals wait for it.
    func macGoesToSleep(after: TimeInterval) {
        sleepingSince = Date()
        sleepGrace = Date().addingTimeInterval(after + Self.sleepGraceSeconds)
        let ssh = self.ssh
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(after + 0.5))
            guard let self, let ssh, self.ssh === ssh else { return }
            log.info("The Mac goes to sleep; closing its connection")
            await ssh.close()
        }
    }

    // MARK: Running

    private func run(wakes: AsyncStream<Void>) async {
        var delay: TimeInterval = 1
        var wakeIterator = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            if let grace = sleepGrace, grace > Date() {
                // The Mac is falling asleep: no attempt until it had the time to (also not when woken).
                state = .unreachable(String(localized: "The Mac is going to sleep."))
                nextAttempt = grace
                try? await Task.sleep(for: .seconds(grace.timeIntervalSinceNow))
                if Task.isCancelled { return }
            }
            state = .connecting
            nextAttempt = nil
            do {
                // The same network first, then the tailnet (aOS's Tailscale here, the Tailscale app's VPN), then
                // Bonjour (ConnectionPlan). The host key stays pinned whichever way answers.
                let tailnet = EmbeddedTailnet.shared
                let routes = ConnectionPlan.routes(for: mac, embeddedNode: tailnet.isRunning, systemVPN: TailnetVPN.isActive)
                let connection = try await SSHConnection.connect(
                    routes: routes, port: Int(mac.sshPort), login: SSHLogin(username: mac.user, key: key),
                    hostKey: .pinned(mac.hostKey), tailnet: tailnet.dialer)
                if Task.isCancelled { await connection.close(); return }
                ssh = connection
                // It answers: awake again (woken on the Mac, or it didn't sleep after all).
                sleepingSince = nil
                sleepGrace = nil
                state = .connected(host: connection.host)
                let connectedAt = Date()
                if mac.lastHost != connection.host {
                    mac.lastHost = connection.host
                    onMacChanged?(mac)
                }
                await serve(connection)
                ssh = nil
                companion = nil
                // No companion without the connection: nothing reads as current any more (the Overview's cards).
                if companionState != .needsPairing { companionState = .notStarted }
                if Task.isCancelled { return }
                log.info("Connection to the Mac ended; reconnecting")
                // A connection that lived a while: reconnect right away. One that ended at once: back off.
                if Date().timeIntervalSince(connectedAt) > 10 {
                    delay = 1
                    continue
                }
                state = .unreachable(String(localized: "The connection to the Mac ended."))
            } catch is CancellationError {
                return
            } catch let error as SSHConnectError {
                switch error {
                case .hostKeyMismatch, .authenticationFailed:
                    state = .needsAttention(Self.message(for: error))
                    loop = nil
                    return
                case .unreachable:
                    state = .unreachable(unreachableMessage())
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
            var started: CompanionClient?
            do {
                let channel = try await connection.exec(CompanionCommand.serve(path: mac.companionPath))
                let client = CompanionClient(transport: channel, signer: signer)
                started = client
                await client.start()
                companion = client
                hello = try await client.hello(app: Self.appVersion, device: deviceName)
                // Subscribe first: the Mac then sends the questions that are still open, then everything new.
                try await client.subscribe()
                workspace = try await client.status()
                companionState = .ready
                let heartbeat = Task { [weak self] in await self?.beat(client) }
                for await event in client.events {
                    handle(event)
                }
                heartbeat.cancel()
                companion = nil
                macAppProblem = nil
                if connection.isActive, companionState != .needsPairing {
                    companionState = .unavailable(String(localized: "aOS on the Mac stopped answering."))
                }
            } catch CompanionError.pairAgain {
                // The Mac has no signing key for this iPhone: nothing works until it is paired again.
                companion = nil
                await started?.close()
                companionState = .needsPairing
                log.notice("The Mac wants this iPhone paired again")
            } catch {
                companion = nil
                await started?.close()
                companionState = .unavailable(Self.companionMessage(for: error))
                log.notice("Companion not available: \(String(describing: error), privacy: .public)")
            }
            // Try the companion again after a while (aOS on the Mac may be starting or updating; without a key on
            // the Mac only pairing helps, so not so often).
            let pause = companionState == .needsPairing ? 60 : 15
            for _ in 0..<pause where connection.isActive && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handle(_ event: CompanionEvent) {
        switch event {
        case .workspace(let state):
            if workspace != nil { workspace?.state = state } else { workspace = WorkspaceStatus(state: state) }
            Task {
                await refreshStatus()
                await refreshMacStatus()
            }
        case .chats:
            // A chat started or ended on the Mac: the list now, not at the next poll.
            Task { await refreshChats() }
        case .mac(let state, let detail):
            macAppProblem = state == "unavailable" ? detail : nil
        case .subscriptionEnded:
            Task { await resubscribe() }
        default:
            break
        }
        onEvent?(event)
    }

    /// The Mac ended the event subscription (it restarted, or a day went by): a new signed subscribe; the Mac then
    /// sends the open questions again.
    private func resubscribe() async {
        guard let companion else { return }
        do {
            try await companion.subscribe()
        } catch CompanionError.pairAgain {
            companionState = .needsPairing
            await companion.close()
        } catch {
            log.notice("Subscribing again failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Every 25 s a `status`: the Mac counts the phone as connected while it asked within 45 s, the workspace line
    /// stays fresh, and a companion that stopped answering is noticed (its channel is closed and started again).
    private func beat(_ client: CompanionClient) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(25))
            if Task.isCancelled { return }
            do {
                workspace = try await client.status()
                macAppProblem = nil
            } catch CompanionError.timeout {
                log.notice("Companion didn't answer the heartbeat; restarting it")
                await client.close()
                return
            } catch CompanionError.refused(let message) {
                macAppProblem = message
            } catch CompanionError.pairAgain {
                // Removed on the Mac meanwhile.
                companionState = .needsPairing
                await client.close()
                return
            } catch {
                return
            }
        }
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            let interface = path.availableInterfaces.first.map { "\($0.name) \($0.type)" }
            Task { @MainActor in self?.pathChanged(to: status, interface: interface) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.marquart.aos.path"))
        pathMonitor = monitor
    }

    @ObservationIgnored private var lastPathStatus: NWPath.Status?
    @ObservationIgnored private var lastInterface: String?
    @ObservationIgnored private var probing = false

    private func pathChanged(to status: NWPath.Status, interface: String?) {
        defer {
            lastPathStatus = status
            lastInterface = interface
        }
        // A new network (or the VPN coming up) is a good moment to try again.
        if status == .satisfied, lastPathStatus != nil, !isConnected { retryNow() }
        // Another way out while connected (Wi-Fi to cellular, another Wi-Fi): the connection may be dead without
        // anyone noticing for minutes, and the terminal would wait on it.
        if status == .satisfied, isConnected, lastInterface != nil, interface != lastInterface { probe() }
    }

    /// Asks the Mac something small; without an answer within 5 s the connection is closed and built again (the
    /// terminals attach again by themselves).
    private func probe() {
        guard !probing, let ssh else { return }
        probing = true
        let companion = self.companion
        Task {
            defer { probing = false }
            let alive: Bool
            if let companion, companionState == .ready {
                // Any answer counts, also a refusal.
                alive = (try? await companion.request(.status, timeout: .seconds(5), refusalsThrow: false)) != nil
            } else {
                alive = (try? await ssh.run("true", timeout: .seconds(5))) != nil
            }
            if !alive, self.ssh === ssh {
                log.notice("The connection to the Mac didn't answer; connecting again")
                await ssh.close()
            }
        }
    }

    #if DEBUG
    /// The demo: shown as connected, the companion is the mock in memory.
    func runDemo(_ server: MockCompanionServer) async {
        state = .connected(host: mac.lastHost ?? mac.hosts.first ?? "")
        let client = CompanionClient(transport: server.makeTransport(), signer: signer)
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
            String(localized: "The Mac no longer accepts this iPhone. Pair again in aOS on the Mac.")
        case .localNetworkDenied:
            String(localized: "aOS may not use the local network. Allow it in Settings > Privacy & Security > Local Network.")
        case .unreachable:
            String(localized: "The Mac isn't reachable. Outside your home network you need Tailscale or another VPN to reach it.")
        case .unknownHostKey:
            String(localized: "The Mac's key is unknown.")
        }
    }

    /// Not reachable: what would help, by the Mac's way on the go.
    func unreachableMessage() -> String {
        let tailnet = EmbeddedTailnet.shared
        let notThroughTailscale = String(localized: "The Mac isn't reachable, also not through Tailscale. Is it awake, and is Tailscale on there?")
        switch mac.way {
        case .aosTailscale?:
            if !tailnet.isSetUp {
                return String(localized: "The Mac isn't reachable. On the go, set up aOS's Tailscale on this iPhone: Settings > Connection.")
            }
            return tailnet.isRunning ? notThroughTailscale
                : String(localized: "The Mac isn't reachable, and aOS's Tailscale on this iPhone isn't connected (Settings > Connection).")
        case .tailscaleApp?:
            return tailnet.isRunning || TailnetVPN.isActive ? notThroughTailscale
                : String(localized: "The Mac isn't reachable. On the go, switch on Tailscale on this iPhone (the Tailscale app, or aOS's Tailscale in Settings > Connection).")
        case .localNetwork?:
            return String(localized: "The Mac isn't reachable. Your Mac is set up for the same network only; to reach it on the go, choose a way with Tailscale in aOS on the Mac.")
        case nil:
            return Self.message(for: .unreachable([]))
        }
    }

    static func companionMessage(for error: Error) -> String {
        if let failure = error as? SessionChannel.Failure, case .exited(let status, _) = failure, status == 127 {
            return String(localized: "aOS isn't installed on the Mac where it was paired. Open aOS on the Mac and pair again.")
        }
        if let error = error as? CompanionError, error == .timeout {
            return String(localized: "aOS on the Mac doesn't answer.")
        }
        return String(localized: "aOS on the Mac isn't ready: \(error.localizedDescription)")
    }
}
