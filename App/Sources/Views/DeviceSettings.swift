import AOSKit
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Apps: aOS puts iPhone apps on the person's iPhone through a tunnel it holds (Docs/DESIGN.md,
/// "Installing apps on the iPhone"): the switch, the environment, the connection, the installs, signing.
struct DeviceSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var signing: String?
    @State private var signingWarning = false
    @State private var pairing = false
    @State private var pairError: String?
    @State private var installError: String?
    @State private var showGuide = false

    var body: some View {
        Form {
            SettingsHeader(symbol: "apps.iphone", title: "Apps on your iPhone",
                           detail: "Your agents build iPhone apps, and \(Brand.name) puts them on your iPhone within seconds: at home and on the go, without a cable.")
            Section {
                Toggle("Install apps on my iPhone", isOn: Binding(get: { model.settings.iphoneApps },
                                                                  set: { v in model.update { $0.iphoneApps = v } }))
                Text("\(Brand.name) keeps a connection to your iPhone. It comes up whenever the iPhone is on any Wi-Fi, and then also holds on cellular, until the iPhone restarts. Your iPhone and this Mac need Tailscale, and Developer Mode must be on on the iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("New here, or a new iPhone? The guide takes you through it once: Xcode, signing, the cable, Developer Mode.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up Step by Step …") { showGuide = true }
                }
                if model.settings.iphoneApps {
                    environmentRow
                    if model.deviceRuntimeReady { connectionRows }
                }
            } header: {
                Text("Installing on the iPhone")
            }
            if model.settings.iphoneApps && model.deviceRuntimeReady {
                installsSection
                Section {
                    if let signing {
                        Label(signing, systemImage: signingWarning ? "exclamationmark.triangle" : "checkmark.seal")
                            .foregroundStyle(signingWarning ? .orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("\(Brand.name) signs every app with your development certificate and a profile that covers it and your iPhone, like Xcode does for a device build. A wildcard profile of your team covers every app.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Signing")
                }
                advancedSection
            }
        }
        .formStyle(.grouped)
        .task(id: model.devices?.device?.udid) { await loadSigning() }
        .sheet(isPresented: $showGuide) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Apps on your iPhone").font(.title2.bold())
                        IPhoneAppsSetupView(setup: model.iphoneSetup)
                    }
                    .padding(24)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showGuide = false }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 640, height: 720)
            .environmentObject(model)
        }
    }

    // MARK: Environment

    @ViewBuilder var environmentRow: some View {
        switch model.deviceSetup {
        case .running(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Self.stepText(step))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { model.setUpDevices() }
        case .idle:
            if !model.deviceRuntimeReady {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One-time setup")
                        Text("\(Brand.name) downloads Python and pymobiledevice3 (about 80 MB) into its own folder. Nothing else on your Mac changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up") { model.setUpDevices() }
                }
            }
        }
    }

    static func stepText(_ step: DeviceRuntime.Step) -> String {
        switch step {
        case .downloadingUV: return String(localized: "Downloading uv …")
        case .installingPython: return String(localized: "Installing Python …")
        case .creatingEnvironment: return String(localized: "Creating the environment …")
        case .installingPackages: return String(localized: "Installing pymobiledevice3 …")
        case .ready: return String(localized: "Ready")
        }
    }

    // MARK: Connection

    @ViewBuilder var connectionRows: some View {
        let status = model.devices.flatMap { $0.isFresh() ? $0 : nil }
        if let status {
            Label(stateText(status), systemImage: stateSymbol(status))
                .foregroundStyle(status.isConnected && !status.isOffline ? Color.green
                                 : (status.state == .notPaired ? .orange : .secondary))
            if let device = status.device {
                LabeledContent("iPhone") {
                    Text(verbatim: [device.name, device.ios.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: ", "))
                }
                if let address = device.address {
                    LabeledContent("Address") {
                        Text(verbatim: device.addressName.map { $0 == address ? address : "\($0) (\(address))" } ?? address)
                            .textSelection(.enabled)
                    }
                }
            }
            if let since = status.since, status.isConnected {
                LabeledContent("Connected since") { Text(since, format: .dateTime.weekday().hour().minute()) }
            }
            if let last = status.history.last {
                LabeledContent("Previous connection") {
                    Text(verbatim: String(localized: "held \(Self.duration(last.seconds))"))
                }
            }
            if status.state == .notPaired {
                HStack {
                    Text("Connect your iPhone to this Mac with a cable once, unlock it and tap Trust if it asks.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(pairing ? String(localized: "Pairing …") : String(localized: "Pair")) {
                        pairing = true
                        Task {
                            pairError = await model.pairIPhone()
                            pairing = false
                        }
                    }
                    .disabled(pairing)
                }
                if let pairError { Text(pairError).font(.caption).foregroundStyle(.orange) }
            }
        } else if model.devicesAgentStatus == .requiresApproval {
            Label("macOS asks you to allow the background item of \(Brand.name): System Settings > General > Login Items.",
                  systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting …")
            }
        }
    }

    func stateText(_ status: DeviceStatus) -> String {
        let name = status.device?.name ?? String(localized: "your iPhone")
        switch status.state {
        case .connected:
            if status.isOffline { return String(localized: "Connected to \(name), offline right now: the connection waits") }
            return status.network == "cellular"
                ? String(localized: "Connected to \(name), on cellular")
                : String(localized: "Connected to \(name), on Wi-Fi")
        case .connecting: return String(localized: "Connecting to \(name) …")
        case .notPaired: return String(localized: "This Mac isn't paired with an iPhone yet.")
        default: return String(localized: "Waiting for \(name) to be on Wi-Fi")
        }
    }

    func stateSymbol(_ status: DeviceStatus) -> String {
        switch status.state {
        case .connected:
            if status.isOffline { return "antenna.radiowaves.left.and.right.slash" }
            return status.network == "cellular" ? "antenna.radiowaves.left.and.right" : "wifi"
        case .notPaired: return "cable.connector"
        default: return "hourglass"
        }
    }

    static func duration(_ seconds: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    // MARK: Installs

    var installsSection: some View {
        Section {
            let jobs = model.devices?.jobs ?? []
            if jobs.isEmpty {
                Text("Nothing installed yet. Your agents use the tool iphone_install, or install an app here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(jobs.prefix(10)) { job in JobRow(job: job) }
            HStack {
                Button("Install an App …") { chooseApp() }
                if let installError { Text(installError).font(.caption).foregroundStyle(.orange) }
            }
        } header: {
            Text("Installed")
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose an iPhone app built for a device (.app) or an .ipa.")
        panel.allowedContentTypes = [.applicationBundle, UTType(filenameExtension: "ipa") ?? .data]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installError = nil
        let paths = model.paths
        Task {
            do {
                _ = try await DeviceInstaller(paths: paths).submit(path: url.path, source: "Mac")
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    // MARK: Signing

    func loadSigning() async {
        let udid = model.devices?.device?.udid ?? DeviceInstaller.pairedDevices().first
        let signer = await IOSAppSigner.current()
        guard let udid else {
            signing = String(localized: "Signing is checked once an iPhone is paired.")
            signingWarning = false
            return
        }
        // A wildcard covers whatever an agent builds; check with an id it would cover.
        let wildcard = signer.profiles.filter { $0.isWildcard && $0.expiration > Date() && $0.covers(device: udid) }
            .sorted { $0.expiration > $1.expiration }
        if let profile = wildcard.first,
           let identity = signer.identities.first(where: { profile.certificateFingerprints.contains($0.fingerprint) }) {
            signing = String(localized: "\(identity.name), profile \(profile.name) (\(profile.applicationIdentifier)), valid until \(profile.expiration.formatted(date: .abbreviated, time: .omitted))")
            signingWarning = false
        } else {
            signing = String(localized: "No wildcard development profile covers this iPhone. Apps install only if Xcode has a profile for their exact bundle id. In Xcode, build any app of your team for this iPhone once to get one.")
            signingWarning = true
        }
    }

    // MARK: Advanced

    var advancedSection: some View {
        Section {
            TextField("iPhone address", text: Binding(get: { model.settings.iphoneAddress },
                                                      set: { v in model.update { $0.iphoneAddress = v.trimmingCharacters(in: .whitespaces) } }),
                      prompt: Text("Found through Tailscale"))
            Picker("Online check", selection: Binding(get: { model.settings.iphoneHeartbeat },
                                                    set: { v in model.update { $0.iphoneHeartbeat = v } })) {
                ForEach([15, 30, 60, 120], id: \.self) { s in Text(verbatim: "\(s) s").tag(s) }
                if ![15, 30, 60, 120].contains(model.settings.iphoneHeartbeat) {
                    Text(verbatim: "\(model.settings.iphoneHeartbeat) s").tag(model.settings.iphoneHeartbeat)
                }
            }
            Text("How often \(Brand.name) pings your iPhone to know whether it's online. The connection itself stays quiet: \(Brand.name) uses it only for installs and for a check when the iPhone joins a Wi-Fi network, so it holds through hours without a network.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reconnect") { model.reconnectDevices() }
                .disabled(model.devices?.isFresh() != true)
        } header: {
            Text("Advanced")
        }
    }
}

private struct JobRow: View {
    let job: DeviceJob

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: [job.name, job.version].compactMap { $0 }.joined(separator: " "))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(job.finished ?? job.created, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
    }

    var symbol: String {
        switch job.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .installing: return "arrow.down.circle"
        default: return "clock"
        }
    }

    var tint: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    var detail: String {
        var parts: [String] = [job.bundleId]
        if let source = job.source { parts.append(source) }
        switch job.state {
        case .done:
            if let s = job.seconds { parts.append(String(localized: "\(Int(s.rounded())) s")) }
            if job.network == "cellular" { parts.append(String(localized: "on cellular")) }
        case .failed:
            if let m = job.message { parts.append(m) }
        case .queued:
            parts.append(String(localized: "waits for the connection"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
