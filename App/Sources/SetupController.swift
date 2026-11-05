import AnnexKit
import Foundation
import ServiceManagement
import UserNotifications
import Virtualization

/// The guided setup: Claude Code, macOS for the workspace, the workspace itself, screen sharing, the session.
/// Each step can be retried; finished steps are recognized from the state on disk, so the setup can be
/// interrupted (quit, restart) and continues where it was.
@MainActor
final class SetupController: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case requirements, claudeCode, download, install, prepare, screenSharing, session, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .requirements: return String(localized: "Check this Mac")
            case .claudeCode: return String(localized: "Claude Code")
            case .download: return String(localized: "Download macOS")
            case .install: return String(localized: "Create the workspace")
            case .prepare: return String(localized: "Prepare the workspace")
            case .screenSharing: return String(localized: "Turn on screen sharing")
            case .session: return String(localized: "Start the session")
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

    let paths: Paths
    let workspace: WorkspaceController
    @Published var step: Step = .requirements
    @Published var activity: Activity = .idle
    @Published var requirementProblems: [String] = []
    @Published var claudeInstalled = false
    @Published var claudeVersion: String?
    @Published var claudeSignedIn = false
    @Published var restoreInfo: RestoreImage.Info?
    @Published var isComplete = false
    @Published var details: [String] = []
    var log: (String) -> Void = { _ in }
    private var download: ResumableDownload?

    init(paths: Paths, workspace: WorkspaceController) {
        self.paths = paths
        self.workspace = workspace
        refreshCompletion()
        step = firstOpenStep()
    }

    private var bundle: VMBundle { workspace.host.bundle }
    private var vmState: VMState? { try? bundle.loadState() }

    func refreshCompletion() {
        let done = vmState.map { $0.bootstrapped && $0.screenSharingReady } == true
            && SessionAgent.service.status == .enabled
        if done != isComplete { isComplete = done }
    }

    /// The first step that isn't done yet.
    func firstOpenStep() -> Step {
        if let s = vmState {
            if !s.provisioned || !s.bootstrapped { return s.guestBuild == nil ? .install : .prepare }
            if !s.screenSharingReady { return .screenSharing }
            return SessionAgent.service.status == .enabled ? .done : .claudeCode
        }
        return .requirements
    }

    private func note(_ line: String) {
        details.append(line)
        if details.count > 200 { details.removeFirst(details.count - 200) }
        log("setup: \(line)")
    }

    private func run(_ label: String, _ body: @escaping () async throws -> Void) {
        guard case .idle = activity else {
            if case .failed = activity {} else { return }
            return runNow(label, body)
        }
        runNow(label, body)
    }

    private func runNow(_ label: String, _ body: @escaping () async throws -> Void) {
        activity = .working(label)
        Task {
            do {
                try await body()
                activity = .idle
            } catch {
                note("\(label): \(error.localizedDescription)")
                activity = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: 1. Requirements

    func checkRequirements() {
        var problems: [String] = []
        if !VZVirtualMachine.isSupported {
            problems.append(String(localized: "This Mac can't run virtual machines (Apple silicon is required)."))
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion < 27 { problems.append(String(localized: "macOS 27 or later is required.")) }
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        if memory < 8 { problems.append(String(localized: "At least 8 GB of memory are required (this Mac has \(memory) GB).")) }
        if let free = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 60 * 1_000_000_000, vmState == nil {
            problems.append(String(localized: "About 60 GB of free disk space are needed (\(free / 1_000_000_000) GB free)."))
        }
        requirementProblems = problems
        if problems.isEmpty { step = .claudeCode; checkClaudeCode() }
    }

    // MARK: 2. Claude Code

    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    func checkClaudeCode() {
        Task.detached {
            let exe = ClaudeCode.executable()
            let version = exe != nil ? ClaudeCode.version() : nil
            let signedIn = exe != nil ? ClaudeCode.signedIn().signedIn : false
            await MainActor.run {
                self.claudeInstalled = exe != nil
                self.claudeVersion = version
                self.claudeSignedIn = signedIn
            }
        }
    }

    func continueAfterClaudeCode() {
        guard claudeInstalled && claudeSignedIn else { return }
        if let s = vmState, s.bootstrapped {
            step = s.screenSharingReady ? .session : .screenSharing
        } else if vmState?.guestBuild != nil {
            step = .prepare
        } else {
            step = .download
            lookUpRestoreImage()
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
        guard let file = restoreImageURL ?? existingRestoreImage() else { step = .download; return }
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
                // The restore image is no longer needed.
                try? FileManager.default.removeItem(at: file)
                activity = .idle
                step = .prepare
                startPrepare()
            } catch {
                note("install: \(error.localizedDescription)")
                // A half installed bundle can't be resumed: start over next time.
                try? FileManager.default.removeItem(at: bundle.url)
                activity = .failed(error.localizedDescription)
            }
        }
    }

    private func existingRestoreImage() -> URL? {
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
            self.step = .screenSharing
            try await self.workspace.provisioner.openSharingSettings(host: ip)
        }
    }

    // MARK: 6. Screen sharing

    /// Polls until screen sharing is on and delivers a real picture, then finishes the guest setup.
    func verifyScreenSharing() {
        run(String(localized: "Checking screen sharing")) {
            guard let ip = try self.workspace.host.guestAddress() else { throw VMHostError.noAddress }
            guard try await self.workspace.provisioner.screenSharingEnabled(host: ip) else {
                throw SetupError.screenSharingOff
            }
            let password = try GuestSecrets(paths: self.paths).adminPassword(createIfMissing: false)
            let client = RFBClient(host: ip, username: Brand.guestUser, password: password)
            try await client.connect()
            let image = try await client.screenshot()
            await client.disconnect()
            guard !ScreenCheck.isBlank(image) else { throw SetupError.screenSharingBlank }
            try await self.workspace.provisioner.finish(host: ip)
            try self.bundle.updateState { $0.screenSharingReady = true }
            self.note("screen sharing works; the workspace account is a standard user now")
            self.step = .session
        }
    }

    func openSharingSettingsAgain() {
        run(String(localized: "Opening the Sharing settings")) {
            guard let ip = try self.workspace.host.guestAddress() else { throw VMHostError.noAddress }
            try await self.workspace.provisioner.openSharingSettings(host: ip)
        }
    }

    func typeGuestPassword(into view: VMDisplay.Coordinator?) {
        guard let view, let password = try? GuestSecrets(paths: paths).adminPassword(createIfMissing: false) else { return }
        view.type(password + "\n")
    }

    // MARK: 7. Session

    var mcpBinary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/annex-mcp") }

    /// Registers the tools with Claude Code for the session folder.
    func configureSession() {
        run(String(localized: "Registering the workspace tools with Claude Code")) {
            let session = self.paths.session
            let binary = self.mcpBinary
            try await Task.detached { try ClaudeCode.configure(session: session, mcpBinary: binary) }.value
            self.note("tools registered for \(session.path)")
        }
    }

    /// After the user answered Claude Code's first questions in the terminal: run the session in the background.
    func enableSession() {
        run(String(localized: "Starting the session in the background")) {
            if self.workspace.host.isRunning { _ = await self.workspace.close() }
            try SessionAgent.enable()
            if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
            // Help requests arrive as notifications.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            self.note("session runs in the background; \(Brand.name) starts at login")
            self.step = .done
            self.refreshCompletion()
        }
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
