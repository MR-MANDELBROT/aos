import AOSKit
import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            StepList()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            StepPage()
                .navigationTitle("")
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            model.openWindow = { openWindow(id: $0) }
            if setup.step == .requirements { setup.checkRequirements() }
            if setup.step == .agents { setup.detectAgents() }
            if setup.step == .session { setup.checkClaudeSignIn() }
            if setup.step == .screenSharing { setup.beginScreenSharing() }
        }
    }
}

extension SetupController.Step {
    var symbol: String {
        switch self {
        case .requirements: return "checkmark.shield"
        case .options: return "slider.horizontal.3"
        case .agents: return "apple.terminal"
        case .download: return "arrow.down.circle"
        case .install: return "laptopcomputer.and.arrow.down"
        case .prepare: return "gearshape.2"
        case .screenSharing: return "rectangle.on.rectangle"
        case .connect: return "link"
        case .pair: return "qrcode"
        case .session: return "iphone.radiowaves.left.and.right"
        case .bitwarden: return "key.horizontal"
        case .done: return "checkmark.seal"
        }
    }
}

// MARK: Sidebar

private struct StepList: View {
    @EnvironmentObject var setup: SetupController

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    AppIconImage(size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Brand.name).font(.headline)
                        Text("Setup").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                ForEach(SetupController.Step.allCases) { step in
                    Label {
                        Text(step.title)
                            .fontWeight(step == setup.step ? .semibold : .regular)
                            .foregroundStyle(step.rawValue > setup.step.rawValue ? .secondary : .primary)
                    } icon: {
                        Image(systemName: step.rawValue < setup.step.rawValue ? "checkmark.circle.fill" : step.symbol)
                            .foregroundStyle(step.rawValue < setup.step.rawValue ? Color.green
                                             : (step == setup.step ? BrandColor.indigo : Color.secondary))
                    }
                    .listRowBackground(step == setup.step
                                       ? RoundedRectangle(cornerRadius: 8).fill(BrandColor.indigo.opacity(0.14)) : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Design review only (AOS_PREVIEW): jump to any step.
                        if ProcessInfo.processInfo.environment["AOS_PREVIEW"] != nil { setup.previewStep(step) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: Pages

private struct StepPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupController
    @EnvironmentObject var power: PowerController
    @Environment(\.openWindow) private var openWindow
    @State private var terminalCommand: TerminalCommand?
    @State private var showBitwarden = false
    /// Read the session folder's readiness again (after the terminal sheet closed).
    @State private var readinessTick = 0

    struct TerminalCommand: Identifiable {
        let id = UUID()
        let title: String
        let command: String
        var directory: URL?
    }

    var busy: Bool {
        switch setup.activity { case .working, .progress: return true; default: return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        HeroSymbol(systemName: setup.step.symbol, tint: setup.step == .done ? .green : BrandColor.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stepCounter).font(.subheadline).foregroundStyle(.secondary)
                            Text(setup.step.title).font(.largeTitle.bold())
                        }
                    }
                    .padding(.bottom, 4)
                    content
                    ActivityView()
                }
                .padding(32)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.5)
            actionBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .sheet(item: $terminalCommand, onDismiss: { readinessTick += 1 }) { cmd in terminalSheet(cmd) }
        .sheet(isPresented: $showBitwarden) {
            VStack(spacing: 0) {
                BitwardenSettings().environmentObject(model)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showBitwarden = false }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 580, height: 640)
        }
    }

    var stepCounter: String {
        let total = SetupController.Step.allCases.count - 1
        return setup.step == .done ? String(localized: "All set") : String(localized: "Step \(setup.step.rawValue + 1) of \(total)")
    }

    // MARK: Content per step

    @ViewBuilder var content: some View {
        switch setup.step {
        case .requirements: requirements
        case .agents: agents
        case .options: options
        case .download: download
        case .install: install
        case .prepare: prepare
        case .screenSharing: screenSharing
        case .connect: connect
        case .pair: pair
        case .session: session
        case .bitwarden: bitwardenStep
        case .done: done
        }
    }

    var requirements: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Brand.name) gives your coding agent its own Mac: a virtual Mac with its own screen and browser, separate from yours. Your agent uses it for tasks that need a website or an app; you approve every time it opens.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    feature("lock.shield", "Separate from your Mac", "None of your files, passwords or sign-ins are inside.")
                    feature("hand.raised", "You decide", "The workspace only opens when you say yes.")
                    feature("clock.arrow.circlepath", "Fresh every time", "Websites forget their sign-ins when it closes.")
                }
            }
            if !setup.requirementProblems.isEmpty {
                ForEach(setup.requirementProblems, id: \.self) { p in
                    Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
        }
    }

    func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(BrandColor.indigo).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which agent should use the workspace? \(Brand.name) adds itself to the agent's settings as an MCP server. You can connect more than one.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(AgentIntegration.all.enumerated()), id: \.element.id) { index, agent in
                        let installed = agent.id == "other" || setup.installedAgents.contains(agent.id)
                        if index > 0 { Divider().padding(.leading, 44) }
                        Button { if installed { setup.toggle(agent.id) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: setup.selectedAgents.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(setup.selectedAgents.contains(agent.id) ? BrandColor.indigo : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Text(agent.id == "other" ? String(localized: "Another agent") : agent.name).fontWeight(.medium)
                                        if agent.id == "claude-code" { RecommendedBadge() }
                                    }
                                    if agent.supportsRemoteSession {
                                        Text("Also reachable from your phone").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(agent.id == "other" ? String(localized: "configure by hand")
                                     : (installed ? String(localized: "found") : String(localized: "not found")))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(installed ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)))
                                    .foregroundStyle(installed ? .green : .secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!installed)
                        .opacity(installed ? 1 : 0.55)
                    }
                }
            }
        }
    }

    var download: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The workspace runs macOS. \(Brand.name) downloads it directly from Apple.")
                .font(.title3).foregroundStyle(.secondary)
            if let info = setup.restoreInfo {
                GlassCard {
                    HStack(spacing: 14) {
                        Image(systemName: "applelogo").font(.largeTitle).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("macOS \(info.osVersion)").font(.headline)
                            Text("Build \(info.buildVersion), about 26 GB. If you quit \(Brand.name) or lose the connection, the download continues where it stopped.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    var install: some View {
        Text("\(Brand.name) creates the virtual Mac and installs macOS into it. This takes about 10 minutes; you can keep working meanwhile.")
            .font(.title3).foregroundStyle(.secondary)
    }

    var prepare: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The workspace starts for the first time, without the setup assistant. \(Brand.name) creates its account, allows remote access only from this Mac, installs Google Chrome and turns off sleep and automatic updates.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                Label("macOS asks whether \(Brand.name) may connect to devices on your local network. Allow it: the workspace counts as such a device.",
                      systemImage: "network")
                    .font(.callout)
            }
        }
    }

    @ViewBuilder var screenSharing: some View {
        switch setup.sharingPhase {
        case .verified, .allowingHelper:
            VStack(alignment: .leading, spacing: 14) {
                GlassCard {
                    Label("Screen sharing is on.", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                }
                Text("One more switch: aOS Helper. With it your agent can sign in on websites once you approve, without ever seeing the password.")
                    .font(.title3).foregroundStyle(.secondary)
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        numbered(1, "Click Allow aOS Helper. The workspace window comes to the front.")
                        numbered(2, "There, follow the bar at the top: switch on aOS Helper. When macOS asks for the password, click Enter Password.")
                        numbered(3, "Then this window comes back by itself.")
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text("One step needs you: macOS only lets a person switch on screen sharing. It stays inside the workspace; your own Mac is not shared.")
                    .font(.title3).foregroundStyle(.secondary)
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        numbered(1, "The workspace window opens by itself. Wait until System Settings appears there at Sharing, the bar at the top tells you.")
                        numbered(2, "Switch on Screen Sharing. When macOS asks for the password, click Enter Password in the bar at the top.")
                        numbered(3, "aOS notices when it worked and brings you back here.")
                    }
                }
            }
        }
    }

    func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(BrandColor.indigo))
            Text(text)
        }
    }

    var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Brand.name) adds its tools to your agents. Opening the workspace always needs your approval: in the agent if it asks for tool permissions, otherwise here on your Mac.")
                .font(.title3).foregroundStyle(.secondary)
            ForEach(AgentIntegration.all.filter { setup.selectedAgents.contains($0.id) }) { agent in
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(agent.id == "other" ? String(localized: "Another agent") : agent.name).fontWeight(.semibold)
                            if agent.id == "claude-code" { RecommendedBadge() }
                            Spacer()
                            switch setup.connectResults[agent.id] {
                            case .connected?: Label("connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed(let why)?: Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                            case .manual?: Label("add by hand", systemImage: "doc.on.clipboard").foregroundStyle(.secondary)
                            case nil: ProgressView().controlSize(.small)
                            }
                        }
                        if needsSnippet(agent.id) {
                            let snippet = AgentIntegration.snippet(binary: setup.mcpBinary)
                            Text(snippet).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
                            Button("Copy", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snippet, forType: .string)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                }
            }
        }
    }

    func needsSnippet(_ id: String) -> Bool {
        switch setup.connectResults[id] {
        case .manual?, .failed?: return true
        default: return false
        }
    }

    var session: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Optional: \(Brand.name) can keep a Claude Code session running on this Mac that you reach from the Claude app on your phone (Remote Control). You approve opening the workspace right there.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { model.settings.keepReachable },
                                     set: { v in model.update { $0.keepReachable = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) { Text("Keep conversations reachable").fontWeight(.semibold); RecommendedBadge() }
                        Text("When the Claude app or a terminal closes a conversation, \(Brand.name) keeps it running, so it stays in the Claude app on your phone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if model.settings.keepReachable {
                    Picker("Conversations active within", selection: Binding(get: { model.settings.keepHours },
                                                                             set: { v in model.update { $0.keepHours = v } })) {
                        Text("the last 6 hours").tag(6)
                        Text("the last day").tag(24)
                        Text("the last 2 days").tag(48)
                        Text("the last week").tag(168)
                        Text("the last 2 weeks").tag(336)
                        if ![6, 24, 48, 168, 336].contains(model.settings.keepHours) {
                            Text("the last \(model.settings.keepHours) hours").tag(model.settings.keepHours)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                }
            }
            lidClosedCard
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(setup.claudeSignedIn ? String(localized: "Signed in to Claude Code") : String(localized: "Sign in to Claude Code"),
                              systemImage: setup.claudeSignedIn ? "checkmark.circle.fill" : "person.crop.circle")
                            .foregroundStyle(setup.claudeSignedIn ? .green : .primary)
                        Spacer()
                        if !setup.claudeSignedIn {
                            Button("Sign in") {
                                terminalCommand = TerminalCommand(title: String(localized: "Sign in to Claude"), command: "claude auth login")
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    Text("Runs Claude Code's own sign-in; \(Brand.name) never sees it.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    let ready = ClaudeCode.readiness(folder: model.paths.session)
                    let _ = readinessTick
                    checkRow(ready.trusted, done: "Claude Code trusts the session folder", todo: "Claude Code doesn't trust the session folder yet")
                    checkRow(ready.remoteControl, done: "Remote Control is on", todo: "Remote Control isn't confirmed yet")
                    if !(ready.trusted && ready.remoteControl) {
                        HStack {
                            Text("Start the session once here: Claude Code asks whether you trust the folder and whether to enable Remote Control. Answer yes to both, then click Done.")
                                .font(.callout)
                            Spacer()
                            Button("Start once") {
                                terminalCommand = TerminalCommand(
                                    title: String(localized: "First start of the session"),
                                    command: "claude --remote-control \(shellQuote(model.settings.sessionName))",
                                    directory: model.paths.session)
                            }
                            .buttonStyle(.glass)
                            .disabled(!setup.claudeSignedIn)
                        }
                    }
                }
            }
        }
    }

    /// The one question about the closed lid (and, when the Mac stays awake, how it joins the iPhone's hotspot).
    var lidClosedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { model.settings.stayAwake == .lidClosed },
                                     set: { v in model.update { $0.stayAwake = v ? .lidClosed : .lidOpen } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) { Text("Stay awake with the lid closed").fontWeight(.semibold); RecommendedBadge() }
                        Text("Conversations and agents keep working with the lid closed, also on battery. Meanwhile \(Brand.name) freezes your other apps; they continue when you open the lid.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(power.cloupiPresent)
                if power.cloupiPresent {
                    OtherWakeServiceNote()
                } else if model.settings.stayAwake == .lidClosed {
                    if power.helperStatus == .requiresApproval {
                        HStack(spacing: 10) {
                            Label("macOS asks you once to allow \(Brand.name)'s background helper.", systemImage: "lock.shield")
                                .font(.callout)
                            Spacer()
                            Button("Open Login Items") { power.openLoginItems() }.buttonStyle(.glass)
                        }
                    }
                    Divider()
                    HotspotChoice(compact: true)
                }
            }
        }
        .onAppear { power.refreshHelperStatus() }
    }

    // MARK: The workspace's settings

    var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How your agent's workspace behaves. You can change it later in the settings.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(selection: Binding(get: { model.settings.signOutWebsites },
                                              set: { v in model.update { $0.signOutWebsites = v } })) {
                        Text("All websites").tag(AgentSettings.SignOutWebsites.all)
                        Text("All except …").tag(AgentSettings.SignOutWebsites.allExcept)
                        Text("None, stay signed in").tag(AgentSettings.SignOutWebsites.none)
                    } label: {
                        Text("Sign out of websites when it closes").fontWeight(.semibold)
                    }
                    .pickerStyle(.menu)
                    if model.settings.signOutWebsites == .allExcept {
                        StaySignedInList()
                    }
                    Text("Recommended: all except google.com. Your agent's sign-ins then end with each use, and Google shows fewer captchas.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GlassCard {
                Toggle(isOn: Binding(get: { model.settings.shareApplications },
                                     set: { v in model.update { $0.shareApplications = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) { Text("Programs of this Mac in the workspace").fontWeight(.semibold); RecommendedBadge() }
                        Text("Your agent can open them there. They start fresh, without your data and sign-ins; App Store apps and apps with licenses often don't run.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: iPhone and Bitwarden

    var pair: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("With \(Brand.name) on your iPhone you approve your agent's sign-ins with Face ID, get a notice when it needs you, and look at the workspace on the go. Without it, you approve everything here on the Mac.")
                .font(.title3).foregroundStyle(.secondary)
            if let device = model.pairedDevices.first {
                GlassCard {
                    Label("\(device.name) is paired.", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                }
            } else if !model.remoteLoginOn {
                GlassCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("First: Remote Login").fontWeight(.semibold)
                            Text("The iPhone connects to this Mac over SSH: encrypted, and only with its own key. Switch on Remote Login in System Settings, then come back here.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Turn On …") { model.openRemoteLoginSettings() }.buttonStyle(.glass)
                    }
                }
            } else {
                GlassCard { PairingView(inline: true).environmentObject(model) }
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in model.refreshPhone() }
    }

    var bitwardenSignedIn: Bool {
        let _ = model.bitwardenTick
        switch model.bitwarden.phase {
        case .locked, .unlocking, .unlocked: return true
        default: return false
        }
    }

    var bitwardenStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When a website needs a sign-in, your agent asks. You pick one of your Bitwarden logins and approve it; \(Brand.name) gets just that login from Bitwarden and types it into the workspace. Your agent never sees it.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Label(bitwardenSignedIn ? String(localized: "Signed in to Bitwarden") : String(localized: "Not signed in yet"),
                              systemImage: bitwardenSignedIn ? "checkmark.circle.fill" : "key.horizontal")
                            .font(.headline)
                            .foregroundStyle(bitwardenSignedIn ? .green : .primary)
                        Spacer()
                        if bitwardenSignedIn {
                            Button("Show …") { showBitwarden = true }.buttonStyle(.glass)
                        } else {
                            Button("Sign In …") { showBitwarden = true }.buttonStyle(.glassProminent)
                        }
                    }
                    if model.bitwarden.phase == .needsHelper {
                        Divider()
                        HStack(spacing: 12) {
                            Text("Bitwarden runs in aOS's background helper. macOS asks you once to allow it in Login Items.")
                                .font(.callout)
                            Spacer()
                            Button("Allow …") { model.allowHelperForBitwarden() }.buttonStyle(.glass)
                        }
                    }
                }
            }
            BitwardenSafetyNote()
        }
    }

    func checkRow(_ ok: Bool, done: LocalizedStringKey, todo: LocalizedStringKey) -> some View {
        Label {
            Text(ok ? done : todo)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
        .font(.callout)
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask your agent for something that needs a website, for example \"look up the opening hours of the city library\". It asks to open its workspace; you approve, and you can watch in the workspace window.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    feature("menubar.rectangle", "In the menu bar", "\(Brand.name) starts with your Mac and shows what the workspace is doing.")
                    if model.settings.sessionEnabled && setup.wantsClaudeSession {
                        feature("iphone", "On your phone", "Open the Claude app: the session \"\(model.settings.sessionName)\" appears with a computer icon.")
                    }
                    feature("folder", "Exchange folder", "Files go in and out of the workspace only through it.")
                    if model.helperState == .allowed {
                        feature("person.badge.key", "Sign-ins", "When a website needs a sign-in, your agent asks; you approve and \(Brand.name) fills it in.")
                    }
                    if model.settings.keepReachable {
                        feature("iphone.radiowaves.left.and.right", "Reachable", "Your Claude Code conversations stay in the Claude app on your phone.")
                    }
                    if bitwardenSignedIn {
                        feature("key.horizontal", "Bitwarden", "Your agent's sign-ins come from your Bitwarden account; you approve each one.")
                    }
                    if let device = model.pairedDevices.first {
                        feature("iphone", "\(Brand.name) on your iPhone", "\(device.name) is paired: approve sign-ins with Face ID, also on the go.")
                    }
                }
            }
            if !bitwardenSignedIn { bitwardenReminder }
            if model.pairedDevices.isEmpty { phoneReminder }
        }
    }

    /// Only when the Bitwarden step was skipped.
    var bitwardenReminder: some View {
            GlassCard {
                HStack(spacing: 14) {
                    Image(systemName: "key.horizontal").font(.title).foregroundStyle(BrandColor.indigo).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bitwarden").fontWeight(.semibold)
                        Text("Sign-ins for your agent from your Bitwarden account: you approve one login, \(Brand.name) gets exactly that one from Bitwarden.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        UserDefaults.standard.set("bitwarden", forKey: "settingsTab")
                        model.openSettingsWindow()
                    }
                    .buttonStyle(.glass)
                }
            }
    }

    /// Only when the pairing step was skipped.
    var phoneReminder: some View {
            GlassCard {
                HStack(spacing: 14) {
                    Image(systemName: "iphone").font(.title).foregroundStyle(BrandColor.indigo).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Brand.name) on your iPhone").fontWeight(.semibold)
                        Text("Approve sign-ins with Face ID, the terminal and the screen of your Mac, on the go.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair") {
                        UserDefaults.standard.set("iphone", forKey: "settingsTab")
                        model.openSettingsWindow()
                    }
                    .buttonStyle(.glass)
                }
            }
    }

    // MARK: Action bar

    @ViewBuilder var actionBar: some View {
        HStack(spacing: 10) {
            secondaryActions
            Spacer()
            primaryAction
        }
        .controlSize(.large)
    }

    @ViewBuilder var secondaryActions: some View {
        switch setup.step {
        case .requirements:
            if !setup.requirementProblems.isEmpty { Button("Check again") { setup.checkRequirements() }.buttonStyle(.glass) }
        case .agents:
            Button("Search again") { setup.detectAgents() }.buttonStyle(.glass)
        case .options:
            Button("Use Recommended") { setup.useRecommendedOptions() }.buttonStyle(.glass)
        case .download:
            if setup.restoreInfo == nil { Button("Look up the newest macOS") { setup.lookUpRestoreImage() }.buttonStyle(.glass).disabled(busy) }
        case .screenSharing:
            switch setup.sharingPhase {
            case .verified:
                Button("Later") { setup.skipHelper() }.buttonStyle(.glass).disabled(busy)
            default:
                EmptyView()
            }
        case .connect:
            Button("Connect again") { setup.connectAgents() }.buttonStyle(.glass).disabled(busy)
        case .session:
            Button("Skip") { setup.skipSession() }.buttonStyle(.glass)
        case .pair:
            if model.pairedDevices.isEmpty {
                Button("Skip (not recommended)") { setup.continueAfterPair() }.buttonStyle(.glass)
            }
        case .bitwarden:
            if !bitwardenSignedIn {
                Button("Skip") { setup.continueAfterBitwarden() }.buttonStyle(.glass)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder var primaryAction: some View {
        switch setup.step {
        case .requirements:
            EmptyView()
        case .options:
            Button("Continue") { setup.continueAfterOptions() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
        case .agents:
            Button("Continue") { setup.continueAfterAgents() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(setup.selectedAgents.isEmpty)
        case .download:
            if case .progress = setup.activity {
                Button("Pause") { setup.pauseDownload() }.buttonStyle(.glass)
            } else if setup.restoreInfo != nil {
                Button("Download") { setup.startDownload() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        case .install:
            if !busy { Button("Create the workspace") { setup.startInstall() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        case .prepare:
            if !busy { Button("Prepare the workspace") { setup.startPrepare() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction) }
        case .screenSharing:
            switch setup.sharingPhase {
            case .verified:
                Button("Allow aOS Helper") { setup.allowHelperAndContinue() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy)
            default:
                Button("Go to the workspace") {
                    openWindow(id: WindowID.workspace)
                    NSApp.activate()
                    setup.beginScreenSharing()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        case .connect:
            Button("Continue") { setup.continueAfterConnect() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy)
        case .session:
            Button("Run in the background") { setup.enableSession() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy || !setup.claudeSignedIn)
        case .pair:
            Button("Continue") { setup.continueAfterPair() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(model.pairedDevices.isEmpty)
        case .bitwarden:
            Button("Continue") { setup.continueAfterBitwarden() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!bitwardenSignedIn)
        case .done:
            Button("Done") { NSApp.keyWindow?.close() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Terminal sheet

    func terminalSheet(_ cmd: TerminalCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(cmd.title, systemImage: "apple.terminal").font(.headline)
            CommandTerminal(command: cmd.command, directory: cmd.directory) { _ in setup.checkClaudeSignIn() }
                .frame(minWidth: 820, minHeight: 440)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Label("This is Claude Code's own terminal. \(Brand.name) never sees what you type here.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { terminalCommand = nil; setup.checkClaudeSignIn() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

/// Progress, running work and errors, below the page content.
private struct ActivityView: View {
    @EnvironmentObject var setup: SetupController
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch setup.activity {
            case .idle:
                EmptyView()
            case .working(let label):
                GlassCard {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(label) }
                }
            case .progress(let label, let fraction):
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(label).fontWeight(.medium)
                            Spacer()
                            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: fraction).tint(BrandColor.indigo)
                    }
                }
            case .failed(let message):
                GlassCard {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if !setup.details.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(setup.details.suffix(80).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                }
                .font(.caption)
            }
        }
    }
}
