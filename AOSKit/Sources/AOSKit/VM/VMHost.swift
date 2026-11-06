import AOSRFB
import Foundation
import Virtualization

public enum VMHostError: LocalizedError {
    case notRunning
    case alreadyRunning
    case invalidState(String)
    case noAddress

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The workspace is not running."
        case .alreadyRunning: return "The workspace is already running."
        case .invalidState(let s): return "The workspace can't do that right now (\(s))."
        case .noAddress: return "The workspace has no network address yet."
        }
    }
}

/// Runs the VM. All Virtualization calls happen on the main actor (the VM is created on the main queue).
@MainActor
public final class VMHost: NSObject, VZVirtualMachineDelegate {
    public enum Phase: String, Sendable {
        case stopped, starting, running, pausing, paused, suspending, stopping, installing, error
    }

    public let bundle: VMBundle
    public let paths: Paths
    public private(set) var phase: Phase = .stopped
    public private(set) var lastError: String?
    private var vm: VZVirtualMachine?
    /// True while we stop the VM ourselves; a stop without it is the guest restarting or shutting down.
    private var stopping = false
    /// Restart the VM when the guest stops by itself (a restart inside the guest ends the VM on this framework).
    public var restartsAfterGuestStop = true
    /// Called on the main actor whenever `phase` changes.
    public var onPhaseChange: ((Phase) -> Void)?
    /// Called with each new VZVirtualMachine before it starts or restores (development hooks).
    public var beforeStart: ((VZVirtualMachine) -> Void)?
    /// Set while the display has another size than the bundle's: a phone views the workspace in its own shape.
    public private(set) var displayOverride: DisplayRequest?
    /// Called on the main actor when the display's size changes.
    public var onDisplayChange: (() -> Void)?
    private var displayLease: Task<Void, Never>?

    public init(bundle: VMBundle, paths: Paths) {
        self.bundle = bundle
        self.paths = paths
    }

    private func set(_ phase: Phase) {
        self.phase = phase
        onPhaseChange?(phase)
    }

    public var isRunning: Bool { vm?.state == .running }
    public var hasSavedState: Bool { FileManager.default.fileExists(atPath: bundle.savedStateURL.path) }

    // MARK: Configuration

    public func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let state = try bundle.loadState()
        let s = state.settings
        let config = VZVirtualMachineConfiguration()

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try bundle.hardwareModel()
        platform.machineIdentifier = try bundle.machineIdentifier()
        platform.auxiliaryStorage = try bundle.auxiliaryStorage()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()

        config.cpuCount = min(max(s.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                              VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = s.memoryMiB * 1024 * 1024
        config.memorySize = min(max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                                VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let graphics = VZMacGraphicsDisplayConfiguration(widthInPixels: s.displayWidth,
                                                         heightInPixels: s.displayHeight,
                                                         pixelsPerInch: s.displayPPI)
        let device = VZMacGraphicsDeviceConfiguration()
        device.displays = [graphics]
        config.graphicsDevices = [device]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false,
                                                          cachingMode: .automatic, synchronizationMode: .full)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: state.macAddress) { net.macAddress = mac }
        config.networkDevices = [net]

        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // The exchange folder appears in the guest as /Volumes/My Shared Files/Exchange, the Mac's programs (read
        // only, they start there without the user's data) as /Volumes/My Shared Files/Applications.
        try FileManager.default.createDirectory(at: paths.exchange, withIntermediateDirectories: true)
        var directories = ["Exchange": VZSharedDirectory(url: paths.exchange, readOnly: false)]
        if AgentSettings.load(paths).shareApplications {
            directories["Applications"] = VZSharedDirectory(url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                                                            readOnly: true)
        }
        let share = VZMultipleDirectoryShare(directories: directories)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = share
        config.directorySharingDevices = [fs]

        try config.validate()
        return config
    }

    // MARK: Install

    /// Installs macOS from the restore image into the (fresh) bundle.
    public func install(restoreImage file: URL, progress: @escaping (Double) -> Void) async throws {
        guard vm == nil else { throw VMHostError.alreadyRunning }
        set(.installing)
        do {
            let config = try makeConfiguration()
            let machine = VZVirtualMachine(configuration: config)
            let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: file)
            let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                progress(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await installer.install()
            let image = try await VZMacOSRestoreImage.image(from: file)
            let v = image.operatingSystemVersion
            try bundle.updateState {
                $0.guestBuild = image.buildVersion
                $0.guestVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }
            set(.stopped)
        } catch {
            lastError = error.localizedDescription
            set(.error)
            throw error
        }
    }

