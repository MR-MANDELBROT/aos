import AnnexKit
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
                       detail: String(localized: "Click Open System Settings if macOS asks, then switch on Annex Helper. If notices at the top right cover the switch, close them with their x first. \(Brand.name) enters the password itself. This happens only once.")) {
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Label(statusText, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(statusColor)
                    .font(.callout)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Exchange Folder", systemImage: "folder") { NSWorkspace.shared.open(model.paths.exchange) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Close Workspace", systemImage: "power") { Task { _ = await model.workspace.close() } }
                    .disabled(model.workspace.host.virtualMachine == nil)
            }
        }
        .navigationTitle(Text("Workspace"))
    }

    var statusText: String {
        if let purpose = model.status?.leasePurpose { return String(localized: "Open: \(purpose)") }
        return model.vmPhase == .running ? String(localized: "Running") : String(localized: "Off")
    }

    var statusColor: Color {
        if model.status?.leaseUntil != nil { return BrandColor.indigo }
        return model.vmPhase == .running ? .green : .secondary
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
                ToolbarItem(placement: .navigation) {
                    Label(model.session?.state.rawValue ?? String(localized: "not running"), systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(model.session?.state == .running ? .green : .secondary)
                        .font(.callout)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restart", systemImage: "arrow.clockwise") { SessionAgent.restart(paths: model.paths) }
                }
            }
            .navigationTitle(Text("Session \"\(model.settings.sessionName)\""))
    }
}
