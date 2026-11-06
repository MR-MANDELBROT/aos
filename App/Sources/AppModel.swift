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
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.answerApproval(request.id, false) }
        }
    }

    func answerApproval(_ id: UUID, _ allowed: Bool) {
        guard let a = approval, a.id == id else { return }
        approval = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["approval"])
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
        if loginItems {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            sessionAgentStatus = SessionAgent.service.status
        }
        setup.refreshCompletion()
        keepAwake.set(settings.keepAwake && settings.sessionEnabled && sessionAgentStatus == .enabled)
        updateActivationPolicy()
    }

    /// A Dock icon (and an entry in the app switcher) while one of Annex's windows is open; menu bar only otherwise.
    func updateActivationPolicy() {
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0.className.contains("MenuBarExtra")) }
        let wanted: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    var menuSymbol: String {
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
        } catch { append("settings: \(error.localizedDescription)") }
    }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                self?.finishHelp(request.id, "The user did not respond within 10 minutes. Tell them in the chat what you need.")
            }
        }
    }

    func finishHelp(_ id: UUID, _ answer: String) {
        guard let h = help, h.id == id else { return }
        help = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["help"])
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
