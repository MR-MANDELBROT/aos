import AOSKit
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
    /// Staying awake, freezing with the lid closed, network care and the hotspot choice.
    let power: PowerController

    @Published var vmPhase: VMHost.Phase = .stopped
    @Published var status: AgentStatus?
    @Published var session: SessionStatus?
    @Published var help: HelpRequest?
    @Published var logLines: [String] = []
    @Published var settings: AgentSettings
    @Published var loginItemEnabled = false
    @Published var sessionAgentStatus: SMAppService.Status = .notRegistered
    /// What the session keeper does (run/keeper.json, written by aos-session).
    @Published var keeper: KeeperStatus?
    @Published var remote: RemoteServerStatus?
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

    // Bitwarden (see AppModel+Bitwarden.swift); the views read `bitwarden` and redraw on the tick.
    @Published var bitwardenTick = 0
    var sleepObserver: NSObjectProtocol?

    var openWindow: ((String) -> Void)?
    var openSettingsAction: (() -> Void)?
    var openersNoted = false

    private init() {
        try? paths.prepare()
        workspace = WorkspaceController(paths: paths)
        settings = workspace.settings
        setup = SetupController(paths: paths, workspace: workspace)
        power = PowerController(paths: paths)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        updater = SPUStandardUpdaterController(startingUpdater: !key.isEmpty && !key.hasPrefix("REPLACE"),
                                               updaterDelegate: nil, userDriverDelegate: nil)
        workspace.log = { [weak self] line in self?.append(line) }
        power.log = { [weak self] line in self?.append(line) }
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
        workspace.bitwarden.log = { [weak self] line in self?.append(line) }
        workspace.bitwarden.onChange = { [weak self] in self?.bitwardenTick += 1 }
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

    /// Design review without a workspace: AOS_PREVIEW=step:<n> | approval | help | done shows that state.
    func applyPreview() {
        guard let preview = ProcessInfo.processInfo.environment["AOS_PREVIEW"] else { return }
        let parts = preview.split(separator: ":").map(String.init)
        if parts.first != "step" {
            // Only the window being reviewed
            NSApp.windows.filter { $0.identifier?.rawValue.contains(WindowID.setup) == true }.forEach { $0.close() }
        }
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
        case "signin":
            // A sign-in request as the agent would make it (nothing is filled: no workspace).
            // AOS_PREVIEW=signin:<field>:<bitwarden state> (unlocked with two logins by default; locked, off, none)
            let state = parts.count > 2 ? parts[2] : "unlocked"
            let logins = state == "unlocked" ? [
                CompanionLogin(id: "preview-1", name: "Example", username: "max@example.com", totp: true),
                CompanionLogin(id: "preview-2", name: "Example (work)", username: "m.marquart@example.com", totp: false),
            ] : []
            workspace.companion.post(CompanionEvent(event: "signin", request: "preview", agent: "Claude Code",
                                                    host: "accounts.example.com", field: parts.count > 1 ? parts[1] : "username",
                                                    purpose: "Download the invoice for October",
                                                    expires: Date().addingTimeInterval(180), logins: logins,
                                                    bitwarden: state == "none" ? "unlocked" : state))
            if state == "locked" { bitwarden.showForPreview(.locked, email: "max@example.com", server: .eu) }
        case "menu":
            // The menu bar panel, in a window of its own
            let host = NSHostingView(rootView: MenuView().environmentObject(self).environmentObject(power))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(size.width, 320), height: max(size.height, 200)),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Menu"
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            previewWindows.append(window)
            NSApp.activate()
        case "settings":
            UserDefaults.standard.set(parts.dropFirst().first ?? "general", forKey: "settingsTab")
            // AOS_PREVIEW=settings:bitwarden:<signedout|methods|code|newdevice|locked|unlocked|problem>
            if parts.count > 2 { previewBitwarden(parts[2]) }
            openSettingsWindow()
        default: break
        }
    }

    /// Bitwarden states for design review (no tool, no account).
    private func previewBitwarden(_ state: String) {
        let email = "max@example.com"
        switch state {
        case "methods": bitwarden.showForPreview(.signingIn(.chooseMethod(["Authenticator App", "Email", "Yubico OTP Security Key"])))
        case "code": bitwarden.showForPreview(.signingIn(.twoStepCode(method: "Email")))
        case "newdevice": bitwarden.showForPreview(.signingIn(.newDeviceCode))
        case "locked": bitwarden.showForPreview(.locked, email: email, server: .eu)
        case "unlocked": bitwarden.showForPreview(.unlocked, email: email, server: .eu, until: Date().addingTimeInterval(8 * 3600))
        case "problem": bitwarden.showForPreview(.signedOut, problem: BitwardenError.wrongPassword)
        default: bitwarden.showForPreview(.noTool)
        }
    }

    /// A design preview (AOS_PREVIEW): no agent socket, no background process, no timers. Run it with AOS_HOME
    /// pointing elsewhere; it must not register or remove the real background process.
    static let isPreview = ProcessInfo.processInfo.environment["AOS_PREVIEW"] != nil
    private var previewWindows: [NSWindow] = []

    func launched() {
        if Self.isPreview {
            if ProcessInfo.processInfo.environment["AOS_APPEARANCE"] == "dark" {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            } else if ProcessInfo.processInfo.environment["AOS_APPEARANCE"] == "light" {
                NSApp.appearance = NSAppearance(named: .aqua)
            }
            refresh(loginItems: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.applyPreview()
                self?.snapshotIfAsked()
            }
            return
        }
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
        startBitwarden()
        updateSessionAgent()
        power.start()
        if settings.stayAwake == .lidClosed { power.ensureHelperRegistered() }
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

    /// Opens the Settings window, also when no SwiftUI view has handed over its opener yet: then through the app
    /// menu's Settings item, as the keyboard shortcut would.
    func openSettingsWindow() {
        NSApp.activate()
        if let open = openSettingsAction { open(); return }
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// AOS_SNAPSHOT=<folder>: a few seconds after the preview (AOS_SNAPSHOT_DELAY, default 3.5), every visible
    /// window is drawn into <folder>/<title>.png and the app quits (design review where screen recording isn't
    /// allowed). AOS_SNAPSHOT_DRAW=1 draws the views instead of asking the window server (which can deliver blank
    /// pictures without the screen recording permission).
    private func snapshotIfAsked() {
        guard let folder = ProcessInfo.processInfo.environment["AOS_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["AOS_SNAPSHOT_DELAY"] ?? "") ?? 3.5
        let draw = ProcessInfo.processInfo.environment["AOS_SNAPSHOT_DRAW"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let dir = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The window server's picture of our own windows (with glass and shadows); drawing the views ourselves
            // is the fallback.
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            let capture = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
                .map { unsafeBitCast($0, to: Capture.self) }
            for (n, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 60 {
                let title = window.title.isEmpty ? "window-\(n)" : window.title
                let url = dir.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + ".png")
                // optionIncludingWindow (8), boundsIgnoreFraming (1)
                if !draw, let capture, let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    continue
                }
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("drawn.png"))
            }
            exit(0)
        }
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
        await power.shutdown()
        if workspace.host.isRunning { _ = await workspace.close() }
        server?.stop()
    }

    private var ticks = 0

    private func changed<T: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    func refresh(loginItems: Bool = true) {
        // Only what changed: every assignment redraws all of aOS's open windows.
        changed(\.vmPhase, workspace.host.phase)
        changed(\.status, workspace.status())
        changed(\.session, SessionStatus.read(paths))
        let k = KeeperStatus.read(paths)
        if k?.enabled != keeper?.enabled || k?.entries != keeper?.entries { keeper = k }
        changed(\.remote, RemoteServerStatus.read(paths))
        if loginItems {
            changed(\.loginItemEnabled, SMAppService.mainApp.status == .enabled)
            changed(\.sessionAgentStatus, SessionAgent.service.status)
            power.refreshHelperStatus()
        }
        syncBitwardenHelper()
        setup.refreshCompletion()
        if !Self.isPreview { power.update(settings: settings, needed: reachabilityNeeded) }
        updateActivationPolicy()
    }

    /// A Dock icon (and an entry in the app switcher) while one of aOS's windows is open; menu bar only otherwise.
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

    /// Something must stay reachable, so the Mac stays awake (Settings > General): aOS's own session, the
    /// conversations the keeper looks after (also while one is open in the Claude app or a terminal; the selection
    /// changes rarely, so the hold doesn't flap while one restarts), or the workspace in use.
    var reachabilityNeeded: Bool {
        let ownSession = settings.sessionEnabled && ClaudeCode.isConfigured(session: paths.session)
        let kept = settings.keepReachable
            && (keeper?.entries.contains { $0.state != .failed && $0.state != .folderMissing } ?? false)
        let background = sessionAgentStatus == .enabled && (ownSession || kept)
        return background || vmPhase == .running || status?.leaseUntil != nil
    }

    // MARK: Settings

    func save(_ s: AgentSettings) {
        do {
            let sessionChanged = s.sessionName != settings.sessionName || s.sessionEnabled != settings.sessionEnabled
            let lidClosedChosen = s.stayAwake == .lidClosed && settings.stayAwake != .lidClosed
            let hotspotChosen = s.hotspotJoin != settings.hotspotJoin ? s.hotspotJoin : nil
            try workspace.updateSettings(s)
            settings = s
            if sessionChanged { SessionAgent.restart(paths: paths) }
            updateSessionAgent()
            // Both need the background helper; macOS asks the user once to allow it.
            if lidClosedChosen && !Self.isPreview { power.ensureHelperRegistered() }
            // Takes effect only with the lid closed (the helper notes and restores the user's own settings).
            if hotspotChosen != nil, !Self.isPreview { power.retryHotspot() }
        } catch { append("settings: \(error.localizedDescription)") }
    }

    /// The background process (aos-session) runs while it has something to do: aOS's own session once it is set
    /// up, or keeping conversations reachable.
    func updateSessionAgent() {
        let needed = settings.keepReachable
            || (settings.sessionEnabled && ClaudeCode.isConfigured(session: paths.session))
            || (settings.newChats && ClaudeCode.executable() != nil)
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
            await MainActor.run { if AppModel.shared.conversations != list { AppModel.shared.conversations = list } }
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
    static let plistName = "dev.marquart.aos.session.plist"
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
        client.send(Data("\u{1B}]aos;restart\u{07}".utf8))
        client.close()
    }
}
