import AOSKit
import AppKit
import Foundation

/// The guided setup of installing apps on the iPhone, once (the setup's step "Apps on your iPhone" and Settings >
/// Apps, "Set Up Step by Step"): Xcode and the team, a wildcard App ID, the iPhone on a cable (trust, Developer Mode),
/// the setup app built once in Xcode (certificate, device, profile), and the wireless connection. Every part is
/// recognized from the state of the Mac and the iPhone, so it can be left and resumed (Docs/DESIGN.md).
@MainActor
final class IPhoneSetupModel: ObservableObject {
    enum Part: Int, CaseIterable, Identifiable {
        case tools, appID, iphone, developerMode, signing, wireless
        var id: Int { rawValue }
    }

    /// An iPhone on the cable (or on Wi-Fi sync), as App/Resources/aos-devices-setup.py reports it.
    struct Device: Decodable, Equatable {
        var udid: String
        var connection: String
        var trusted: Bool
        var developerMode: Bool?
        var remotePaired: Bool
        var name: String?
        var ios: String?
        var locked: Bool?
        var problem: String?
    }

    @Published var xcode = false
    @Published var teams: [IPhoneDevSetup.Team] = []
    @Published var device: Device?
    @Published var signing: IPhoneDevSetup.Signing = .noProfile
    @Published var working: String?
    @Published var problem: String?
    @Published var projectOpened = false
    @Published private(set) var loaded = false
    /// The prefix being typed in the App ID part (saved with "Registered").
    @Published var prefixDraft = ""
    /// iPhones this Mac holds a wireless (RemotePairing) record for.
    @Published private(set) var paired: [String] = []

    let model: AppModel
    private var timer: Timer?
    private var refreshing = false
    private var trustAsked: Set<String> = []
    private var revealed: Set<String> = []
    private var pairingTried: Set<String> = []
    private var preview = false
    private var previewDone: Set<Part> = []

    init(model: AppModel) {
        self.model = model
    }

    // MARK: State

    var settings: AgentSettings { model.settings }
    var team: IPhoneDevSetup.Team? { teams.first { $0.id == settings.iphoneTeam } ?? teams.first }
    var suggestedPrefix: String {
        team.map { IPhoneDevSetup.suggestedPrefix(team: $0, profiles: ProvisioningProfile.all()) } ?? "com.example"
    }
    var prefix: String { settings.iphonePrefix.isEmpty ? suggestedPrefix : settings.iphonePrefix }
    /// The iPhone this setup is about: the one on the cable, else the one paired earlier.
    var udid: String? { device?.udid ?? paired.first }
    var connected: Bool { model.devices.map { $0.isFresh() && $0.isConnected } == true }

    func isDone(_ part: Part) -> Bool {
        if preview { return previewDone.contains(part) }
        switch part {
        case .tools:
            return model.deviceRuntimeReady && xcode && team != nil && settings.iphoneApps
        case .appID:
            if team?.isFree == true { return true }
            if case .ready = signing { return true }
            return !settings.iphonePrefix.isEmpty
        case .iphone:
            if let device { return device.trusted }
            return !paired.isEmpty  // its wireless record exists: it was trusted
        case .developerMode:
            if let device { return device.developerMode == true }
            return !paired.isEmpty  // the record is made only once Developer Mode is on
        case .signing:
            if case .ready = signing { return true }
            return team?.isFree == true && signing == .exactOnly
        case .wireless:
            return connected
        }
    }

    /// The first part that isn't done (nil: all done).
    var current: Part? { Part.allCases.first { !isDone($0) } }
    var finished: Bool { loaded && current == nil }

    // MARK: Watching

    func start() {
        guard timer == nil, !preview else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !refreshing, !preview else { return }
        refreshing = true
        defer { refreshing = false }
        xcode = IPhoneDevSetup.xcodeInstalled()
        let found = IPhoneDevSetup.xcodeTeams()
        if found != teams { teams = found }
        if prefixDraft.isEmpty, team != nil { prefixDraft = prefix }
        model.refreshDevices(loginItems: false)
        let records = DeviceInstaller.pairedDevices()
        if records != paired { paired = records }
        if model.deviceRuntimeReady, working == nil {
            if let answer = await helper(["status"]), let list = answer["devices"] as? [[String: Any]] {
                let devices = list.compactMap { Self.decode($0) }
                let next = devices.first { $0.connection == "USB" } ?? devices.first
                if next != device { device = next }
            }
        }
        let signer = await IOSAppSigner.current()
        let state = IPhoneDevSetup.signing(signer, team: team?.id ?? "", prefix: prefix, udid: udid)
        if state != signing { signing = state }
        loaded = true
        await advance()
    }

