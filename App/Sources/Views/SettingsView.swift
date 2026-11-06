import AOSKit
import SwiftUI

/// The settings window: one tab per part of aOS. Changes apply at once.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Claude Code", systemImage: "iphone.radiowaves.left.and.right", value: "claude") { ReachableSettings() }
            Tab("Bitwarden", systemImage: "key.horizontal", value: "bitwarden") { BitwardenSettings() }
            Tab("iPhone", systemImage: "iphone", value: "iphone") { PhoneSettings() }
        }
        .frame(width: 640)
        .environmentObject(model)
    }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var domains = ""

    var body: some View {
        Form {
            Section {
                Toggle("Sign-ins expire when the workspace closes", isOn: binding(\.expireSignIns))
                Text(model.settings.expireSignIns
                     ? "The workspace shuts down after each use; websites forget sign-ins, except the domains below (fewer captchas there)."
                     : "The workspace is suspended after each use and continues exactly where it was, signed in everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Stay signed in on", text: $domains, prompt: Text("[*.]google.com"))
                    .disabled(!model.settings.expireSignIns)
                    .onSubmit(saveDomains)
                Stepper("Close after \(model.settings.idleMinutes) min without activity",
                        value: binding(\.idleMinutes), in: 5...120, step: 5)
            } header: {
                Text("Workspace")
            } footer: {
                Text("Changes to sign-ins apply to the workspace at its next start.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    switch model.helperState {
                    case .allowed:
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .checking, .allowing:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Set Up …") { Task { await model.allowHelper() } }
                            .buttonStyle(.glass)
                            .disabled(!model.setup.isComplete)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign-ins for your agent")
                        Text(helperText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Signing in")
            }
            Section("Mac") {
                Toggle("Start \(Brand.name) at login", isOn: Binding(
                    get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                Toggle("Keep this Mac awake while something must stay reachable", isOn: binding(\.keepAwake))
                Text("The Mac doesn't go to sleep by itself while a session or a kept conversation runs. Closing a laptop's lid still puts it to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Folders") {
                LabeledContent("Exchange") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.exchange) }
                }
                LabeledContent("Data") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.root) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            domains = model.settings.keepSignedIn.joined(separator: ", ")
            Task { await model.checkHelper() }
        }
        .onDisappear(perform: saveDomains)
    }

    var helperText: String {
        switch model.helperState {
        case .allowed:
            return String(localized: "When a website needs a sign-in, your agent asks; you approve on your iPhone or Mac and \(Brand.name) fills it in.")
        case .unavailable(let reason): return reason
        case .allowing: return String(localized: "Switch on aOS Helper in the workspace window.")
        default:
            return String(localized: "Once: allow \(Brand.name)'s helper in the workspace to see the sign-in field and type into it. Your agent never sees passwords.")
        }
    }

    func saveDomains() {
        let list = domains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
            .filter { !$0.isEmpty }
        model.update { $0.keepSignedIn = list }
    }

    func binding<T>(_ path: WritableKeyPath<AgentSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { v in model.update { $0[keyPath: path] = v } })
    }
}

// MARK: Claude Code: the session and reachable conversations

