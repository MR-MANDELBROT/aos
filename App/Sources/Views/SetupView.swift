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
            if setup.step == .claudeCode { setup.checkClaudeCode() }
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
            case .claudeCode: claudeCode
            case .download: download
            case .install: install
            case .prepare: prepare
            case .screenSharing: screenSharing
            case .session: session
            case .done: done
            }
        }
        .sheet(item: $terminalCommand) { cmd in
            VStack(alignment: .leading, spacing: 10) {
                Text(cmd.title).font(.headline)
                CommandTerminal(command: cmd.command, directory: cmd.directory) { _ in
                    setup.checkClaudeCode()
                }
                .frame(minWidth: 820, minHeight: 440)
                HStack {
                    Text("This is Claude Code's own terminal. \(Brand.name) never sees what you type here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { terminalCommand = nil; setup.checkClaudeCode() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    // MARK: Steps

    var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Brand.name) gives Claude its own Mac: a virtual Mac with its own screen and browser, separate from yours. Claude uses it for tasks that need a website or an app, and you reach Claude from the Claude app on your phone at any time.")
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

    var claudeCode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Brand.name) runs Claude Code, Anthropic's own app, with your Claude subscription (Pro, Max or Team). You install it and sign in yourself; \(Brand.name) never sees your sign-in.")
            row(done: setup.claudeInstalled,
                title: setup.claudeInstalled ? String(localized: "Claude Code \(setup.claudeVersion ?? "") is installed") : String(localized: "Install Claude Code"),
                detail: String(localized: "Uses Anthropic's installer: \(SetupController.installCommand)")) {
                Button("Install") {
                    terminalCommand = TerminalCommand(title: String(localized: "Install Claude Code"), command: SetupController.installCommand)
                }
            }
            row(done: setup.claudeSignedIn, title: setup.claudeSignedIn ? String(localized: "Signed in") : String(localized: "Sign in to Claude"),
                detail: String(localized: "Opens Claude's sign-in page in your browser.")) {
                Button("Sign in") {
                    terminalCommand = TerminalCommand(title: String(localized: "Sign in to Claude"), command: "claude auth login")
                }
                .disabled(!setup.claudeInstalled)
            }
            HStack {
                Button("Check again") { setup.checkClaudeCode() }
                Spacer()
                Button("Continue") { setup.continueAfterClaudeCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(setup.claudeInstalled && setup.claudeSignedIn))
            }
        }
    }

    var download: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The workspace runs macOS. \(Brand.name) downloads it directly from Apple.")
            if let info = setup.restoreInfo {
                Text("macOS \(info.osVersion) (\(info.buildVersion)), about 18 GB. The download continues where it stopped if you quit \(Brand.name) or lose the connection.")
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

    var session: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last step: \(Brand.name) registers its tools with Claude Code and starts the session \"\(model.settings.sessionName)\". Start it once here: Claude Code asks whether you trust the folder and whether to enable Remote Control. Answer yes to both, then close the terminal.")
            HStack {
                Button("1. Register tools") { setup.configureSession() }.disabled(busy)
                Button("2. Start once") {
                    terminalCommand = TerminalCommand(
                        title: String(localized: "First start of the session"),
                        command: "claude --remote-control \(shellQuote(model.settings.sessionName))",
                        directory: model.paths.session)
                }
                Spacer()
                Button("3. Run in the background") { setup.enableSession() }
                    .keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(Brand.name) is ready.", systemImage: "checkmark.seal.fill").font(.title3).foregroundStyle(.green)
            Text("Open the Claude app on your phone or at claude.ai/code. The session \"\(model.settings.sessionName)\" appears with a computer icon. Ask Claude for something that needs a website: it asks for permission to open its workspace, and you approve it there.")
            Text("\(Brand.name) lives in the menu bar. It starts with your Mac and keeps the session running.")
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
