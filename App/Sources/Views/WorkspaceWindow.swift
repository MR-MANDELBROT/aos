import AOSKit
import AppKit
import SwiftUI

/// The workspace screen. Shows the agent's help requests on top, and the setup's screen sharing step.
struct WorkspaceWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var coordinator: VMDisplay.Coordinator?

    var body: some View {
        ZStack(alignment: .top) {
            if let machine = model.workspace.host.virtualMachine {
                VMDisplay(machine: machine) { c in DispatchQueue.main.async { coordinator = c } }
                    .aspectRatio(1280.0 / 800.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("The workspace is off", systemImage: "macwindow")
                } description: {
                    Text("It starts when your agent opens it.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let help = model.help {
                banner(symbol: "hand.raised.fill", tint: .orange,
                       title: "Your agent asks for your help", detail: help.purpose) {
                    Button("I can't do this") {
                        model.finishHelp(help.id, "The user could not do it. Ask them in the chat how to continue.")
                    }
                    .buttonStyle(.glass)
                    Button("Done") {
                        model.finishHelp(help.id, "The user is done. Continue with a screenshot.")
                    }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            } else if model.helperState == .allowing {
                banner(symbol: "person.badge.key.fill", tint: BrandColor.indigo,
                       title: "Allow the \(Brand.name) helper below",
                       detail: model.setup.isComplete
                           ? String(localized: "Click Open System Settings if macOS asks, then switch on aOS Helper. When macOS asks for the password to allow aOS Helper, click Enter the workspace password. Only then: if another window asks, click Not Now.")
                           : String(localized: "Click Open System Settings if macOS asks, then switch on aOS Helper. If notices at the top right cover the switch, close them with their x first. \(Brand.name) enters the password itself. This happens only once.")) {
                    Button("Not Now") { Task { await model.cancelHelperPermission() } }
                        .buttonStyle(.glass)
                    Button("Enter the workspace password") { model.setup.typeGuestPassword(into: coordinator) }
                        .buttonStyle(.glassProminent)
                }
            } else if model.setup.step == .screenSharing && !model.setup.isComplete {
                banner(symbol: "rectangle.on.rectangle", tint: BrandColor.indigo,
                       title: "Switch on Screen Sharing below",
                       detail: String(localized: "When macOS asks for a password, let \(Brand.name) enter it.")) {
                    Button("Enter the workspace password") { model.setup.typeGuestPassword(into: coordinator) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        // The user working in the window keeps the workspace open like the agent's requests do.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            guard coordinator?.view?.window?.isKeyWindow == true,
                  let any = CGEventType(rawValue: ~0),
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < 120 else { return }
            model.workspace.noteActivity()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Exchange Folder", systemImage: "folder") { NSWorkspace.shared.open(model.paths.exchange) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Close Workspace", systemImage: "power") { Task { _ = await model.workspace.close() } }
                    .disabled(model.workspace.host.virtualMachine == nil)
            }
        }
        .navigationTitle(Text("Workspace"))
        .navigationSubtitle(statusText)
    }

    var statusText: String {
        if let purpose = model.status?.leasePurpose, model.vmPhase == .running { return String(localized: "Open: \(purpose)") }
        return model.vmPhase.displayName
    }

    func banner(symbol: String, tint: Color, title: LocalizedStringKey, detail: String,
                @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            }
            Spacer(minLength: 12)
            actions()
        }
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.18)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 18)
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
