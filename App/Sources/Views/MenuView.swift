import AnnexKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Brand.name).font(.headline)
                Spacer()
                if let help = model.help {
                    Button("Help needed") { openWindow(id: WindowID.workspace) }
                        .help(help.purpose)
                        .tint(.orange)
                }
            }

            if !model.setup.isComplete {
                Button("Continue setup …") { openWindow(id: WindowID.setup); NSApp.activate() }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if model.settings.sessionEnabled && model.sessionAgentStatus == .enabled {
                        statusRow("Session", sessionText, sessionColor)
                    }
                    statusRow("Workspace", workspaceText, workspaceColor)
                    if let s = model.status, s.exchangeFiles > 0 {
                        statusRow("Exchange", "\(s.exchangeFiles) item(s)", .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Workspace") { openWindow(id: WindowID.workspace); NSApp.activate() }
                if model.sessionAgentStatus == .enabled {
                    Button("Session") { openWindow(id: WindowID.session); NSApp.activate() }
                }
                Button("Exchange") { NSWorkspace.shared.open(model.paths.exchange) }
            }
            if model.status?.leaseUntil != nil || model.vmPhase == .running {
                Button("Close the workspace now") {
                    Task { _ = await model.workspace.close() }
                }
            }
            Divider()
            HStack {
                Button("Settings …") { openSettings(); NSApp.activate() }
                Button("Updates …") { model.updater.checkForUpdates(nil) }
                    .disabled(!model.updater.updater.canCheckForUpdates)
                Spacer()
                Button("Quit \(Brand.name)") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.openWindow = { openWindow(id: $0) } }
    }

    func statusRow(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).frame(width: 80, alignment: .leading)
            Text(value).foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.callout)
    }

    var sessionText: String {
        guard let s = model.session else { return String(localized: "not started") }
        switch s.state {
        case .running: return String(localized: "\"\(model.settings.sessionName)\" reachable in the Claude app")
        case .starting: return String(localized: "starting")
        case .restarting: return String(localized: "restarting \(s.detail)")
        case .waitingForNetwork: return String(localized: "waiting for the network")
        case .needsLogin: return String(localized: "sign in to Claude Code (open Session)")
        case .needsAttention: return String(localized: "Claude Code asks something (open Session)")
        case .missingClaude: return String(localized: "Claude Code is not installed")
        case .stopped: return String(localized: "off")
        case .failed: return s.detail
        }
    }

    var sessionColor: Color {
        switch model.session?.state {
        case .running: return .green
        case .starting, .restarting, .waitingForNetwork: return .yellow
        case .stopped, .none: return .secondary
        default: return .orange
        }
    }

    var workspaceText: String {
        if let until = model.status?.leaseUntil, let purpose = model.status?.leasePurpose {
            return String(localized: "open: \(purpose) (until \(until.formatted(date: .omitted, time: .shortened)))")
        }
        switch model.vmPhase {
        case .stopped: return model.setup.isComplete ? String(localized: "off, starts when your agent needs it") : String(localized: "not set up")
        case .running: return String(localized: "running")
        case .installing: return String(localized: "installing macOS")
        case .error: return model.status?.lastError ?? String(localized: "error")
        default: return model.vmPhase.rawValue
        }
    }

    var workspaceColor: Color {
        if model.status?.leaseUntil != nil { return .blue }
        switch model.vmPhase {
        case .running: return .green
        case .error: return .red
        case .stopped: return .secondary
        default: return .yellow
        }
    }
}
