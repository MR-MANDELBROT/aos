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
        }
    }
}

extension SetupController.Step {
    var symbol: String {
        switch self {
        case .requirements: return "checkmark.shield"
        case .agents: return "apple.terminal"
        case .download: return "arrow.down.circle"
        case .install: return "laptopcomputer.and.arrow.down"
        case .prepare: return "gearshape.2"
        case .screenSharing: return "rectangle.on.rectangle"
        case .connect: return "link"
        case .session: return "iphone.radiowaves.left.and.right"
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
        .sheet(item: $terminalCommand) { cmd in terminalSheet(cmd) }
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
        case .download: download
        case .install: install
        case .prepare: prepare
        case .screenSharing: screenSharing
        case .connect: connect
        case .session: session
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
                                    Text(agent.id == "other" ? String(localized: "Another agent") : agent.name).fontWeight(.medium)
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

    var screenSharing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One step needs you: macOS only lets a person switch on screen sharing. It stays inside the workspace; your own Mac is not shared.")
                .font(.title3).foregroundStyle(.secondary)
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    numbered(1, "Open the workspace window. System Settings is already open there at General > Sharing.")
                    numbered(2, "Switch on Screen Sharing. If notices at the top right cover the switch, close them with their x.")
                    numbered(3, "When macOS asks for a password, click \"Enter the workspace password\" in the window.")
                    numbered(4, "Come back here and click Check.")
                    numbered(5, "Right after, the workspace asks once more: switch on aOS Helper. \(Brand.name) enters the password itself. With it, your agent can sign in on websites once you approve, without ever seeing the password.")
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
                Toggle(isOn: Binding(get: { model.settings.keepReachable },
                                     set: { v in model.update { $0.keepReachable = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep conversations reachable").fontWeight(.semibold)
                        Text("When the Claude app or a terminal closes a conversation, \(Brand.name) keeps it running, so it stays in the Claude app on your phone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
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

    /// The one question about the closed lid (and, when the Mac stays awake, how it joins the iPhone's hotspot).
    var lidClosedCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { model.settings.stayAwake == .lidClosed },
                                     set: { v in model.update { $0.stayAwake = v ? .lidClosed : .lidOpen } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay awake with the lid closed").fontWeight(.semibold)
                        Text("Conversations and agents keep working with the lid closed, also on battery. Meanwhile \(Brand.name) freezes your other apps; they continue when you open the lid.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(power.cloupiPresent)
                if power.cloupiPresent {
                    CloupiNote()
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
                }
            }
            GlassCard {
                HStack(spacing: 14) {
                    Image(systemName: "key.horizontal").font(.title).foregroundStyle(BrandColor.indigo).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bitwarden").fontWeight(.semibold)
                        Text("Sign-ins for your agent from your Bitwarden account: you approve one login, \(Brand.name) gets exactly that one from Bitwarden.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.bitwarden.isSignedIn ? "Settings" : "Connect") {
                        UserDefaults.standard.set("bitwarden", forKey: "settingsTab")
                        model.openSettingsWindow()
                    }
                    .buttonStyle(.glass)
                }
            }
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
        case .download:
            if setup.restoreInfo == nil { Button("Look up the newest macOS") { setup.lookUpRestoreImage() }.buttonStyle(.glass).disabled(busy) }
        case .screenSharing:
            Button("Open the workspace window") { openWindow(id: WindowID.workspace) }.buttonStyle(.glass)
            Button("Open Sharing settings again") { setup.openSharingSettingsAgain() }.buttonStyle(.glass).disabled(busy)
        case .connect:
            Button("Connect again") { setup.connectAgents() }.buttonStyle(.glass).disabled(busy)
        case .session:
            Button("Skip") { setup.skipSession() }.buttonStyle(.glass)
        default:
            EmptyView()
        }
    }

    @ViewBuilder var primaryAction: some View {
        switch setup.step {
        case .requirements:
            EmptyView()
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
            Button("Check") { setup.verifyScreenSharing() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy)
        case .connect:
            Button("Continue") { setup.continueAfterConnect() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy)
        case .session:
            Button("Run in the background") { setup.enableSession() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(busy || !setup.claudeSignedIn)
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
