import AOSKit
import SwiftUI

/// The menu bar window: what the workspace and the session are doing, and the few actions that matter.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var power: PowerController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let signIn = model.signIns.first {
                attention(symbol: "person.badge.key.fill",
                          title: "\(signIn.agent ?? String(localized: "Your agent")) wants to sign in",
                          detail: String(localized: "on \(signIn.host ?? "a website"). Approve on your iPhone or here.")) {
                    openWindow(id: WindowID.signIn); NSApp.activate()
                }
            } else if let help = model.help {
                attention(symbol: "hand.raised.fill", title: "Your agent asks for your help", detail: help.purpose) {
                    openWindow(id: WindowID.workspace); NSApp.activate()
                }
            } else if let approval = model.approval {
                attention(symbol: "macwindow.badge.plus", title: "\(approval.agent) wants to open its workspace", detail: approval.purpose) {
                    openWindow(id: WindowID.approval); NSApp.activate()
                }
            } else if !model.setup.isComplete {
                attention(symbol: "sparkles", title: "Finish setting up \(Brand.name)", detail: String(localized: "A few steps are left.")) {
                    openWindow(id: WindowID.setup); NSApp.activate()
                }
            } else if model.settings.stayAwake == .lidClosed && power.helperStatus == .requiresApproval && !power.cloupiPresent {
                attention(symbol: "lock.shield", title: "Allow \(Brand.name)'s background helper",
                          detail: String(localized: "So the Mac stays awake with the lid closed: Login Items & Extensions, \"Allow in the Background\".")) {
                    power.openLoginItems()
                }
            }

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    statusCard(symbol: "macwindow", title: "Workspace", value: workspaceText, color: workspaceColor) {
                        if model.status?.leaseUntil != nil || model.vmPhase == .running {
                            Button("Close now") { Task { _ = await model.workspace.close() } }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    if model.settings.keepReachable || ownSession {
                        statusCard(symbol: "iphone.radiowaves.left.and.right", title: "Claude Code", value: claudeText,
                                   color: claudeColor) {
                            Button("Show") {
                                if ownSession && !model.settings.keepReachable {
                                    openWindow(id: WindowID.session)
                                } else {
                                    UserDefaults.standard.set("claude", forKey: "settingsTab")
                                    openSettings()
                                }
                                NSApp.activate()
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    statusCard(symbol: "iphone", title: "iPhone", value: phoneText,
                               color: model.phoneConnected ? .green : (model.pairedDevices.isEmpty ? .secondary : BrandColor.indigo)) {
                        if model.pairedDevices.isEmpty {
                            Button("Pair") {
                                UserDefaults.standard.set("iphone", forKey: "settingsTab")
                                openSettings(); NSApp.activate()
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                quick("macwindow", "Workspace") { openWindow(id: WindowID.workspace); NSApp.activate() }
                quick("folder", "Exchange") { NSWorkspace.shared.open(model.paths.exchange) }
                quick("gearshape", "Settings") { openSettings(); NSApp.activate() }
            }

            Divider().opacity(0.6)
            HStack {
                Button("Check for Updates …") { model.updater.checkForUpdates(nil) }
                    .disabled(!model.updater.updater.canCheckForUpdates)
                Spacer()
                Button("Quit \(Brand.name)") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            model.openWindow = { openWindow(id: $0) }
            model.openSettingsAction = { openSettings() }
            model.refreshPhone()
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            AppIconImage(size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(Brand.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var summary: String {
        if !model.signIns.isEmpty { return String(localized: "A sign-in is waiting for you") }
        if model.status?.leaseUntil != nil { return String(localized: "Your agent is working") }
        if !model.setup.isComplete { return String(localized: "Setup not finished") }
        return String(localized: "Ready")
    }

    func attention(symbol: String, title: LocalizedStringKey, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).multilineTextAlignment(.leading)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func statusCard(symbol: String, title: LocalizedStringKey, value: String, color: Color,
                    @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    StatusDot(color: color)
                }
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func quick(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }

    var ownSession: Bool {
        model.settings.sessionEnabled && model.sessionAgentStatus == .enabled
            && ClaudeCode.isConfigured(session: model.paths.session)
    }

    var claudeText: String {
        var parts: [String] = []
        if ownSession { parts.append(sessionText) }
        if model.settings.keepReachable {
            let n = model.reachableCount
            parts.append(n == 0 ? String(localized: "no conversation to keep right now")
                         : (n == 1 ? String(localized: "1 conversation reachable on your phone")
                            : String(localized: "\(n) conversations reachable on your phone")))
        }
        return parts.joined(separator: " · ")
    }

    var claudeColor: Color {
        if ownSession { return sessionColor }
        if model.keeper?.entries.contains(where: { $0.state == .needsAttention || $0.state == .failed }) == true { return .orange }
        return model.reachableCount > 0 ? .green : .secondary
    }

    var phoneText: String {
        if model.phoneConnected { return String(localized: "\(model.phoneName ?? "iPhone") connected") }
        if model.pairedDevices.isEmpty { return String(localized: "Not paired yet") }
        return model.pairedDevices.count == 1 ? String(localized: "\(model.pairedDevices[0].name) paired, not connected now")
            : String(localized: "\(model.pairedDevices.count) devices paired")
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
        if model.status?.leaseUntil != nil { return BrandColor.indigo }
        switch model.vmPhase {
        case .running: return .green
        case .error: return .red
        case .stopped: return .secondary
        default: return .yellow
        }
    }
}
