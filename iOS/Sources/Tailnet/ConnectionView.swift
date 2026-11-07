import AOSTailnet
import SwiftUI

/// Settings > Connection: how this iPhone reaches the Mac now, the Mac's way on the go, aOS's Tailscale on this
/// iPhone (set up, signed in, its devices) and what to do. Users, access rules and other devices stay in Tailscale's
/// admin console.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    private var tailnet: EmbeddedTailnet { EmbeddedTailnet.shared }
    @State private var vpnActive = TailnetVPN.isActive
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Now") {
                    Text(Self.routeText(model.connection)).multilineTextAlignment(.trailing)
                }
                if let mac = model.activeMac {
                    LabeledContent("\(mac.name) on the go") {
                        Text(Self.wayText(mac)).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("The connection")
            } footer: {
                Text("The iPhone tries the same network first, then the tailnet, then the Mac's name on the network.")
            }

            if let mac = model.activeMac, Self.usesTailnet(mac) {
                if mac.way == .tailscaleApp || !ConnectionPlan.tailnetHosts(of: mac).isEmpty {
                    Section {
                        LabeledContent("Tailscale app on this iPhone") {
                            Label(vpnActive ? String(localized: "VPN on") : String(localized: "VPN off"),
                                  systemImage: vpnActive ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(vpnActive ? BrandColor.mint : .secondary)
                        }
                        if mac.way == .tailscaleApp && !vpnActive && !tailnet.isSetUp {
                            Link(destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!) {
                                Label("Get the Tailscale App", systemImage: "arrow.down.app")
                            }
                        }
                    } footer: {
                        Text("Your Mac uses the Tailscale app. On this iPhone the Tailscale app, signed in with the same account, reaches it too; so does aOS's own Tailscale below.")
                    }
                }
                nodeSection(mac)
            }

            if tailnet.isSetUp, let status = tailnet.status, status.isRunning {
                Section {
                    ForEach(status.aosDevices) { device in DeviceRow(device: device, isThisDevice: device.id == status.device?.id) }
                } header: {
                    Text("aOS devices")
                } footer: {
                    Text("Users, access rules and your other devices are in Tailscale's admin console.")
                }
            }

            if tailnet.isSetUp {
                Section {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        tailnet.reconnect()
                        model.connection?.retryNow()
                    }
                    .disabled(tailnet.working)
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmSignOut = true
                    }
                    .disabled(tailnet.working)
                } footer: {
                    Text("Sign Out removes this iPhone from the tailnet and deletes its Tailscale keys here.")
                }
            }
            Section {
                Button("Open the Tailscale Admin Console", systemImage: "safari") {
                    openURL(URL(string: "https://login.tailscale.com/admin/machines")!)
                }
            } footer: {
                Text("If you install the Tailscale app later and sign in with the same account, aOS's devices appear in the same tailnet, and you manage them there like any other device. The Tailscale app can't take over aOS's connection.")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                vpnActive = TailnetVPN.isActive
                await tailnet.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Sign out of Tailscale on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await tailnet.signOut()
                    model.connection?.retryNow()
                }
            }
        } message: {
            Text("This iPhone leaves your tailnet. On the go it then reaches the Mac only through the Tailscale app, if it has it.")
        }
    }

    @ViewBuilder func nodeSection(_ mac: PairedMac) -> some View {
        Section {
            if !tailnet.isSetUp {
                Text(mac.way == .aosTailscale
                     ? "Your Mac uses aOS's own Tailscale. Set it up here too: you sign in once with your Tailscale account, the same as on the Mac."
                     : "aOS can bring Tailscale along on this iPhone too: no VPN, no extra app. You sign in once with your Tailscale account, the same as on the Mac.")
                    .font(.subheadline)
                if let name = mac.tailnetName {
                    LabeledContent("Tailnet of the Mac", value: name)
                }
                Button {
                    tailnet.setUp(deviceName: model.deviceName)
                } label: {
                    Label("Set Up Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(tailnet.working)
            } else if let status = tailnet.status, status.isRunning, let device = status.device {
                LabeledContent("Name", value: device.dnsName.isEmpty ? device.hostName : device.dnsName)
                LabeledContent("Address", value: device.addresses.first ?? "")
                if let name = status.tailnet { LabeledContent("Tailnet", value: name) }
                LabeledContent("Tailscale key", value: DeviceRow.keyLine(device))
                if let expected = mac.tailnetName, let name = status.tailnet, expected != name {
                    Label("Your Mac is in the tailnet \(expected). Sign out here and sign in with that account.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                } else if status.peers.isEmpty == false, ConnectionPlan.macNode(of: mac, in: status) == nil {
                    Label("Your Mac isn't in this tailnet. Sign in with the account you used on the Mac.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } else if tailnet.signingIn {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Sign in to Tailscale on the page that opened.")
                }
            } else if tailnet.status?.needsApproval == true {
                Text("Signed in. The tailnet's admin still has to approve this iPhone in the Tailscale admin console.")
            } else {
                if let problem = tailnet.problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await tailnet.signIn() }
                } label: {
                    Label("Sign In to Tailscale", systemImage: "person.badge.key")
                }
                .disabled(tailnet.working)
            }
        } header: {
            Text("aOS's Tailscale on this iPhone")
        } footer: {
            Text("No VPN and no Tailscale app needed. aOS only reaches your Mac through it, and nothing on this iPhone is reachable in your tailnet. Its keys stay on this iPhone, out of backups.")
        }
    }

    /// The Mac reaches the tailnet one way or another (or the pairing doesn't say).
    static func usesTailnet(_ mac: PairedMac) -> Bool { mac.way != .localNetwork }

    static func wayText(_ mac: PairedMac) -> String {
        switch mac.way {
        case .tailscaleApp?: String(localized: "through the Tailscale app")
        case .aosTailscale?: String(localized: "through aOS's Tailscale")
        case .localNetwork?: String(localized: "only on the same network")
        case nil:
            ConnectionPlan.tailnetHosts(of: mac).isEmpty
                ? String(localized: "not chosen (pair again to choose)") : String(localized: "through Tailscale")
        }
    }

    static func routeText(_ connection: MacConnection?) -> String {
        guard let connection, connection.isConnected, let route = connection.route else {
            return String(localized: "not connected")
        }
        switch route {
        case .tailnet(let host): return String(localized: "aOS's Tailscale (\(host))")
        case .host(let host) where TailnetAddress.isTailnetHost(host): return String(localized: "Tailscale app (\(host))")
        case .host(let host): return String(localized: "same network (\(host))")
        case .bonjour: return String(localized: "same network, found by name")
        }
    }
}

/// One of aOS's devices in the tailnet: online or last seen, and its key.
struct DeviceRow: View {
    let device: TailnetDevice
    var isThisDevice = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.os == "iOS" ? "iphone" : "laptopcomputer").foregroundStyle(BrandColor.indigo).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.hostName)
                    if isThisDevice { Text("this iPhone").font(.footnote).foregroundStyle(.secondary) }
                }
                Text(Self.presence(device, isThisDevice: isThisDevice) + " · " + Self.keyLine(device))
                    .font(.footnote)
                    .foregroundStyle(device.expired ? Color.orange : Color.secondary)
            }
        }
    }

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
