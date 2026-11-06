import AOSKit
import AppKit
import SwiftUI

/// The workspace screen. A bar under the title guides the user (setup steps, the agent's help requests, allowing
/// the helper); it sits above the screen and never covers it.
struct WorkspaceWindow: View {
    @EnvironmentObject var model: AppModel
    /// Observed here too, so the bar follows the setup's step and activity.
    @EnvironmentObject var setup: SetupController
    @State private var coordinator: VMDisplay.Coordinator?

    var body: some View {
        VStack(spacing: 0) {
            guide
            screen
        }
        .frame(minWidth: 800, minHeight: 560)
        .onAppear { setup.beginScreenSharing() }
        // The user working in the window keeps the workspace open like the agent's requests do.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard coordinator?.view?.window?.isKeyWindow == true,
                  let any = CGEventType(rawValue: ~0),
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < 120 else { return }
            model.workspace.noteActivity()
        }
        .toolbar {
            if setup.isComplete {
                ToolbarItem(placement: .primaryAction) {
                    Button("Exchange Folder", systemImage: "folder") { NSWorkspace.shared.open(model.paths.exchange) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Close Workspace", systemImage: "power") { Task { _ = await model.workspace.close() } }
                        .disabled(model.workspace.host.virtualMachine == nil)
                }
            }
        }
        .navigationTitle(Text("Workspace"))
        .navigationSubtitle(statusText)
    }

    @ViewBuilder var screen: some View {
        if let machine = model.workspace.host.virtualMachine {
            VMDisplay(machine: machine) { c in DispatchQueue.main.async { coordinator = c; setup.display = c } }
                .aspectRatio(1280.0 / 800.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("The workspace is off", systemImage: "macwindow")
            } description: {
                Text(setup.isComplete ? "It starts when your agent opens it." : "It starts for the next setup step.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The bar

    @ViewBuilder var guide: some View {
        if let help = model.help {
            bar(symbol: "hand.raised.fill", tint: .orange, title: "Your agent asks for your help", detail: help.purpose) {
                Button("I can't do this") {
                    model.finishHelp(help.id, "The user could not do it. Ask them in the chat how to continue.")
                }
                Button("Done") {
                    model.finishHelp(help.id, "The user is done. Continue with a screenshot.")
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } else if model.helperState == .allowing {
            bar(symbol: "person.badge.key.fill", tint: BrandColor.indigo,
                title: "Switch on aOS Helper below",
                detail: setup.isComplete
                    ? String(localized: "If macOS asks, click Open System Settings, then switch on aOS Helper. When macOS asks for the password, click Enter Password. Only then: if another window asks, click Not Now.")
                    : String(localized: "If macOS asks, click Open System Settings, then switch on aOS Helper. aOS enters the password itself, type nothing. Then the setup continues by itself.")) {
                Button("Not Now") { Task { await model.cancelHelperPermission() } }
                Button("Enter Password") { setup.typeGuestPassword(into: coordinator) }
                    .disabled(!model.helperPasswordDialog)
                    .help(model.helperPasswordDialog ? "" : String(localized: "macOS isn't asking for the password right now."))
            }
        } else if setup.sharingPhase == .allowingHelper && !setup.isComplete {
            bar(symbol: "person.badge.key.fill", tint: BrandColor.indigo, title: "One moment",
                detail: String(localized: "aOS prepares the switch for aOS Helper. Type nothing yet."), busy: true) {}
        } else if setup.step == .screenSharing && !setup.isComplete {
            sharingBar
        }
    }

    @ViewBuilder var sharingBar: some View {
        switch setup.sharingPhase {
        case .starting:
            if case .failed(let why) = setup.activity {
                bar(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "The workspace didn't start", detail: why) {
                    Button("Try Again") { setup.beginScreenSharing() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else if !setup.isBusy && model.workspace.host.virtualMachine == nil {
                bar(symbol: "power", tint: BrandColor.indigo, title: "The workspace is off",
                    detail: String(localized: "Start it for this step.")) {
                    Button("Start the Workspace") { setup.beginScreenSharing() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                bar(symbol: "hourglass", tint: BrandColor.indigo, title: "Please wait, don't click anything yet",
                    detail: String(localized: "The workspace starts and then opens System Settings at Sharing. This takes about a minute."),
                    busy: true) {}
            }
        case .waitingForSwitch:
            bar(symbol: "rectangle.on.rectangle", tint: BrandColor.indigo, title: "Switch on Screen Sharing below",
                detail: setup.sharingProblem.map { String(localized: "That didn't work yet: \($0)") }
                    ?? String(localized: "When macOS asks for a password, aOS enters it, type nothing. aOS notices by itself when it worked."),
                warning: setup.sharingProblem != nil) {
                Button("Enter Password") { setup.typeGuestPassword(into: coordinator) }
                    .disabled(!setup.passwordDialogOpen)
                    .help(setup.passwordDialogOpen ? "" : String(localized: "macOS isn't asking for the password right now."))
                Button("Check") { setup.checkScreenSharing() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(setup.isBusy)
            }
        case .checking:
            bar(symbol: "rectangle.on.rectangle", tint: BrandColor.indigo, title: "Checking screen sharing",
                detail: String(localized: "A few seconds. Then the setup continues."), busy: true) {}
        case .verified, .allowingHelper:
            bar(symbol: "checkmark.circle.fill", tint: .green, title: "Screen sharing is on",
                detail: String(localized: "Continue in the setup window.")) {
                Button("Back to Setup") { model.openWindow?(WindowID.setup); NSApp.activate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// A full-width strip under the title bar, in the window's chrome.
    func bar(symbol: String, tint: Color, title: LocalizedStringKey, detail: String, busy: Bool = false,
             warning: Bool = false, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else {
                    Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(warning ? .orange : .secondary)
                        .textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) { actions() }.controlSize(.large)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
        }
        .background(.bar)
    }

    var statusText: String {
        if let purpose = model.status?.leasePurpose, model.vmPhase == .running { return String(localized: "Open: \(purpose)") }
        return model.vmPhase.displayName
    }
}

/// The Claude Code session's terminal.
struct SessionWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SessionTerminal(socketURL: model.paths.run.appendingPathComponent("session.sock"))
            .padding(8)
            .frame(minWidth: 760, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restart", systemImage: "arrow.clockwise") { SessionAgent.restart(paths: model.paths) }
                }
            }
            .navigationTitle(Text("Session \"\(model.settings.sessionName)\""))
            .navigationSubtitle(model.session?.state.displayName ?? String(localized: "Off"))
    }
}

extension VMHost.Phase {
    /// For window subtitles and the menu.
    var displayName: String {
        switch self {
        case .stopped: return String(localized: "Off")
        case .starting: return String(localized: "Starting")
        case .running: return String(localized: "Running")
        case .pausing, .paused: return String(localized: "Paused")
        case .suspending, .stopping: return String(localized: "Shutting down")
        case .installing: return String(localized: "Installing macOS")
        case .error: return String(localized: "Error")
        }
    }
}

extension SessionStatus.State {
    var displayName: String {
        switch self {
        case .starting: return String(localized: "Starting")
        case .running: return String(localized: "Running")
        case .waitingForNetwork: return String(localized: "Waiting for the network")
        case .needsLogin: return String(localized: "Sign in to Claude Code")
        case .needsAttention: return String(localized: "Claude Code asks something")
        case .missingClaude: return String(localized: "Claude Code is not installed")
        case .restarting: return String(localized: "Restarting")
        case .stopped: return String(localized: "Off")
        case .failed: return String(localized: "Error")
        }
    }
}