    // MARK: Start, stop, suspend

    /// Counts cold boots (not resumes from a saved state) since the app started: after one the guest logs in afresh.
    public private(set) var bootCount = 0

    /// Starts the VM: resumes a saved state if there is one, otherwise boots. On the very first boot
    /// `provisioning` creates the account, turns on auto login and SSH (macOS 27 guests).
    public func start(provisioning: VZMacGuestProvisioningOptions? = nil) async throws {
        if let vm, vm.state == .running { return }
        if let vm, vm.state == .paused {
            try await vm.resume(); set(.running); return
        }
        set(.starting)
        do {
            let config = try makeConfiguration()
            let machine = VZVirtualMachine(configuration: config)
            machine.delegate = self
            vm = machine
            beforeStart?(machine)
            if hasSavedState && provisioning == nil {
                do {
                    try await machine.restoreMachineStateFrom(url: bundle.savedStateURL)
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    try await machine.resume()
                    set(.running)
                    // A state saved while a phone had the display in its shape: back to the workspace's own.
                    restoreDisplay()
                    return
                } catch {
                    // A state that doesn't fit any more (macOS update, changed settings): boot cold.
                    try? FileManager.default.removeItem(at: bundle.savedStateURL)
                    let fresh = VZVirtualMachine(configuration: try makeConfiguration())
                    fresh.delegate = self
                    vm = fresh
                    beforeStart?(fresh)
                }
            }
            let options = VZMacOSVirtualMachineStartOptions()
            if let provisioning {
                try options.setGuestProvisioning(provisioning)
            }
            try await vm!.start(options: options)
            if provisioning != nil { try bundle.updateState { $0.provisioned = true } }
            bootCount += 1
            set(.running)
        } catch {
            vm = nil
            lastError = error.localizedDescription
            set(.error)
            throw error
        }
    }