struct ReachableSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var sessionName = ""
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.keepReachable)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep conversations reachable")
                        Text("When the Claude app or a terminal closes a conversation, \(Brand.name) keeps it running in the background, so you can continue it from the Claude app on your phone. Open it on the Mac again and \(Brand.name) hands it back at once.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.settings.keepReachable {
                    Toggle("Automatically: conversations from the Claude app", isOn: binding(\.keepAutomatic))
                    if model.settings.keepAutomatic {
                        Stepper("Active within the last \(model.settings.keepHours) hours",
                                value: binding(\.keepHours), in: 6...(24 * 14), step: 6)
                        Toggle("Also conversations started in a terminal", isOn: binding(\.keepTerminal))
                    }
                    Stepper("At most \(model.settings.keepMax) at once", value: binding(\.keepMax), in: 1...12)
                    Text("Each kept conversation is a Claude Code process with about 250 MB of memory. Pinned ones are kept regardless of age.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Reachable from your phone")
            }

            if model.settings.keepReachable {
                Section("Conversations") {
                    if model.conversations.isEmpty {
                        Text("No conversations in the last days.").foregroundStyle(.secondary)
                    }
                    ForEach(model.conversations) { c in
                        ConversationRow(conversation: c, entry: model.keeper?.entries.first { $0.id == c.id })
                    }
                }
            }

            if ClaudeCode.isConfigured(session: model.paths.session) {
                Section {
                    TextField("Name in the Claude app", text: $sessionName).onSubmit(saveName)
                    Toggle("Keep the session running", isOn: binding(\.sessionEnabled))
                } header: {
                    Text("\(Brand.name)'s own session")
                } footer: {
                    Text("A session that always runs in \(Brand.name)'s folder, with the workspace tools.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            sessionName = model.settings.sessionName
            model.loadConversations()
        }
        .onDisappear(perform: saveName)
        .onReceive(timer) { _ in if model.settings.keepReachable { model.loadConversations() } }
    }

    func saveName() {
        let name = sessionName.trimmingCharacters(in: .whitespaces)
        model.update { $0.sessionName = name.isEmpty ? Brand.defaultSessionName : name }
    }

    func binding<T>(_ path: WritableKeyPath<AgentSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { v in model.update { $0[keyPath: path] = v } })
    }
}

/// One conversation: title, where it is, whether it is reachable, and pin or skip.
struct ConversationRow: View {
    @EnvironmentObject var model: AppModel
    let conversation: ClaudeConversation
    let entry: KeeperStatus.Entry?

    var pinned: Bool { model.settings.keptConversations.contains(conversation.id) }
    var skipped: Bool { model.settings.skippedConversations.contains(conversation.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.startedIn == "claude-desktop" ? "macwindow" : "terminal")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: color)
                    Text(stateText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(URL(fileURLWithPath: conversation.cwd).lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                    Text(conversation.lastActivity, style: .relative).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if skipped {
                Button("Allow") { model.unskip(conversation.id) }.buttonStyle(.glass).controlSize(.small)
            } else {
                Button {
                    model.pin(conversation.id, !pinned)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.glass).controlSize(.small)
                .help(pinned ? "Keep only automatically" : "Always keep reachable")
                Button {
                    model.skip(conversation.id)
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.glass).controlSize(.small)
                .help("Never keep this conversation")
            }
        }
        .padding(.vertical, 2)
    }

    var color: Color {
        switch entry?.state {
        case .running: return .green
        case .openElsewhere: return BrandColor.indigo
        case .starting, .waitingForNetwork: return .yellow
        case .needsAttention, .failed, .folderMissing: return .orange
        case .none: return .secondary
        }
    }

    var stateText: String {
        if let entry {
            switch entry.state {
            case .running: return String(localized: "Reachable")
            case .starting: return String(localized: "Starting")
            case .openElsewhere:
                return entry.detail.contains("Claude app") ? String(localized: "Open in the Claude app")
                    : String(localized: "Open elsewhere")
            case .waitingForNetwork: return String(localized: "Waiting for the network")
            case .needsAttention: return entry.detail
            case .failed: return entry.detail
            case .folderMissing: return String(localized: "Folder no longer exists")
            }
        }
        let s = model.settings
        if skipped { return String(localized: "Never kept") }
        if let d = conversation.desktop {
            if d.archived { return String(localized: "Archived in the Claude app") }
            if d.scheduled { return String(localized: "Scheduled task") }
            if d.remoteControlTurnedOff { return String(localized: "Remote Control turned off") }
        }
        if !s.keepAutomatic { return String(localized: "Not pinned") }
        if conversation.startedIn != "claude-desktop" && !s.keepTerminal { return String(localized: "From a terminal") }
        if !conversation.usedRemoteControl { return String(localized: "Never used Remote Control") }
        if conversation.lastActivity < Date().addingTimeInterval(-Double(s.keepHours) * 3600) {
            return String(localized: "Inactive for longer than \(s.keepHours) hours")
        }
        return String(localized: "Above the limit of \(s.keepMax)")
    }
}
