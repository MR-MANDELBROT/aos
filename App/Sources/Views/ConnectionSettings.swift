import AOSKit
import SwiftUI

/// The three ways the iPhone reaches this Mac on the go, always all three, the recommended one marked: the setup's
/// step before pairing and Settings > Connection show them.
struct ReachWayChoices: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tailnet = TailnetController.shared
    /// In a settings form: rows instead of glass cards.
    var inForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: inForm ? 14 : 10) {
            ForEach(ReachWay.allCases) { way in
                if inForm {
                    choice(way)
                    if way != ReachWay.allCases.last { Divider() }
                } else {
                    GlassCard { choice(way) }
                }
            }
        }
        .onAppear { tailnet.refresh() }
    }

    func choice(_ way: ReachWay) -> some View {
        let selected = model.settings.reachWay == way
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                let old = model.settings.reachWay
                model.update { $0.reachWay = way }
                tailnet.wayChanged(from: old, to: way)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? BrandColor.indigo : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(Self.title(way)).fontWeight(.semibold)
                            if tailnet.app != nil, tailnet.recommended == way { RecommendedBadge() }
                        }
                        Text(detail(way)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Group {
                switch way {
                case .tailscaleApp: appState
                case .aosTailscale: if selected { NodeState() }
                case .localNetwork: EmptyView()
                }
            }
            .padding(.leading, 32)
        }
    }

    static func title(_ way: ReachWay) -> String {
        switch way {
        case .tailscaleApp: return String(localized: "Your Tailscale app")
        case .aosTailscale: return String(localized: "\(Brand.name) sets up Tailscale")
        case .localNetwork: return String(localized: "Only on the same network (SSH)")
        }
    }

    func detail(_ way: ReachWay) -> String {
        switch way {
        case .tailscaleApp:
            return String(localized: "Tailscale runs on this Mac. \(Brand.name) puts this Mac's Tailscale address into the pairing code. On your iPhone you need the Tailscale app too, signed in with the same account.")
        case .aosTailscale:
            return String(localized: "\(Brand.name) brings Tailscale along, on this Mac and in \(Brand.name) on your iPhone: no VPN, no extra app. You sign in once on each device, in the browser, with your Tailscale account (you can create one there). In your tailnet only this Mac's SSH is reachable, nothing else.")
        case .localNetwork:
            return String(localized: "Your iPhone reaches this Mac on the same Wi-Fi, or when the Mac is on your iPhone's hotspot. Nothing to set up.")
        }
    }

    @ViewBuilder var appState: some View {
        switch tailnet.app {
        case nil:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Tailscale …").font(.callout) }
        case .notInstalled?:
            Label("Tailscale isn't on this Mac.", systemImage: "minus.circle").font(.callout).foregroundStyle(.secondary)
        case .notConnected?:
            Label("Tailscale is on this Mac but not connected. Open it and sign in, then click Check Again.",
                  systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.orange)
        case .connected(let status)?:
            ConnectedLine(status: status)
        }
    }
}

/// "Connected: <name> (<address>)" and the tailnet.
struct ConnectedLine: View {
    let status: TailnetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("Connected: \(status.device?.dnsName ?? "") (\(status.device?.ipv4 ?? ""))").textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
            if let tailnet = status.tailnet {
                Text("Tailnet: \(tailnet)").font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            }
        }
    }
}