    /// Saves the running VM to disk and stops it; the next `start` continues where it was.
    public func suspend() async throws {
        guard let vm, vm.state == .running || vm.state == .paused else { throw VMHostError.notRunning }
        if displayOverride != nil {
            restoreDisplay()
            // The guest takes a moment to switch back; the saved state should have the workspace's own size.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        set(.suspending)
        stopping = true
        defer { stopping = false }
        if vm.state == .running { try await vm.pause() }
        try await vm.saveMachineStateTo(url: bundle.savedStateURL)
        try await vm.stop()
        self.vm = nil
        forgetDisplay()
        set(.stopped)
    }

    /// Waits for the guest to power off by itself (after a shutdown inside the guest).
    public func waitUntilStopped(timeout: TimeInterval) async -> Bool {
        defer { stopping = false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm == nil || vm?.state == .stopped || vm?.state == .error { vm = nil; forgetDisplay(); set(.stopped); return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Asks the guest to shut down (like pressing the power button).
    public func requestStop() throws {
        guard let vm else { throw VMHostError.notRunning }
        stopping = true
        try vm.requestStop()
    }

    /// Pulls the plug. Only as a last resort: the guest loses unsaved state.
    public func forceStop() async throws {
        guard let vm else { return }
        set(.stopping)
        stopping = true
        defer { stopping = false }
        try await vm.stop()
        self.vm = nil
        forgetDisplay()
        set(.stopped)
    }

    /// The running VM, for a VZVirtualMachineView in the app.
    public var virtualMachine: VZVirtualMachine? { vm }

    // MARK: Display

    /// The display's size in pixels now: the bundle's, or what a phone asked for.
    public var displaySize: CGSize {
        if let o = displayOverride { return CGSize(width: o.width, height: o.height) }
        guard let s = try? bundle.loadState().settings else { return CGSize(width: 1280, height: 800) }
        return CGSize(width: s.displayWidth, height: s.displayHeight)
    }

    private var display: VZGraphicsDisplay? { vm?.graphicsDevices.first?.displays.first }

    /// Gives the running workspace's display another size (macOS in the guest follows within a second or two) for
    /// `lease` seconds: without a renewal (the same call again) it goes back to the workspace's own size, so a phone
    /// that vanished doesn't leave it in its shape. Returns the size it got.
    @discardableResult
    public func setDisplay(_ request: DisplayRequest, lease: TimeInterval, pixelsPerInch: Int? = nil) throws -> DisplayRequest {
        guard let display, vm?.state == .running else { throw VMHostError.notRunning }
        let r = request.clamped()
        if r != displayOverride || pixelsPerInch != nil {
            let config = VZMacGraphicsDisplayConfiguration(widthInPixels: r.width, heightInPixels: r.height,
                                                           pixelsPerInch: pixelsPerInch ?? r.pixelsPerInch)
            try display.reconfigure(configuration: config)
            displayOverride = r
            onDisplayChange?()
        }
        displayLease?.cancel()
        displayLease = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lease * 1_000_000_000))
            guard !Task.isCancelled, let self, self.displayOverride != nil else { return }
            self.restoreDisplay()
        }
        return r
    }

    /// The workspace's own display size again (VMSettings: 1280x800 at 110 pixels per inch).
    public func restoreDisplay() {
        displayLease?.cancel()
        displayLease = nil
        let changed = displayOverride != nil
        displayOverride = nil
        if let display, let s = try? bundle.loadState().settings {
            let config = VZMacGraphicsDisplayConfiguration(widthInPixels: s.displayWidth, heightInPixels: s.displayHeight,
                                                           pixelsPerInch: s.displayPPI)
            if display.sizeInPixels != CGSize(width: s.displayWidth, height: s.displayHeight) || changed {
                try? display.reconfigure(configuration: config)
            }
        }
        if changed { onDisplayChange?() }
    }

    private func forgetDisplay() {
        displayLease?.cancel()
        displayLease = nil
        if displayOverride != nil {
            displayOverride = nil
            onDisplayChange?()
        }
    }

    // MARK: Delegate

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard self.vm === virtualMachine else { return }
            self.vm = nil
            self.forgetDisplay()
            self.set(.stopped)
            if !self.stopping && self.restartsAfterGuestStop {
                // A restart inside the guest: boot again.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.vm == nil { try? await self.start() }
            }
        }
    }

    /// Marks the next guest stop as intended (orderly shutdown requested over SSH).
    public func expectStop() { stopping = true }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            if self.vm === virtualMachine {
                self.vm = nil
                self.forgetDisplay()
                self.lastError = error.localizedDescription
                self.set(.error)
            }
        }
    }

    // MARK: Network

    /// The guest's IP address from the host's DHCP leases (the VM uses a fixed MAC address).
    public func guestAddress() throws -> String? {
        let state = try bundle.loadState()
        return DHCPLeases.address(for: state.macAddress)
    }

    public func waitForAddress(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ip = try guestAddress() { return ip }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw VMHostError.noAddress
    }
}

/// Reads /var/db/dhcpd_leases (written by the host's DHCP server for VMs on the NAT network).
public enum DHCPLeases {
    public static var file = URL(fileURLWithPath: "/var/db/dhcpd_leases")

    public static func address(for mac: String) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text, mac: mac)
    }

    /// The lease file writes MAC octets without leading zeros ("1,a:2:3c:..."); compare normalized.
    static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet in
            let trimmed = octet.drop(while: { $0 == "0" })
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }

    static func parse(_ text: String, mac: String) -> String? {
        let wanted = normalize(mac)
        var best: (ip: String, lease: UInt64)?
        for block in text.components(separatedBy: "}") {
            var ip: String?, hw: String?, lease: UInt64 = 0
            for raw in block.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("ip_address=") { ip = String(line.dropFirst("ip_address=".count)) }
                if line.hasPrefix("hw_address=") {
                    let value = line.dropFirst("hw_address=".count)
                    hw = value.split(separator: ",", maxSplits: 1).last.map(String.init)
                }
                if line.hasPrefix("lease=") {
                    lease = UInt64(line.dropFirst("lease=0x".count), radix: 16) ?? 0
                }
            }
            if let ip, let hw, normalize(hw) == wanted, lease >= (best?.lease ?? 0) { best = (ip, lease) }
        }
        return best?.ip
    }
}
