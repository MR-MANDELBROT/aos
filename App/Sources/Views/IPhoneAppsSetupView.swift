import AOSKit
import SwiftUI

/// The guided setup of installing apps on the iPhone (IPhoneSetupModel): the parts one below the other, the open one
/// expanded with what to do, the finished ones ticked with a word on what they found. In the setup (its step "Apps on
/// your iPhone") and as a sheet of Settings > Apps.
struct IPhoneAppsSetupView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var setup: IPhoneSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(IPhoneSetupModel.Part.allCases) { part in
                PartCard(number: part.rawValue + 1, title: title(part), summary: summary(part),
                         state: state(part)) {
                    content(part)
                }
            }
            if let working = setup.working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working) }
                    .font(.callout).padding(.horizontal, 4)
            }
            if let problem = setup.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .textSelection(.enabled).padding(.horizontal, 4)
            }
        }
        .onAppear { setup.start() }
        .onDisappear { setup.stop() }
    }

    func state(_ part: IPhoneSetupModel.Part) -> SetupPartState {
        if !setup.loaded { return .later }
        if setup.isDone(part) { return .done }
        return part == setup.current ? .open : .later
    }

    func title(_ part: IPhoneSetupModel.Part) -> String {
        switch part {
        case .tools: return String(localized: "Xcode and your Apple account")
        case .appID: return String(localized: "An App ID for all your apps")
        case .iphone: return String(localized: "Connect your iPhone")
        case .developerMode: return String(localized: "Developer Mode")
        case .signing: return String(localized: "Signing for your iPhone")
        case .wireless: return String(localized: "Without a cable")
        }
    }

    func summary(_ part: IPhoneSetupModel.Part) -> String? {
        guard setup.isDone(part) else { return nil }
        switch part {
        case .tools: return setup.team.map { String(localized: "Team \($0.name)") }
        case .appID:
            if setup.team?.isFree == true { return String(localized: "Not with a free account") }
            return String(localized: "Apps under \(setup.prefix).*")
        case .iphone:
            guard let device = setup.device else { return String(localized: "Paired") }
            return [device.name, device.ios.map { "iOS \($0)" }].compactMap { $0 }.joined(separator: ", ")
        case .developerMode: return String(localized: "On")
        case .signing:
            if case .ready(let pattern, _, let expires) = setup.signing {
                return String(localized: "\(pattern), until \(expires.formatted(date: .abbreviated, time: .omitted))")
            }
            return String(localized: "Only apps you build in Xcode")
        case .wireless: return model.devices?.device?.name.map { String(localized: "Connected to \($0)") } ?? String(localized: "Connected")
        }
    }

    // MARK: The parts

    @ViewBuilder func content(_ part: IPhoneSetupModel.Part) -> some View {
        switch part {
        case .tools: tools
        case .appID: appID
        case .iphone: iphone
        case .developerMode: developerMode
        case .signing: signing
        case .wireless: wireless
        }
    }

    @ViewBuilder var tools: some View {
        if !setup.xcode {
            Text("Install Xcode from the App Store. It builds your agents' apps and makes the signing for your iPhone.")
            Button("Get Xcode") { setup.getXcode() }.buttonStyle(.glassProminent)
        } else if setup.teams.isEmpty {
            Text("Sign in to Xcode with your Apple account:")
            numbered(1, "Open Xcode, then Xcode > Settings > Accounts.")
            numbered(2, "Click +, choose Apple Account and sign in.")
            Button("Open Xcode") { setup.openXcode() }.buttonStyle(.glassProminent)
        } else {
            if setup.teams.count > 1 {
                Picker("Team", selection: Binding(get: { setup.team?.id ?? "" }, set: { setup.chooseTeam($0) })) {
                    ForEach(setup.teams) { team in
                        Text(verbatim: team.isFree ? "\(team.name) (\(String(localized: "free")))" : team.name).tag(team.id)
                    }
                }
                .pickerStyle(.menu).fixedSize()
            } else if let team = setup.team {
                Label(String(localized: "Team \(team.name)"), systemImage: "person.crop.circle.badge.checkmark")
            }
            if setup.team?.isFree == true {
                Text("This is a free Apple account: your iPhone takes only apps you built once in Xcode yourself, and they run for 7 days. With the Apple Developer Program, \(Brand.name) installs every app of your agents.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            switch model.deviceSetup {
            case .running(let step):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(DeviceSettings.stepText(step)) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Try Again") { setup.setUp() }.buttonStyle(.glass)
            case .idle:
                Text("\(Brand.name) downloads Python and pymobiledevice3 (about 80 MB) into its own folder for the steps on your iPhone. Nothing else on your Mac changes.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Set Up") { setup.setUp() }.buttonStyle(.glassProminent)
            }
        }
    }

    @ViewBuilder var appID: some View {
        Text("One wildcard App ID lets one profile sign every app under a prefix. Register it once on the Apple Developer website:")
        numbered(1, "Click Open Identifiers and sign in with your Apple account.")
        numbered(2, "Choose App IDs, then App, and click Continue.")
        numbered(3, "Description: \(Brand.name). Bundle ID: Wildcard, with the prefix below and .* at the end.")
        numbered(4, "Click Continue, then Register.")
        HStack(spacing: 8) {
            TextField("Prefix", text: $setup.prefixDraft, prompt: Text(verbatim: "com.example"))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Text(verbatim: ".*").foregroundStyle(.secondary)
            Button("Copy", systemImage: "doc.on.doc") { setup.copy(setup.prefixDraft + ".*") }
                .buttonStyle(.glass).disabled(!setup.prefixDraftValid)
        }
        if !setup.prefixDraft.isEmpty && !setup.prefixDraftValid {
            Text("Like com.yourname: letters, digits and hyphens, with a dot in between.")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text("Your agents give their apps bundle ids under it, like \(setup.prefixDraft).notes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Open Identifiers") { setup.openIdentifiers() }.buttonStyle(.glass)
            Button("Registered") { setup.confirmPrefix() }.buttonStyle(.glassProminent).disabled(!setup.prefixDraftValid)
        }
    }

    @ViewBuilder var iphone: some View {
        if let device = setup.device {
            if device.locked == true {
                Text("Unlock your iPhone.")
            } else {
                Text("Tap Trust on your iPhone and enter its passcode.")
                if setup.working == nil {
                    Button("Ask Again") { Task { await setup.trust() } }.buttonStyle(.glass)
                }
            }
        } else {
            Text("Connect your iPhone to this Mac with a cable and unlock it. You need the cable only this once.")
        }
    }

    @ViewBuilder var developerMode: some View {
        Text("Your iPhone runs apps you build yourself only with Developer Mode on:")
        numbered(1, "On your iPhone open Settings > Privacy & Security > Developer Mode, at the very bottom.")
        numbered(2, "Switch it on and tap Restart.")
        numbered(3, "After the restart unlock your iPhone, tap Turn On and enter your passcode.")
        Text("\(Brand.name) notices when it's on. If the switch isn't there, keep the cable in and click Show the Switch.")
            .font(.callout).foregroundStyle(.secondary)
        if setup.working == nil, setup.device != nil {
            Button("Show the Switch") { Task { await setup.revealDeveloperMode() } }.buttonStyle(.glass)
        }
    }

    @ViewBuilder var signing: some View {
        Text("Xcode makes the signing: it registers your iPhone with your team, creates your development certificate and a profile for your apps. For that it builds a small app, \(SetupAppProject.name), once.")
        numbered(1, "Click Open in Xcode.")
        numbered(2, "At the top of the Xcode window choose your iPhone as the destination, not a simulator.")
        numbered(3, "Press ⌘R. If Xcode asks for a team, choose yours under Signing & Capabilities.")
        numbered(4, "The first time Xcode prepares your iPhone for development, which takes a few minutes. Then \(SetupAppProject.name) opens on your iPhone.")
        if case .exactOnly = setup.signing, setup.team?.isFree == false {
            Text("Xcode made a profile for this one app only: is the wildcard App ID \(setup.prefix).* registered? Then build again.")
                .font(.callout).foregroundStyle(.orange)
        }
        if setup.projectOpened {
            Button("Open in Xcode Again") { setup.openSetupApp() }.buttonStyle(.glass)
        } else {
            Button("Open in Xcode") { setup.openSetupApp() }.buttonStyle(.glassProminent)
        }
    }

    @ViewBuilder var wireless: some View {
        Text("Unplug the cable. \(Brand.name) connects to your iPhone whenever it's on any Wi-Fi with Tailscale on, and the connection then also holds on cellular.")
        Label("Waiting for your iPhone: Wi-Fi and Tailscale on", systemImage: "hourglass").foregroundStyle(.secondary)
        Text("Tailscale must run on your iPhone with the same account as on this Mac.")
            .font(.callout).foregroundStyle(.secondary)
    }

    func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(BrandColor.indigo))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum SetupPartState { case done, open, later }

/// One part: a ticked line when it's done, the open one with its content, later ones dimmed.
struct PartCard<Content: View>: View {
    let number: Int
    let title: String
    let summary: String?
    let state: SetupPartState
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Group {
                        if state == .done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(state == .open ? BrandColor.indigo : Color.secondary.opacity(0.5)))
                        }
                    }
                    .font(.title3).frame(width: 24)
                    Text(title).fontWeight(.semibold).foregroundStyle(state == .later ? .secondary : .primary)
                    Spacer()
                    if let summary { Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                if state == .open {
                    VStack(alignment: .leading, spacing: 8) { content() }
                        .padding(.leading, 34)
                }
            }
        }
    }
}
