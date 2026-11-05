import AnnexKit
import SwiftUI

/// The workspace screen. Shows Claude's help requests on top, and the setup's screen sharing step.
struct WorkspaceWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var coordinator: VMDisplay.Coordinator?

    var body: some View {
        VStack(spacing: 0) {
            if let help = model.help {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude asks for your help").font(.headline)
                        Text(help.purpose).textSelection(.enabled)
                    }
                    Spacer()
                    Button("I can't do this") {
                        model.finishHelp(help.id, "The user could not do it. Ask them in the chat how to continue.")
                    }
                    Button("Done") {
                        model.finishHelp(help.id, "The user is done. Continue with a screenshot.")
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                .background(.orange.opacity(0.12))
            } else if model.setup.step == .screenSharing && !model.setup.isComplete {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.blue)
                    Text("Switch on Screen Sharing in the System Settings below. When macOS asks for a password:")
                    Spacer()
                    Button("Enter the workspace password") { model.setup.typeGuestPassword(into: coordinator) }
                }
                .padding(12)
                .background(.blue.opacity(0.10))
            }

            if let machine = model.workspace.host.virtualMachine {
                VMDisplay(machine: machine) { c in DispatchQueue.main.async { coordinator = c } }
                    .aspectRatio(1280.0 / 800.0, contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("The workspace is off. It starts when Claude opens it.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
    }
}

/// The Claude Code session's terminal.
struct SessionWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session \"\(model.settings.sessionName)\"").font(.headline)
                Spacer()
                Text(model.session?.state.rawValue ?? "not running").foregroundStyle(.secondary)
                Button("Restart") { SessionAgent.restart(paths: model.paths) }
            }
            .padding(10)
            SessionTerminal(socketURL: model.paths.run.appendingPathComponent("session.sock"))
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