    /// What happens by itself: the Trust question once a new iPhone is on the cable, the Developer Mode switch shown,
    /// the wireless record made once Developer Mode is on.
    private func advance() async {
        guard let device, working == nil else { return }
        if !device.trusted, device.locked != true, device.connection == "USB", !trustAsked.contains(device.udid) {
            trustAsked.insert(device.udid)
            await trust()
        } else if device.trusted, device.developerMode == false, !revealed.contains(device.udid) {
            revealed.insert(device.udid)
            await revealDeveloperMode()
        } else if device.trusted, device.developerMode == true, !device.remotePaired, !pairingTried.contains(device.udid) {
            pairingTried.insert(device.udid)
            await pairWireless()
        }
    }

    // MARK: Actions

    /// Turns installing on the iPhone on and downloads the environment the iPhone steps need.
    func setUp() {
        model.update { $0.iphoneApps = true }
        if !model.deviceRuntimeReady { model.setUpDevices() }
    }

    func chooseTeam(_ id: String) {
        model.update { $0.iphoneTeam = id }
        prefixDraft = prefix
    }

    func getXcode() {
        NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
    }

    func openXcode() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openIdentifiers() {
        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/account/resources/identifiers/add/bundleId")!)
    }

    var prefixDraftValid: Bool { IPhoneDevSetup.isValidPrefix(prefixDraft.trimmingCharacters(in: .whitespaces)) }

    /// The person registered the wildcard App ID for the prefix.
    func confirmPrefix() {
        let value = prefixDraft.trimmingCharacters(in: .whitespaces)
        guard IPhoneDevSetup.isValidPrefix(value) else { return }
        model.update {
            $0.iphonePrefix = value
            if let team = self.team { $0.iphoneTeam = team.id }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func trust() async {
        guard let udid = device?.udid else { return }
        problem = nil
        working = String(localized: "Waiting for Trust on your iPhone …")
        let answer = await helper(["trust", udid], timeout: 150)
        working = nil
        if let error = answer?["error"] as? String { problem = error }
        await refresh()
    }

    func revealDeveloperMode() async {
        guard let udid = device?.udid else { return }
        problem = nil
        working = String(localized: "Showing the switch on your iPhone …")
        let answer = await helper(["reveal", udid])
        working = nil
        if let error = answer?["error"] as? String { problem = error }
    }

    func pairWireless() async {
        guard let udid = device?.udid else { return }
        problem = nil
        working = String(localized: "Pairing for the wireless connection …")
        let answer = await helper(["remotepair", udid], timeout: 60)
        working = nil
        if let error = answer?["error"] as? String { problem = error }
        model.reconnectDevices()  // the worker looks for the iPhone again at once, with the new record
        await refresh()
    }

    /// Writes the setup app for the team and the prefix and opens it in Xcode.
    func openSetupApp() {
        guard let team else { return }
        problem = nil
        let bundleID = team.isFree
            ? "\(prefix).aossetup.\(team.id.lowercased())"  // free teams share no namespace: unique per team
            : IPhoneDevSetup.setupBundleID(prefix: prefix)
        do {
            let project = try SetupAppProject.write(
                to: model.paths.devices.appendingPathComponent("Setup App", isDirectory: true),
                bundleID: bundleID, team: team.id,
                title: String(localized: "\(Brand.name) is set up"),
                message: String(localized: "Your agents' apps now come to this iPhone. You can delete this app."))
            NSWorkspace.shared.open(project)
            projectOpened = true
            if settings.iphoneTeam.isEmpty || settings.iphonePrefix.isEmpty {
                model.update {
                    $0.iphoneTeam = team.id
                    if $0.iphonePrefix.isEmpty { $0.iphonePrefix = self.prefix }
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: The helper

    private func helper(_ arguments: [String], timeout: TimeInterval = 30) async -> [String: Any]? {
        let python = DeviceRuntime.python(model.paths).path
        let script = DeviceRuntime.setupHelper(in: model.deviceResources).path
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        guard let result = try? await Subprocess.run(python, ["-I", "-B", script] + arguments, environment: env,
                                                     timeout: timeout) else { return nil }
        let line = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func decode(_ object: [String: Any]) -> Device? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Device.self, from: data)
    }

    // MARK: Design review

    /// AOS_PREVIEW: a team, the iPhone on the cable and trusted, Developer Mode still off.
    func showPreview() {
        preview = true
        // AOS_PREVIEW_PART=<1…6>: the part that is open (default 4, Developer Mode)
        let open = Int(ProcessInfo.processInfo.environment["AOS_PREVIEW_PART"] ?? "") ?? 4
        previewDone = Set(Part.allCases.filter { $0.rawValue < open - 1 })
        stop()
        xcode = true
        teams = [IPhoneDevSetup.Team(id: "S3725YB7V6", name: "Maximilian Marquart", isFree: false)]
        prefixDraft = "dev.marquart"
        device = Device(udid: "00008140-00111D6801EB001C", connection: "USB", trusted: true, developerMode: false,
                        remotePaired: false, name: "iPhone von Max", ios: "27.2")
        signing = .noProfile
        loaded = true
    }
}