/// aOS's own node: set it up, sign in, or what it is doing.
struct NodeState: View {
    @ObservedObject var tailnet = TailnetController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = tailnet.helperProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            } else if let status = tailnet.nodeStatus, status.isRunning {
                ConnectedLine(status: status)
            } else if tailnet.waitingForSignIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sign in to Tailscale in your browser. \(Brand.name) waits here.").font(.callout)
                }
                Button("Open the Sign-In Page Again") { tailnet.signIn() }.buttonStyle(.glass).disabled(tailnet.working)
            } else if tailnet.nodeStatus?.needsApproval == true {
                Label("Signed in. The tailnet's admin still has to approve this Mac in the Tailscale admin console.",
                      systemImage: "hourglass")
                    .font(.callout)
                Button("Open the Admin Console") { tailnet.openAdminConsole() }.buttonStyle(.glass)
            } else if tailnet.nodeEnabled {
                Label("Sign in to Tailscale again: you signed out, or this Mac's key expired.", systemImage: "key")
                    .font(.callout)
                Button("Sign In …") { tailnet.signIn() }.buttonStyle(.glassProminent).disabled(tailnet.working)
            } else {
                HStack(spacing: 10) {
                    Button("Set Up Tailscale …") { tailnet.setUp() }.buttonStyle(.glassProminent).disabled(tailnet.working)
                    if tailnet.working { ProgressView().controlSize(.small) }
                }
                Text("Your browser opens Tailscale's sign-in page. \(Brand.name) never sees your Tailscale account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = tailnet.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Text("If you install the Tailscale app later and sign in with the same account, \(Brand.name)'s devices appear in the same tailnet, and you manage them there like any other device. The Tailscale app can't take over \(Brand.name)'s connection.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings > Connection: the way in use, this Mac in the tailnet, aOS's devices and what to do.
struct ConnectionSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tailnet = TailnetController.shared
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            SettingsHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Reaching this Mac on the go",
                           detail: "At home your iPhone reaches this Mac by itself. On the go it goes through Tailscale, a private network of your own devices.")
            Section {
                ReachWayChoices(inForm: true)
            } header: {
                Text("Way")
            } footer: {
                Text("After you change the way, pair your iPhone again: the pairing code tells it how to reach this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = shownStatus, let device = status.device {
                Section("This Mac in the tailnet") {
                    LabeledContent("Name", value: device.dnsName.isEmpty ? device.hostName : device.dnsName)
                    LabeledContent("Address", value: device.addresses.joined(separator: ", "))
                    if let name = status.tailnet { LabeledContent("Tailnet", value: name) }
                    if let user = status.user { LabeledContent("Account", value: user) }
                    LabeledContent("Key", value: TailnetText.keyLine(device))
                }
                Section {
                    if status.aosDevices.isEmpty {
                        Text("No \(Brand.name) devices in this tailnet yet.").foregroundStyle(.secondary)
                    }
                    ForEach(status.aosDevices) { device in DeviceRow(device: device, isThisMac: device.id == status.device?.id) }
                } header: {
                    Text("\(Brand.name) devices")
                } footer: {
                    Text("Users, access rules and your other devices are in Tailscale's admin console.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.reachWay == .aosTailscale || model.settings.reachWay == .tailscaleApp {
                Section {
                    HStack(spacing: 10) {
                        if model.settings.reachWay == .aosTailscale && tailnet.nodeEnabled {
                            Button("Reconnect") { tailnet.reconnect() }.buttonStyle(.glass).disabled(tailnet.working)
                            Button("Sign Out …", role: .destructive) { confirmSignOut = true }
                                .buttonStyle(.glass).disabled(tailnet.working)
                        } else if model.settings.reachWay == .tailscaleApp {
                            Button("Check Again") { tailnet.refresh() }.buttonStyle(.glass)
                        }
                        Button("Open the Tailscale Admin Console") { tailnet.openAdminConsole() }.buttonStyle(.glass)
                        if tailnet.working { ProgressView().controlSize(.small) }
                    }
                } footer: {
                    if model.settings.reachWay == .aosTailscale {
                        Text("Sign Out removes this Mac from the tailnet and deletes its Tailscale keys. Its keys are kept by \(Brand.name)'s background helper, where no other program of yours can read them.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(Brand.name) only reads the Tailscale app's status and never changes its settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { tailnet.refresh() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if model.settings.reachWay == .aosTailscale { Task { await tailnet.readNode() } }
        }
        .alert("Sign out of Tailscale?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { tailnet.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac leaves your tailnet. Your iPhone then reaches it only on the same network, until you set Tailscale up again.")
        }
    }

    /// The node of the way in use: aOS's own, or the Tailscale app's.
    var shownStatus: TailnetStatus? {
        switch model.settings.reachWay {
        case .aosTailscale?: return tailnet.nodeStatus?.isRunning == true ? tailnet.nodeStatus : nil
        case .tailscaleApp?: return tailnet.app?.status
        default: return nil
        }
    }
}

/// One of aOS's devices: online or last seen, and its key.
struct DeviceRow: View {
    let device: TailnetDevice
    var isThisMac = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.os == "iOS" ? "iphone" : "laptopcomputer").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.hostName)
                    if isThisMac { Text("this Mac").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    StatusDot(color: device.online || isThisMac ? .green : .secondary)
                    Text(TailnetText.presence(device, isThisDevice: isThisMac)).font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(TailnetText.keyLine(device)).font(.caption)
                        .foregroundStyle(device.expired ? Color.orange : Color.secondary)
                }
            }
        }
    }
}

enum TailnetText {
    static func presence(_ device: TailnetDevice, isThisDevice: Bool) -> String {
        if device.online || isThisDevice { return String(localized: "online") }
        guard let seen = device.lastSeen else { return String(localized: "offline") }
        return String(localized: "last seen \(seen.formatted(.relative(presentation: .named)))")
    }

    static func keyLine(_ device: TailnetDevice) -> String {
        if device.expired { return String(localized: "key expired") }
        guard let expiry = device.keyExpiry else { return String(localized: "key doesn't expire") }
        return String(localized: "key expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
    }
}
