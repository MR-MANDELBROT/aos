import AnnexKit
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

/// A request from Claude for the user to do something on the workspace screen.
struct HelpRequest: Identifiable {
    let id = UUID()
    let purpose: String
    let since = Date()
    let continuation: CheckedContinuation<String, Never>
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let paths = Paths.default
    let workspace: WorkspaceController
    let setup: SetupController
    /// Sparkle updates (only once a real EdDSA key is in Info.plist; see Tools/release.sh).
    let updater: SPUStandardUpdaterController
    private var server: LineSocketServer?
    private var statusTimer: Timer?
    private let keepAwake = KeepAwake()

    @Published var vmPhase: VMHost.Phase = .stopped
    @Published var status: AgentStatus?
    @Published var session: SessionStatus?
    @Published var help: HelpRequest?
    @Published var logLines: [String] = []
    @Published var settings: AgentSettings
    @Published var loginItemEnabled = false
    @Published var sessionAgentStatus: SMAppService.Status = .notRegistered
    /// What the session keeper does (run/keeper.json, written by annex-session).
    @Published var keeper: KeeperStatus?
    /// Recent Claude Code conversations, for the settings (filled while the settings show them).
    @Published var conversations: [ClaudeConversation] = []
    let conversationCache = ConversationCache()

    // iPhone (see AppModel+Companion.swift)
    @Published var signIns: [CompanionEvent] = []
    @Published var phoneConnected = false
    @Published var phoneName: String?
    @Published var pairing: PairingSession?
    @Published var pairingTick = 0
    @Published var pairedDevices: [AuthorizedKeys.Device] = []
    @Published var remoteLoginOn = false
    @Published var helperState: HelperState = .unknown
    var helperWasAdmin: Bool?

    var openWindow: ((String) -> Void)?

    private init() {
        try? paths.prepare()
        workspace = WorkspaceController(paths: paths)
        settings = workspace.settings
        setup = SetupController(paths: paths, workspace: workspace)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        updater = SPUStandardUpdaterController(startingUpdater: !key.isEmpty && !key.hasPrefix("REPLACE"),
                                               updaterDelegate: nil, userDriverDelegate: nil)
        workspace.log = { [weak self] line in self?.append(line) }
        workspace.onChange = { [weak self] in self?.refresh() }
        workspace.onHelpRequest = { [weak self] purpose in
            guard let self else { return "The app is not available." }
            return await self.askForHelp(purpose)
        }
        setup.log = { [weak self] line in self?.append(line) }
        setup.settingsChanged = { [weak self] s in self?.save(s) }
        workspace.onApprovalRequest = { [weak self] agent, purpose, minutes in
            guard let self else { return false }
            return await self.askApproval(agent: agent, purpose: purpose, minutes: minutes)
        }
        workspace.companion.onChange = { [weak self] in self?.companionChanged() }
        workspace.onCompanionAnswer = { [weak self] request in self?.companionAnswer(request) }
    }

    // MARK: Approval on the Mac

    struct ApprovalRequest: Identifiable {
        let id = UUID()
        let agent: String
        let purpose: String
        let minutes: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    @Published var approval: ApprovalRequest?

    func askApproval(agent: String, purpose: String, minutes: Int) async -> Bool {
        if approval != nil { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(agent) wants to open the workspace")
        content.body = purpose
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "approval", content: content, trigger: nil))
        openWindow?(WindowID.approval)
        NSApp.activate()
        return await withCheckedContinuation { cont in
            let request = ApprovalRequest(agent: agent, purpose: purpose, minutes: minutes, continuation: cont)
            approval = request
            workspace.companion.post(CompanionEvent(event: "approval", request: request.id.uuidString, agent: agent,
                                                    purpose: purpose, minutes: minutes,
                                                    expires: Date().addingTimeInterval(300)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.answerApproval(request.id, false) }
        }
    }

    func answerApproval(_ id: UUID, _ allowed: Bool) {
        guard let a = approval, a.id == id else { return }
        approval = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval"])
        workspace.companion.post(CompanionEvent(event: "approval.closed", request: id.uuidString,
                                                result: allowed ? "allowed" : "declined"))
        a.continuation.resume(returning: allowed)
    }

