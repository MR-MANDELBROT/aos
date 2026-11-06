import Foundation

/// The user's Bitwarden account in aOS: signing in (through Bitwarden's own command line tool), unlocking and
/// locking, and the logins for a sign-in request. Everything about passwords stays in Bitwarden; aOS asks it for
/// exactly the login the user approves, right before filling, and keeps nothing but the session key (in the
/// keychain, until the vault locks again).
///
/// When it locks again: `lockHours` after it was unlocked (a setting, default 8), when the Mac goes to sleep or
/// restarts (also while aOS wasn't running: the kernel's sleep and boot times are checked), and when the user locks
/// it. Quitting aOS alone doesn't lock it (an update or a restart of aOS shouldn't need the master password again).
@MainActor
public final class BitwardenVault {
    public enum Phase: Equatable, Sendable {
        /// Not looked at yet.
        case unknown
        /// Bitwarden's command line tool isn't on this Mac yet (aOS downloads it with the first sign-in).
        case noTool
        /// Downloading and checking Bitwarden's command line tool.
        case installing
        case signedOut
        /// Signing in: what Bitwarden asks right now.
        case signingIn(BitwardenLoginConversation.Step)
        case locked
        case unlocking
        case unlocked
    }

    /// What a sign-in request can offer from Bitwarden.
    public enum Offer: Equatable, Sendable {
        /// No Bitwarden account in aOS.
        case off
        /// Signed in, but locked: the user unlocks it on the Mac.
        case locked
        /// Unlocked; the logins that match the site (maybe none).
        case logins([BitwardenCLI.Item])
        /// Bitwarden didn't answer.
        case unavailable(String)

        /// For the companion protocol ("bitwarden" in a sign-in event).
        public var state: String {
            switch self {
            case .off: return "off"
            case .locked: return "locked"
            case .logins: return "unlocked"
            case .unavailable: return "unavailable"
            }
        }

        public var logins: [BitwardenCLI.Item] {
            if case .logins(let list) = self { return list }
            return []
        }
    }

    public private(set) var phase: Phase = .unknown
    public private(set) var email: String?
    public private(set) var server: BitwardenServer = .us
    public private(set) var lastSync: Date?
    public private(set) var tool: BitwardenTool.Located?
    public private(set) var toolVersion: String?
    /// The last thing that went wrong (a BitwardenError with Bitwarden's own message, or a download problem), until
    /// the next action.
    public private(set) var problem: Error?
    /// When the vault locks again by itself (while unlocked).
    public var lockedAt: Date? { session?.until }
    /// Hours after unlocking until the vault locks again (AgentSettings.bitwardenLockHours).
    public var lockHours: Int = 8 {
        didSet { if var s = session { s.until = s.unlocked.addingTimeInterval(Double(lockHours) * 3600); keep(s) } }
    }
    public var onChange: (() -> Void)?
    /// The logins Bitwarden can offer may have changed (unlocked, locked, synced): open requests are offered again.
    public var onOffersChanged: (() -> Void)?
    public var log: (String) -> Void = { _ in }

    let paths: Paths
    private let store: BitwardenSessionStore
    /// A fixed tool (tests: a stand-in for `bw`); otherwise the located one.
    private let fixedCLI: BitwardenCLI?
    private var session: BitwardenSession?
    private var loaded = false
    private var conversation: BitwardenLoginConversation?
    private var lockTimer: Timer?
    /// `bw lock` still running: an unlock waits for it (or the new session would be locked right away).
    private var pendingLock: Task<Void, Never>?
    private var recent: [String: (id: String, at: Date)] = [:]
    /// Clocks for the lock rules (tests replace them).
    var now: () -> Date = { Date() }
    var lastSleep: () -> Date? = { SystemClock.lastSleep }
    var bootTime: () -> Date? = { SystemClock.boot }

    public init(paths: Paths, store: BitwardenSessionStore = KeychainSessionStore(), cli: BitwardenCLI? = nil) {
        self.paths = paths
        self.store = store
        self.fixedCLI = cli
    }

    public var isSignedIn: Bool {
        switch phase {
        case .locked, .unlocking, .unlocked: return true
        default: return false
        }
    }

    public var isSigningIn: Bool { conversation != nil }

