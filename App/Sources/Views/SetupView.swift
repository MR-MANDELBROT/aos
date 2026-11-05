import AnnexKit
import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            StepList()
                .frame(width: 210)
                .background(.background.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                StepContent()
                Spacer(minLength: 0)
                ActivityBar()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            model.openWindow = { openWindow(id: $0) }
            if setup.step == .requirements { setup.checkRequirements() }
            if setup.step == .agents { setup.detectAgents() }
            if setup.step == .session { setup.checkClaudeSignIn() }
        }
    }
}

private struct StepList: View {
    @EnvironmentObject var setup: SetupController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Brand.name).font(.title2.bold()).padding(.bottom, 8)
            ForEach(SetupController.Step.allCases) { step in
                HStack(spacing: 8) {
                    Image(systemName: icon(step))
                        .foregroundStyle(step.rawValue < setup.step.rawValue ? .green : (step == setup.step ? .accentColor : .secondary))
                        .frame(width: 16)
                    Text(step.title)
                        .foregroundStyle(step == setup.step ? .primary : .secondary)
                        .fontWeight(step == setup.step ? .semibold : .regular)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    func icon(_ step: SetupController.Step) -> String {
        if step.rawValue < setup.step.rawValue { return "checkmark.circle.fill" }
        if step == setup.step { return "circle.inset.filled" }
        return "circle"
    }
}

private struct ActivityBar: View {
    @EnvironmentObject var setup: SetupController
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.activity {
            case .idle:
                EmptyView()
            case .working(let label):
                HStack { ProgressView().controlSize(.small); Text(label).foregroundStyle(.secondary) }
            case .progress(let label, let fraction):
                ProgressView(value: fraction) { Text(label) } currentValueLabel: {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
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

private struct StepContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupController
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
        VStack(alignment: .leading, spacing: 14) {
            Text(setup.step.title).font(.title.bold())
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
        .sheet(item: $terminalCommand) { cmd in
            VStack(alignment: .leading, spacing: 10) {
                Text(cmd.title).font(.headline)
                CommandTerminal(command: cmd.command, directory: cmd.directory) { _ in
                    setup.checkClaudeSignIn()
                }
                .frame(minWidth: 820, minHeight: 440)
                HStack {
                    Text("This is Claude Code's own terminal. \(Brand.name) never sees what you type here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { terminalCommand = nil; setup.checkClaudeSignIn() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    // MARK: Steps

    var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Brand.name) gives your coding agent its own Mac: a virtual Mac with its own screen and browser, separate from yours. Your agent uses it for tasks that need a website or an app; you approve every time it opens.")
            if setup.requirementProblems.isEmpty {
                Text("Checking this Mac …").foregroundStyle(.secondary)
            } else {
                ForEach(setup.requirementProblems, id: \.self) { p in
                    Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Button("Check again") { setup.checkRequirements() }
            }
        }
    }

    var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which agent should use the workspace? \(Brand.name) adds itself to the agent's settings as an MCP server. You can connect more than one.")
            VStack(spacing: 6) {
                ForEach(AgentIntegration.all) { agent in
                    let installed = agent.id == "other" || setup.installedAgents.contains(agent.id)
                    Toggle(isOn: Binding(get: { setup.selectedAgents.contains(agent.id) },
                                         set: { _ in setup.toggle(agent.id) })) {
                        HStack {
                            Text(agent.name)
                            if agent.supportsRemoteSession {
                                Text("reachable from your phone").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(agent.id == "other" ? String(localized: "configure by hand")
                                 : (installed ? String(localized: "found") : String(localized: "not found")))
                                .font(.caption).foregroundStyle(installed ? .green : .secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!installed)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Search again") { setup.detectAgents() }
                Spacer()
                Button("Continue") { setup.continueAfterAgents() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.selectedAgents.isEmpty)
            }
        }
    }

    var download: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The workspace runs macOS. \(Brand.name) downloads it directly from Apple.")
            if let info = setup.restoreInfo {
                Text("macOS \(info.osVersion) (\(info.buildVersion)), about 26 GB. The download continues where it stopped if you quit \(Brand.name) or lose the connection.")
                    .foregroundStyle(.secondary)
                HStack {
                    if case .progress = setup.activity {
                        Button("Pause") { setup.pauseDownload() }
                    } else {
                        Button("Download") { setup.startDownload() }.keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Button("Look up the newest macOS") { setup.lookUpRestoreImage() }.disabled(busy)
            }
        }
    }

    var install: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Brand.name) creates the virtual Mac and installs macOS into it. This takes about 10 minutes.")
            if !busy { Button("Create the workspace") { setup.startInstall() }.keyboardShortcut(.defaultAction) }
        }
    }

    var prepare: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The workspace starts for the first time without the setup assistant: \(Brand.name) creates its account, locks remote access down to this Mac, installs Google Chrome and turns off sleep and updates.")
            if !busy { Button("Prepare the workspace") { setup.startPrepare() }.keyboardShortcut(.defaultAction) }
        }
    }

    var screenSharing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One step needs you: macOS only lets a person switch on screen sharing. It stays inside the workspace; your own Mac is not shared.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open the workspace window. System Settings is already open there at General > Sharing.")
                Text("2. Switch on Screen Sharing.")
                Text("3. When macOS asks for a password, click \"Enter the workspace password\" in the window.")
                Text("4. Come back here and click Check.")
            }
            .font(.callout)
            HStack {
                Button("Open the workspace window") { openWindow(id: WindowID.workspace) }
                Button("Open Sharing settings again") { setup.openSharingSettingsAgain() }.disabled(busy)
                Spacer()
                Button("Check") { setup.verifyScreenSharing() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    var connect: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Brand.name) adds its tools to your agents. Opening the workspace always needs your approval: in the agent if it asks for tool permissions, otherwise here on your Mac.")
            ForEach(AgentIntegration.all.filter { setup.selectedAgents.contains($0.id) }) { agent in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(agent.name).fontWeight(.medium)
                        Spacer()
                        switch setup.connectResults[agent.id] {
                        case .connected?: Label("connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed(let why)?: Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                        case .manual?: Text("add by hand:").foregroundStyle(.secondary)
                        case nil: Text("waiting").foregroundStyle(.secondary)
                        }
                    }
                    if setup.connectResults[agent.id] == .manual || { if case .failed = setup.connectResults[agent.id] { return true }; return false }() {
                        let snippet = AgentIntegration.snippet(binary: setup.mcpBinary)
                        Text(snippet).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet, forType: .string)
                        }
                    }
                }
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Connect again") { setup.connectAgents() }.disabled(busy)
                Spacer()
                Button("Continue") { setup.continueAfterConnect() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    var session: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional: \(Brand.name) can keep a Claude Code session running on this Mac that you reach from the Claude app on your phone (Remote Control). You approve opening the workspace right there.")
            row(done: setup.claudeSignedIn, title: setup.claudeSignedIn ? String(localized: "Signed in to Claude Code") : String(localized: "Sign in to Claude Code"),
                detail: String(localized: "Runs Claude Code's own sign-in; \(Brand.name) never sees it.")) {
                Button("Sign in") {
                    terminalCommand = TerminalCommand(title: String(localized: "Sign in to Claude"), command: "claude auth login")
                }
            }
            Text("Start the session once here: Claude Code asks whether you trust the folder and whether to enable Remote Control. Answer yes to both, then click Done.")
                .font(.callout)
            HStack {
                Button("Start once") {
                    terminalCommand = TerminalCommand(
                        title: String(localized: "First start of the session"),
                        command: "claude --remote-control \(shellQuote(model.settings.sessionName))",
                        directory: model.paths.session)
                }
                .disabled(!setup.claudeSignedIn)
                Spacer()
                Button("Skip") { setup.skipSession() }
                Button("Run in the background") { setup.enableSession() }
                    .keyboardShortcut(.defaultAction).disabled(busy || !setup.claudeSignedIn)
            }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(Brand.name) is ready.", systemImage: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
            Text("Ask your agent for something that needs a website, for example \"look up the opening hours of the city library\". It asks to open its workspace; you approve, and you can watch in the workspace window.")
            if model.settings.sessionEnabled && setup.wantsClaudeSession {
                Text("On your phone: open the Claude app. The session \"\(model.settings.sessionName)\" appears with a computer icon.")
            }
            Text("\(Brand.name) lives in the menu bar and starts with your Mac.")
                .foregroundStyle(.secondary)
        }
    }

    func row(done: Bool, title: String, detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if !done { action() }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