    func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        let file = paths.logs.appendingPathComponent("app.log")
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(Data("\(Date().ISO8601Format()) \(line)\n".utf8)); try? h.close()
        } else {
            try? Data("\(Date().ISO8601Format()) \(line)\n".utf8).write(to: file)
        }
    }

    // MARK: Lifecycle

    /// Design review without a workspace: ANNEX_PREVIEW=step:<n> | approval | help | done shows that state.
    func applyPreview() {
        guard let preview = ProcessInfo.processInfo.environment["ANNEX_PREVIEW"] else { return }
        let parts = preview.split(separator: ":").map(String.init)
        switch parts.first {
        case "step":
            if let n = Int(parts.dropFirst().first ?? ""), let step = SetupController.Step(rawValue: n) {
                setup.previewStep(step)
                openWindow?(WindowID.setup)
            }
        case "approval":
            Task { _ = await askApproval(agent: "Codex CLI", purpose: "Look up the opening hours of the city library", minutes: 15) }
        case "help":
            Task { _ = await askForHelp("Sign in to the library website, then click Done.") }
        default: break
        }
    }

    func launched() {
        do {
            let server = LineSocketServer(path: paths.agentSocket) { line in
                guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
                    return (try? JSONEncoder().encode(AgentResponse.failure(0, "bad request"))) ?? Data()
                }
                let workspace = await AppModel.shared.workspace
                let response = await workspace.handle(request)
                return (try? JSONEncoder().encode(response)) ?? Data()
            }
            try server.start()
            self.server = server
        } catch {
            append("agent socket: \(error.localizedDescription)")
        }
        workspace.startIdleWatch()
        updateSessionAgent()
        // Cheap state every 2 s; the login item status means two XPC calls to macOS, so only every 30 s
        // (and whenever a view asks with refresh()).
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                self.refresh(loginItems: self.ticks % 15 == 0)
            }
        }
        refresh()
        if !setup.isComplete { openWindow?(WindowID.setup) ; showSetupSoon() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.applyPreview() }
    }

    private func showSetupSoon() {
        // The scene's openWindow action is only available once a view appeared; the menu view sets it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.setup.isComplete else { return }
            self.openWindow?(WindowID.setup)
            NSApp.activate()
        }
    }

    func prepareToQuit() async {
        if workspace.host.isRunning { _ = await workspace.close() }
        server?.stop()
    }

    private var ticks = 0

    func refresh(loginItems: Bool = true) {
        vmPhase = workspace.host.phase
        status = workspace.status()
        session = SessionStatus.read(paths)
        keeper = KeeperStatus.read(paths)
        if loginItems {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            sessionAgentStatus = SessionAgent.service.status
        }
        setup.refreshCompletion()
        // Awake while something must stay reachable: Annex's own session or kept conversations.
        let ownSession = settings.sessionEnabled && ClaudeCode.isConfigured(session: paths.session)
        keepAwake.set(settings.keepAwake && sessionAgentStatus == .enabled && (ownSession || reachableCount > 0))
        updateActivationPolicy()
    }

    /// A Dock icon (and an entry in the app switcher) while one of Annex's windows is open; menu bar only otherwise.
    func updateActivationPolicy() {
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0.className.contains("MenuBarExtra")) }
        let wanted: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    var menuSymbol: String {
        if !signIns.isEmpty { return "person.badge.key.fill" }
        if help != nil || approval != nil { return "hand.raised.fill" }
        switch session?.state {
        case .needsLogin, .needsAttention, .failed, .missingClaude: return "exclamationmark.triangle"
        default: break
        }
        if status?.leaseUntil != nil { return "macwindow.badge.plus" }
        return "macwindow"
    }

    // MARK: Settings

    func save(_ s: AgentSettings) {
        do {
            let sessionChanged = s.sessionName != settings.sessionName || s.sessionEnabled != settings.sessionEnabled
            try workspace.updateSettings(s)
            settings = s
            if sessionChanged { SessionAgent.restart(paths: paths) }
            updateSessionAgent()
        } catch { append("settings: \(error.localizedDescription)") }
    }

    /// The background process (annex-session) runs while it has something to do: Annex's own session once it is set
    /// up, or keeping conversations reachable.
    func updateSessionAgent() {
        let needed = settings.keepReachable
            || (settings.sessionEnabled && ClaudeCode.isConfigured(session: paths.session))
        do {
            if needed && SessionAgent.service.status != .enabled {
                try SessionAgent.enable()
                append("background process registered")
            } else if !needed && SessionAgent.service.status == .enabled {
                try SessionAgent.disable()
                append("background process removed")
            }
        } catch { append("background process: \(error.localizedDescription)") }
        sessionAgentStatus = SessionAgent.service.status
    }

    /// Changes one setting right away.
    func update(_ change: (inout AgentSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        save(s)
    }

    // MARK: Reachable conversations

    func loadConversations() {
        let hours = Double(max(settings.keepHours, 24 * 7))
        let cache = conversationCache
        Task.detached(priority: .utility) {
            let list = ClaudeConversations.recent(within: hours * 3600, limit: 40, cache: cache)
                .filter { $0.startedIn != "sdk-cli" }
            await MainActor.run { AppModel.shared.conversations = list }
        }
    }

    func pin(_ id: String, _ on: Bool) {
        update { s in
            s.keptConversations.removeAll { $0 == id }
            s.skippedConversations.removeAll { $0 == id }
            if on { s.keptConversations.append(id) }
        }
    }

    func skip(_ id: String) {
        update { s in
            s.keptConversations.removeAll { $0 == id }
            if !s.skippedConversations.contains(id) { s.skippedConversations.append(id) }
        }
    }

    func unskip(_ id: String) {
        update { s in s.skippedConversations.removeAll { $0 == id } }
    }

    /// For the menu: how many conversations are reachable now through the keeper.
    var reachableCount: Int { keeper?.entries.filter { $0.state == .running || $0.state == .starting }.count ?? 0 }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { append("login item: \(error.localizedDescription)") }
        refresh()
    }

    // MARK: Help requests

    func askForHelp(_ purpose: String) async -> String {
        if help != nil { return "Another request is already waiting for the user." }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your agent needs your help")
        content.body = purpose
        content.sound = .default
        try? await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "help", content: content, trigger: nil))
        openWindow?(WindowID.workspace)
        NSApp.activate()
        return await withCheckedContinuation { cont in
            let request = HelpRequest(purpose: purpose, continuation: cont)
            help = request
            workspace.companion.post(CompanionEvent(event: "help", request: request.id.uuidString, purpose: purpose,
                                                    expires: Date().addingTimeInterval(600)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                self?.finishHelp(request.id, "The user did not respond within 10 minutes. Tell them in the chat what you need.")
            }
        }
    }

    func finishHelp(_ id: UUID, _ answer: String) {
        guard let h = help, h.id == id else { return }
        help = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["help"])
        workspace.companion.post(CompanionEvent(event: "help.closed", request: id.uuidString))
        h.continuation.resume(returning: answer)
    }
}

extension SessionStatus {
    static func read(_ paths: Paths) -> SessionStatus? { SessionSupervisor.readStatus(paths: paths) }
}

/// The LaunchAgent that keeps the Claude Code session running (App/LaunchAgents).
enum SessionAgent {
    static let plistName = "dev.marquart.annex.session.plist"
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    static func enable() throws {
        if service.status == .enabled { return }
        try service.register()
    }

    static func disable() throws {
        try service.unregister()
    }

    /// Restart by sending the supervisor's restart command through its socket.
    static func restart(paths: Paths) {
        let sock = paths.run.appendingPathComponent("session.sock")
        guard let client = try? RawSocket(path: sock) else { return }
        client.send(Data("\u{1B}]annex;restart\u{07}".utf8))
        client.close()
    }
}