    // MARK: State

    /// Looks at the tool and the account (call at launch and when the settings show).
    public func refresh() async {
        loadSession()
        guard conversation == nil, phase != .installing else { return }
        guard let cli = await currentCLI() else {
            phase = .noTool
            changed()
            return
        }
        if toolVersion == nil { toolVersion = await cli.version() }
        do {
            apply(try await cli.status(session: validSession()?.key))
        } catch {
            problem = error
        }
        changed()
    }

    private func apply(_ status: BitwardenCLI.Status) {
        email = status.email
        server = BitwardenServer(serverURL: status.serverURL)
        lastSync = status.lastSync
        switch status.state {
        case .unauthenticated:
            forgetSession()
            phase = .signedOut
        case .locked:
            if session != nil { log("Bitwarden: the session key no longer opens the vault") }
            forgetSession()
            phase = .locked
        case .unlocked:
            phase = session != nil ? .unlocked : .locked
        }
    }

    // MARK: Signing in

    /// Signs in with email and master password; Bitwarden's questions (two-step login, new device) come as
    /// `phase` `.signingIn(step)`, answered with `choose` and `answer`. The master password goes to Bitwarden's
    /// tool once (environment) and isn't kept.
    public func signIn(email: String, password: String, server: BitwardenServer) async {
        guard conversation == nil else { return }
        problem = nil
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await pendingLock?.value
        guard BitwardenCLI.isEmail(address) else {
            problem = BitwardenError.invalidEmail
            changed()
            return
        }
        do {
            let cli = try await ensureTool()
            phase = .signingIn(.working)
            changed()
            let status = try await cli.status()
            if status.state != .unauthenticated {
                // Someone is signed in already (another account, another server, or locked): start clean.
                forgetSession()
                try? await cli.logout()
            }
            if BitwardenServer(serverURL: status.serverURL) != server { try await cli.setServer(server) }
            let conversation = try cli.startLogin(email: address, password: password)
            conversation.onStep = { [weak self, weak conversation] step in
                Task { @MainActor in
                    guard let self, let conversation, self.conversation === conversation else { return }
                    self.phase = .signingIn(step)
                    self.changed()
                }
            }
            self.conversation = conversation
            let key = try await conversation.run()
            self.conversation = nil
            start(key)
            log("signed in to Bitwarden (\(server.name))")
            phase = .unlocked
            if let status = try? await cli.status(session: key) { apply(status) }
            changed()
            onOffersChanged?()
        } catch {
            conversation = nil
            if (error as? BitwardenError) != .cancelled {
                problem = error
                log("Bitwarden sign-in: \(error.localizedDescription)")
            }
            phase = .unknown
            await refresh()
        }
    }

    /// Picks a two-step method while signing in.
    public func choose(method index: Int) { conversation?.choose(index) }

    /// Answers what Bitwarden asks while signing in (a code).
    public func answer(_ text: String) { conversation?.answer(text) }

    public func cancelSignIn() { conversation?.cancel() }

    // MARK: Unlocking and locking

    /// Unlocks with the master password (it goes to Bitwarden's tool once and isn't kept).
    public func unlock(password: String) async {
        problem = nil
        await pendingLock?.value
        guard let cli = await currentCLI() else { phase = .noTool; changed(); return }
        phase = .unlocking
        changed()
        do {
            start(try await cli.unlock(password: password))
            phase = .unlocked
            log("Bitwarden unlocked")
            changed()
            onOffersChanged?()
        } catch {
            problem = error
            phase = .locked
            await refresh()
        }
    }

    /// Locks at once: the session key is forgotten here and in the keychain, then Bitwarden's tool locks too.
    public func lock(reason: String) async {
        let had = session != nil
        forgetSession()
        if phase == .unlocked || phase == .unlocking { phase = .locked }
        changed()
        if had {
            log("Bitwarden locked (\(reason))")
            onOffersChanged?()
        }
        // While signing in there is no session yet; a `bw lock` would only lock the one the sign-in is about to make.
        guard conversation == nil, phase != .noTool, phase != .signedOut else { return }
        let task = Task { [weak self] in
            if let cli = await self?.currentCLI() { try? await cli.lock() }
        }
        pendingLock = task
        await task.value
    }

