import AOSKit
import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import Virtualization

/// The guided setup: choose agents, macOS for the workspace, the workspace itself, screen sharing, connecting the
/// agents, and optionally an always-on Claude Code session. Finished steps are recognized from the state on disk,
/// so the setup can be interrupted and continues where it was.
@MainActor
final class SetupController: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case requirements, agents, download, install, prepare, screenSharing, connect, session, pair, bitwarden, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .requirements: return String(localized: "Check this Mac")
            case .agents: return String(localized: "Choose your agent")
            case .download: return String(localized: "Download macOS")
            case .install: return String(localized: "Create the workspace")
            case .prepare: return String(localized: "Prepare the workspace")
            case .screenSharing: return String(localized: "Turn on screen sharing")
            case .connect: return String(localized: "Connect your agent")
            case .session: return String(localized: "Reach it from your phone")
            case .pair: return String(localized: "Pair your iPhone")
            case .bitwarden: return String(localized: "Sign in to Bitwarden")
            case .done: return String(localized: "Ready")
            }
        }
    }

    enum Activity: Equatable {
        case idle
        case working(String)
        case progress(String, Double)
        case failed(String)
    }

    enum ConnectResult: Equatable { case connected, failed(String), manual }

    let paths: Paths
    let workspace: WorkspaceController
    var settingsChanged: (AgentSettings) -> Void = { _ in }
    @Published var step: Step = .requirements
    @Published var activity: Activity = .idle
    @Published var requirementProblems: [String] = []
    @Published var installedAgents: Set<String> = []
    @Published var selectedAgents: Set<String> = []
    @Published var connectResults: [String: ConnectResult] = [:]
    @Published var claudeSignedIn = false
    @Published var restoreInfo: RestoreImage.Info?
    @Published var isComplete = false
    @Published var details: [String] = []
    var log: (String) -> Void = { _ in }
    private var download: ResumableDownload?

    init(paths: Paths, workspace: WorkspaceController) {
        self.paths = paths
        self.workspace = workspace
        selectedAgents = Set(workspace.settings.agents)
        refreshCompletion()
        step = firstOpenStep()
    }

    private var bundle: VMBundle { workspace.host.bundle }
    private var vmState: VMState? { try? bundle.loadState() }
    var workspaceReady: Bool { vmState.map { $0.bootstrapped && $0.screenSharingReady } == true }
    var wantsClaudeSession: Bool { selectedAgents.contains("claude-code") }

    func refreshCompletion() {
        let done = workspaceReady && workspace.settings.setupFinished
        if done != isComplete { isComplete = done }
    }

    func firstOpenStep() -> Step {
        if workspace.settings.setupFinished && workspaceReady { return .done }
        if let s = vmState {
            if s.guestBuild == nil { return .install }
            if !s.provisioned || !s.bootstrapped { return .prepare }
            if !s.screenSharingReady { return .screenSharing }
            return .connect
        }
        return .requirements
    }

    private func note(_ line: String) {
        details.append(line)
        if details.count > 200 { details.removeFirst(details.count - 200) }
        log("setup: \(line)")
    }

    /// Runs one piece of work at a time (the buttons are disabled meanwhile). `then` runs after it succeeded and
    /// the activity is idle again: work that starts the next piece goes there, not into `body` (a `run` inside
    /// `body` would be refused as busy).
    private func run(_ label: String, _ body: @escaping () async throws -> Void, then: (() -> Void)? = nil) {
        switch activity {
        case .working, .progress: return
        default: break
        }
        activity = .working(label)
        Task {
            do {
                try await body()
                activity = .idle
                then?()
            } catch {
                note("\(label): \(error.localizedDescription)")
                activity = .failed(error.localizedDescription)
            }
        }
    }

    private func saveSettings(_ change: (inout AgentSettings) -> Void) {
        var s = workspace.settings
        change(&s)
        settingsChanged(s)
    }

    /// Design review: shows a step with sample state (no work starts).
    func previewStep(_ s: Step) {
        step = s
        requirementProblems = []
        installedAgents = ["claude-code", "codex", "vscode"]
        selectedAgents = ["claude-code", "codex"]
        restoreInfo = RestoreImage.Info(url: URL(string: "https://updates.cdn-apple.com/")!, buildVersion: "26B123", osVersion: "27.2.0")
        connectResults = ["claude-code": .connected, "codex": .connected]
        switch s {
        case .download: activity = .progress(String(localized: "Downloading macOS 27.2.0"), 0.42)
        case .prepare: activity = .working(String(localized: "Setting up the workspace (installs Chrome, a few minutes)"))
        default: activity = .idle
        }
    }

    // MARK: 1. Requirements

    func checkRequirements() {
        var problems: [String] = []
        if !VZVirtualMachine.isSupported {
            problems.append(String(localized: "This Mac can't run virtual machines. aOS needs a Mac with Apple silicon and can't run inside a virtual machine itself."))
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 27 { problems.append(String(localized: "macOS 27 or later is required.")) }
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if memory < 8 { problems.append(String(localized: "At least 8 GB of memory are required (this Mac has \(memory) GB).")) }
        if let free = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 75 * 1_000_000_000, vmState == nil {
            problems.append(String(localized: "About 75 GB of free disk space are needed (\(free / 1_000_000_000) GB free)."))
        }
        requirementProblems = problems
        if problems.isEmpty { step = .agents; detectAgents() }
    }

    // MARK: 2. Agents

    func detectAgents() {
        Task.detached {
            let found = Set(AgentIntegration.all.filter { $0.id != "other" && $0.isInstalled }.map(\.id))
            await MainActor.run {
                self.installedAgents = found
                if self.selectedAgents.isEmpty { self.selectedAgents = found }
            }
        }
    }

    func toggle(_ id: String) {
        if selectedAgents.contains(id) { selectedAgents.remove(id) } else { selectedAgents.insert(id) }
    }

    func continueAfterAgents() {
        guard !selectedAgents.isEmpty else { return }
        saveSettings { $0.agents = AgentIntegration.all.map(\.id).filter(selectedAgents.contains) }
        if let s = vmState {
            step = s.guestBuild == nil ? .install : (!s.bootstrapped ? .prepare : (!s.screenSharingReady ? .screenSharing : .connect))
        } else {
            step = .download
            if existingRestoreImage() != nil { step = .install } else { lookUpRestoreImage() }
        }
    }

    // MARK: 3. Download

    var restoreImageURL: URL? {
        guard let info = restoreInfo else { return nil }
        return paths.restoreImages.appendingPathComponent("\(info.buildVersion).ipsw")
    }

    func lookUpRestoreImage() {
        run(String(localized: "Asking Apple for the newest macOS")) {
            self.restoreInfo = try await RestoreImage.latestSupported()
        }
    }

    func startDownload() {
        guard let info = restoreInfo, let dest = restoreImageURL else { return }
        let label = String(localized: "Downloading macOS \(info.osVersion)")
        activity = .progress(label, 0)
        let d = ResumableDownload(source: info.url, destination: dest) { got, total in
            Task { @MainActor in
                if case .progress = self.activity {
                    self.activity = .progress(label, total > 0 ? Double(got) / Double(total) : 0)
                }
            }
        }
        download = d
        Task {
            do {
                _ = try await d.run()
                note("downloaded macOS \(info.osVersion) (\(info.buildVersion))")
                activity = .idle
                step = .install
                startInstall()
            } catch {
                activity = .failed(error.localizedDescription)
            }
        }
    }

    func pauseDownload() {
        download?.cancel()
        download = nil
        activity = .idle
    }

    // MARK: 4. Install

    func startInstall() {
        guard let file = existingRestoreImage() else { step = .download; lookUpRestoreImage(); return }
        let label = String(localized: "Installing macOS in the workspace")
        activity = .progress(label, 0)
        Task {
            do {
                if !bundle.exists {
                    let (_, requirements) = try await RestoreImage.load(file)
                    _ = try VMBundle.create(at: bundle.url, requirements: requirements, settings: .standard)
                }
                try await workspace.host.install(restoreImage: file) { fraction in
                    Task { @MainActor in self.activity = .progress(label, fraction) }
                }
                note("macOS installed")
                try? FileManager.default.removeItem(at: file)
                activity = .idle
                step = .prepare
                startPrepare()
            } catch {
                note("install: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: bundle.url)
                activity = .failed(error.localizedDescription)
            }
        }
    }

    func existingRestoreImage() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.restoreImages, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "ipsw" }
    }

    // MARK: 5. First boot and guest setup

    func startPrepare() {
        run(String(localized: "Starting the workspace for the first time")) {
            let host = self.workspace.host
            let secrets = GuestSecrets(paths: self.paths)
            if self.vmState?.provisioned != true {
                let password = try secrets.adminPassword(createIfMissing: true)
                let options = VZMacGuestProvisioningOptions()
                options.fullName = Brand.guestFullName
                options.username = Brand.guestUser
                options.password = password
                options.logsInAutomatically = true
                options.enablesRemoteLogin = true
                try options.validate()
                try await host.start(provisioning: options)
                self.note("first boot with account, automatic login and SSH")
            } else if !host.isRunning {
                try await host.start()
            }
            let ip = try await host.waitForAddress(timeout: 300)
            self.note("workspace address \(ip)")
            self.activity = .working(String(localized: "Setting up the workspace (installs Chrome, a few minutes)"))
            try await self.workspace.provisioner.bootstrap(host: ip) { line in
                Task { @MainActor in self.note(line) }
            }
            // Language and the keyboard layout apply only at the next login. From here on the user follows in the
            // workspace window: its bar says to wait until System Settings is open.
            self.step = .screenSharing
            self.sharingPhase = .starting
            self.showWorkspace()
            self.activity = .working(String(localized: "Restarting the workspace once"))
            self.note("restarting the workspace so language and keyboard apply")
            try await self.workspace.restart()
            let address = try await self.startedWorkspace(prepare: true)
            self.activity = .working(String(localized: "Opening the Sharing settings"))
            try await self.workspace.provisioner.openSharingSettings(host: address)
            self.sharingPhase = .waitingForSwitch
            self.watchScreenSharing(ip: address)
        }
    }

    /// The workspace running and logged in (booted if it was off, e.g. after the app was quit); its address.
    private func startedWorkspace(prepare: Bool = false) async throws -> String {
        let host = workspace.host
        let booting = !host.isRunning
        if booting { try await host.start() }
        let ip = try await host.waitForAddress(timeout: 300)
        if booting || prepare { try await workspace.provisioner.prepareSession(host: ip) }
        workspace.noteActivity()
        return ip
    }

    private func showWorkspace() {
        AppModel.shared.openWindow?(WindowID.workspace)
        NSApp.activate()
    }

    private func showSetup() {
        AppModel.shared.openWindow?(WindowID.setup)
        NSApp.activate()
    }

    // MARK: 6. Screen sharing and the helper

    /// Where the screen sharing step stands. The user works in the workspace window (its bar guides them); the setup
    /// window takes over again for the helper and the next steps.
    enum SharingPhase: Equatable {
        /// The workspace starts and opens System Settings at Sharing: the user waits.
        case starting
        /// System Settings is open: the user switches on Screen Sharing. aOS enters the password when macOS asks
        /// and notices by itself when it is on.
        case waitingForSwitch
        case checking
        /// Screen sharing works: back in the setup window, next the helper.
        case verified
        /// The user switches on aOS Helper in the workspace window (aOS enters the password).
        case allowingHelper
    }

    @Published var sharingPhase: SharingPhase = .starting
    /// Why the last check failed (shown in the workspace window's bar).
    @Published var sharingProblem: String?
    /// macOS shows its password dialog in the workspace right now.
    @Published var passwordDialogOpen = false
    /// The workspace window's screen, for typing the password (set by the window).
    weak var display: VMDisplay.Coordinator?
    private var sharingWatch: Task<Void, Never>?

    var isBusy: Bool {
        switch activity { case .working, .progress: return true; default: return false }
    }

    /// Step 6 from the start: shows the workspace window, boots the workspace if it is off (the app was quit or
    /// the workspace closed), opens the Sharing settings there and watches. Called when the setup or the
    /// workspace window shows this step; does nothing while it runs already.
    func beginScreenSharing() {
        guard step == .screenSharing, !isComplete, !isBusy else { return }
        switch sharingPhase {
        case .verified, .allowingHelper, .checking: return
        case .waitingForSwitch where sharingWatch != nil && workspace.host.isRunning: return
        default: break
        }
        showWorkspace()
        sharingPhase = .starting
        sharingProblem = nil
        run(String(localized: "Opening the Sharing settings")) {
            let ip = try await self.startedWorkspace()
            try await self.workspace.provisioner.openSharingSettings(host: ip)
            self.sharingPhase = .waitingForSwitch
            self.watchScreenSharing(ip: ip)
        }
    }

    /// Every two seconds: is screen sharing on (then check it), does macOS ask for the password (then enter it, once
    /// per dialog; during the setup no agent has used the workspace yet, so nothing else can be waiting for it).
    private func watchScreenSharing(ip: String, checkWhenOn: Bool = true) {
        sharingWatch?.cancel()
        sharingWatch = Task { [weak self] in
            var typedForDialog = false
            var typings = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.step == .screenSharing, self.sharingPhase == .waitingForSwitch,
                      self.workspace.host.isRunning else { break }
                let provisioner = self.workspace.provisioner
                if checkWhenOn, (try? await provisioner.screenSharingEnabled(host: ip)) == true {
                    self.sharingWatch = nil
                    self.checkScreenSharing(automatic: true)
                    return
                }
                let dialog = await provisioner.passwordDialogOpen(host: ip)
                self.passwordDialogOpen = dialog
                if dialog && !typedForDialog && typings < 3 {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)  // the dialog takes the focus
                    guard self.sharingPhase == .waitingForSwitch, self.display != nil else { continue }
                    self.typeGuestPassword(into: self.display)
                    self.note("entered the workspace password for screen sharing")
                    typedForDialog = true
                    typings += 1
                } else if !dialog {
                    typedForDialog = false
                }
            }
            self?.passwordDialogOpen = false
        }
    }

    /// "Check" in the workspace window, or by itself once screen sharing is on: connects over screen sharing and
    /// looks for a picture. Works: back to the setup window for the helper.
    func checkScreenSharing(automatic: Bool = false) {
        guard step == .screenSharing, !isBusy else { return }
        sharingWatch?.cancel()
        sharingWatch = nil
        passwordDialogOpen = false
        sharingPhase = .checking
        sharingProblem = nil
        run(String(localized: "Checking screen sharing")) {
            do {
                let ip = try await self.startedWorkspace()
                guard try await self.workspace.provisioner.screenSharingEnabled(host: ip) else {
                    throw SetupError.screenSharingOff
                }
                let password = try GuestSecrets(paths: self.paths).adminPassword(createIfMissing: false)
                // Right after the switch the service needs a few seconds before it shows a picture.
                var problem: Error?
                for attempt in 0..<(automatic ? 6 : 2) {
                    if attempt > 0 { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    do {
                        let client = RFBClient(host: ip, username: Brand.guestUser, password: password)
                        try await client.connect()
                        let image = try await client.screenshot()
                        await client.disconnect()
                        guard !ScreenCheck.isBlank(image) else { throw SetupError.screenSharingBlank }
                        problem = nil
                        break
                    } catch {
                        problem = error
                    }
                }
                if let problem { throw problem }
                self.note("screen sharing works")
                self.sharingPhase = .verified
                self.showSetup()
            } catch {
                self.sharingPhase = .waitingForSwitch
                self.sharingProblem = error.localizedDescription
                if let ip = try? self.workspace.host.guestAddress() { self.watchScreenSharing(ip: ip, checkWhenOn: false) }
                throw error
            }
        }
    }

    /// In the setup window after screen sharing: the workspace window comes to the front, the user switches on aOS
    /// Helper (aOS enters the password), then the setup window comes back by itself.
    func allowHelperAndContinue() {
        sharingPhase = .allowingHelper
        run(String(localized: "In the workspace: switch on aOS Helper"), {
            await AppModel.shared.allowHelper()
            self.note(AppModel.shared.helperState == .allowed ? "the helper may sign in" : "helper not allowed (later in the settings)")
            try await self.finishScreenSharing()
        }, then: { self.connectAgents() })
    }

    /// Without the helper (it can be allowed later in the settings).
    func skipHelper() {
        run(String(localized: "Finishing the workspace"), {
            try await self.finishScreenSharing()
        }, then: { self.connectAgents() })
    }

    private func finishScreenSharing() async throws {
        let ip = try await startedWorkspace()
        try await workspace.provisioner.finish(host: ip)
        try bundle.updateState { $0.screenSharingReady = true }
        note("screen sharing works; the workspace account is a standard user now")
        _ = await workspace.close()
        step = .connect
        showSetup()
    }

    /// Types the workspace password into the workspace window's screen (the password dialog has the focus there).
    func typeGuestPassword(into view: VMDisplay.Coordinator?) {
        guard let view, let password = try? GuestSecrets(paths: paths).adminPassword(createIfMissing: false) else { return }
        workspace.noteActivity()
        view.type(password + "\n")
    }

    // MARK: 7. Connect agents

    var mcpBinary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/aos-mcp") }

    func connectAgents() {
        run(String(localized: "Connecting your agents")) {
            let binary = self.mcpBinary
            let session = self.paths.session
            for id in AgentIntegration.all.map(\.id) where self.selectedAgents.contains(id) {
                guard let agent = AgentIntegration.byID(id) else { continue }
                let result: ConnectResult = await Task.detached {
                    do {
                        try agent.configure(binary: binary, sessionFolder: id == "claude-code" ? session : nil)
                        return .connected
                    } catch AgentIntegration.IntegrationError.manual {
                        return .manual
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                self.connectResults[id] = result
                self.note("\(agent.name): \(result)")
            }
        }
    }

    func continueAfterConnect() {
        if wantsClaudeSession {
            saveSettings { $0.keepReachable = true }
            step = .session
            checkClaudeSignIn()
        } else {
            toPairing()
        }
    }

    private func toPairing() {
        step = .pair
        AppModel.shared.refreshPhone()
    }

    // MARK: 9. The iPhone

    /// Paired, or skipped (not recommended: without the phone, approvals only happen at the Mac).
    func continueAfterPair() {
        AppModel.shared.stopPairing()
        step = .bitwarden
    }

    // MARK: 8. Always-on session (Claude Code)

    func checkClaudeSignIn() {
        Task.detached {
            let signedIn = ClaudeCode.signedIn().signedIn
            await MainActor.run { self.claudeSignedIn = signedIn }
        }
    }

    func enableSession() {
        run(String(localized: "Starting the session in the background")) {
            try SessionAgent.enable()
            self.saveSettings { $0.sessionEnabled = true }
            self.note("session runs in the background")
            self.toPairing()
        }
    }

    func skipSession() {
        saveSettings { $0.sessionEnabled = false }
        // The background process stays if it keeps conversations reachable
        if !workspace.settings.keepReachable { try? SessionAgent.disable() }
        toPairing()
    }

    // MARK: 10. Bitwarden

    /// Signed in, or later (the agent's sign-ins then have no logins to offer until the user signs in in the
    /// settings).
    func continueAfterBitwarden() {
        finish()
    }

    private func finish() {
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        saveSettings { $0.setupFinished = true }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        step = .done
        refreshCompletion()
    }
}

enum SetupError: LocalizedError {
    case screenSharingOff, screenSharingBlank
    var errorDescription: String? {
        switch self {
        case .screenSharingOff: return String(localized: "Screen sharing is still off in the workspace.")
        case .screenSharingBlank: return String(localized: "Screen sharing is on but shows no picture yet. Turn it off and on again in the workspace.")
        }
    }
}

enum ScreenCheck {
    /// A picture where (almost) every sampled pixel is black.
    static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        var lit = 0, samples = 0
        var i = 0
        while i + 3 < length {
            if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) > 30 { lit += 1 }
            samples += 1
            i += 4 * 997
        }
        return samples == 0 || Double(lit) / Double(samples) < 0.02
    }
}