    /// Signs out of Bitwarden: Bitwarden's data for aOS is removed.
    public func signOut() async {
        conversation?.cancel()
        forgetSession()
        if let cli = await currentCLI() {
            do { try await cli.logout() } catch BitwardenError.notLoggedIn {} catch { problem = error }
        }
        email = nil
        lastSync = nil
        phase = .signedOut
        log("signed out of Bitwarden")
        changed()
        onOffersChanged?()
    }

    /// Gets the newest state of the vault from Bitwarden's server.
    @discardableResult
    public func sync() async -> Bool {
        guard let session = validSession(), let cli = await currentCLI() else { return false }
        do {
            try await cli.sync(session: session.key)
            if let status = try? await cli.status(session: session.key) { apply(status) }
            changed()
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    /// Syncs when the last sync is older than `maxAge` (a login added on the phone a minute ago should show up).
    public func syncIfStale(maxAge: TimeInterval = 300) async -> Bool {
        guard validSession() != nil else { return false }
        if let lastSync, now().timeIntervalSince(lastSync) < maxAge { return false }
        return await sync()
    }

    /// Downloads Bitwarden's newest command line tool again (Settings).
    public func updateTool() async {
        problem = nil
        do {
            phase = .installing
            changed()
            tool = try await BitwardenTool.install(paths)
            toolVersion = nil
            log("Bitwarden's command line tool updated")
        } catch {
            problem = error
        }
        phase = .unknown
        await refresh()
    }

    // MARK: Logins for a sign-in

    /// The logins for a website: Bitwarden's matches for the site, narrowed to aOS's rule (Docs/COMPANION.md,
    /// "Matching logins"). Logins with "master password re-prompt" are left out: aOS can't ask for the master
    /// password on the phone.
    public func offer(for host: String) async -> Offer {
        if !loaded || phase == .unknown { await refresh() }
        guard let session = validSession() else { return isSignedIn ? .locked : .off }
        guard let cli = await currentCLI() else { return .off }
        do {
            let items = try await cli.items(forHost: host, session: session.key)
            let remembered = recentLogin(for: host)
            let matching = items.filter { !$0.reprompt && HostMatching.matches(uris: $0.uris, requestHost: host) }
                .sorted { a, b in
                    if (a.id == remembered) != (b.id == remembered) { return a.id == remembered }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            return .logins(matching)
        } catch {
            await handle(error)
            return validSession() == nil ? .locked : .unavailable(Self.describe(error))
        }
    }

    /// User name and password of the login the user approved, right before filling: only if it still matches the
    /// website (checked again here) and has no re-prompt.
    public func credentials(id: String, host: String) async throws -> (username: String, password: String) {
        let (item, password) = try await checkedLogin(id: id, host: host)
        guard !password.isEmpty else { throw BitwardenError.failed("This login has no password in Bitwarden.") }
        return (item.username, password)
    }

    /// The current one-time code of the login the user approved (Bitwarden computes it; it needs the account's
    /// premium or an organization that allows it).
    public func totp(id: String, host: String) async throws -> String {
        let (item, _) = try await checkedLogin(id: id, host: host)
        guard item.hasTOTP else { throw BitwardenError.failed("This login has no authenticator key in Bitwarden.") }
        guard let session = validSession(), let cli = await currentCLI() else { throw BitwardenError.locked }
        do {
            return try await cli.totp(id: id, session: session.key)
        } catch {
            await handle(error)
            throw error
        }
    }

    private func checkedLogin(id: String, host: String) async throws -> (BitwardenCLI.Item, String) {
        guard let session = validSession() else { throw BitwardenError.locked }
        guard let cli = await currentCLI() else { throw BitwardenError.notLoggedIn }
        do {
            let (item, password) = try await cli.login(id: id, session: session.key)
            guard !item.reprompt else {
                throw BitwardenError.failed("This login asks for the master password again (re-prompt); \(Brand.name) doesn't fill it.")
            }
            guard HostMatching.matches(uris: item.uris, requestHost: host) else {
                throw BitwardenError.failed("This login isn't for \(host).")
            }
            return (item, password)
        } catch {
            await handle(error)
            throw error
        }
    }

    /// A login the user just used for a site comes first for its next request (the code after the password).
    public func remember(login id: String, host: String) {
        recent[HostMatching.normalize(host)] = (id, now())
    }

    private func recentLogin(for host: String) -> String? {
        guard let r = recent[HostMatching.normalize(host)], now().timeIntervalSince(r.at) < 15 * 60 else { return nil }
        return r.id
    }

    // MARK: Session key

    private func loadSession() {
        guard !loaded else { return }
        loaded = true
        session = store.load()
        if session != nil, validSession() == nil { log("Bitwarden locked (time is up, or the Mac slept or restarted)") }
        scheduleLock()
    }

    /// The session key if it is still good; locks (forgets it) when its time is up or the Mac slept or restarted.
    private func validSession() -> BitwardenSession? {
        guard let s = session else { return nil }
        if s.isValid(now: now(), lastSleep: lastSleep(), boot: bootTime()) { return s }
        forgetSession()
        if phase == .unlocked { phase = .locked }
        pendingLock = Task { [weak self] in
            if let cli = await self?.currentCLI() { try? await cli.lock() }
            self?.changed()
            self?.onOffersChanged?()
        }
        return nil
    }

    private func start(_ key: String) {
        let unlocked = now()
        keep(BitwardenSession(key: key, unlocked: unlocked, until: unlocked.addingTimeInterval(Double(lockHours) * 3600)))
    }

    private func keep(_ s: BitwardenSession) {
        session = s
        loaded = true
        do { try store.save(s) } catch {
            log("Bitwarden: the keychain didn't take the session key (\(error.localizedDescription)); it stays in memory until aOS quits")
        }
        scheduleLock()
    }

    private func forgetSession() {
        session = nil
        store.delete()
        lockTimer?.invalidate()
        lockTimer = nil
    }

    private func scheduleLock() {
        lockTimer?.invalidate()
        lockTimer = nil
        guard let until = session?.until else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.lock(reason: "\(self?.lockHours ?? 0) hours after unlocking") }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
    }

    // MARK: Tool

    private func currentCLI() async -> BitwardenCLI? {
        if let fixedCLI { return fixedCLI }
        if let tool, BitwardenTool.verify(tool.path) == nil {
            return BitwardenCLI(executable: tool.path, dataDirectory: paths.bitwarden)
        }
        let paths = self.paths
        tool = await Task.detached(priority: .userInitiated) { BitwardenTool.locate(paths) }.value
        toolVersion = nil
        return tool.map { BitwardenCLI(executable: $0.path, dataDirectory: paths.bitwarden) }
    }

    /// The tool, downloaded from Bitwarden first if there is none yet.
    private func ensureTool() async throws -> BitwardenCLI {
        if let cli = await currentCLI() { return cli }
        phase = .installing
        changed()
        log("downloading Bitwarden's command line tool")
        tool = try await BitwardenTool.install(paths)
        toolVersion = nil
        log("Bitwarden's command line tool is in place (signed by Bitwarden)")
        guard let cli = await currentCLI() else { throw BitwardenError.notRunnable("not installed") }
        toolVersion = await cli.version()
        return cli
    }

    private func handle(_ error: Error) async {
        switch error as? BitwardenError {
        case .locked?:
            await lock(reason: "Bitwarden reported it locked")
        case .notLoggedIn?:
            forgetSession()
            phase = .signedOut
            changed()
            onOffersChanged?()
        default:
            break
        }
    }

    private func changed() { onChange?() }

    static func describe(_ error: Error) -> String { error.localizedDescription }

    /// Design review only (the app's AOS_PREVIEW): shows a state without Bitwarden's tool or an account.
    public func showForPreview(_ phase: Phase, email: String? = nil, server: BitwardenServer = .us,
                               until: Date? = nil, problem: Error? = nil) {
        self.phase = phase
        self.email = email
        self.server = server
        self.problem = problem
        lastSync = email == nil ? nil : Date().addingTimeInterval(-240)
        tool = BitwardenTool.Located(path: BitwardenTool.installedPath(paths), downloaded: true)
        toolVersion = "2026.10.1"
        loaded = true
        if let until { session = BitwardenSession(key: "preview", unlocked: Date(), until: until) }
        changed()
    }
}
