import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let connection = model.connection {
                        MacCard(connection: connection)
                        if model.waitingCount > 0 {
                            RequestsCard()
                        }
                        WorkspaceCard(connection: connection)
                        PromiseCard()
                    } else {
                        WelcomeView()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .annexBackground()
            .navigationTitle(model.isPaired ? "Annex" : "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .refreshable {
                model.connection?.retryNow()
                await model.connection?.refreshStatus()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                #if DEBUG
                if model.isDemo, Demo.sheet == "settings" { showSettings = true }
                #endif
            }
        }
    }
}

// MARK: - Mac

struct MacCard: View {
    let connection: MacConnection

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    HeroSymbol(systemName: "laptopcomputer", tint: tint, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.mac.name).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            StatusDot(color: tint)
                            Text(stateLine).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                switch connection.state {
                case .unreachable(let message), .needsAttention(let message):
                    Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        connection.retryNow()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                case .connected:
                    if let problem = connection.macAppProblem {
                        Label {
                            Text(problem.isEmpty
                                 ? String(localized: "Annex on the Mac isn't answering right now. It keeps trying.")
                                 : String(localized: "Annex on the Mac isn't answering right now (\(problem)). It keeps trying."))
                                .font(.footnote).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    } else if case .unavailable(let message) = connection.companionState {
                        Label {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    } else if let hello = connection.hello, !hello.annex.isEmpty {
                        Text("Annex \(hello.annex) on the Mac answers.").font(.footnote).foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch connection.state {
        case .connected:
            connection.macAppProblem == nil
                && (connection.companionState == .ready || connection.companionState == .starting) ? .green : .orange
        case .connecting, .idle: .gray
        case .unreachable: .orange
        case .needsAttention: .red
        }
    }

    private var stateLine: String {
        switch connection.state {
        case .idle: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting …")
        case .connected(let host): String(localized: "Connected via \(Self.describe(host))")
        case .unreachable: String(localized: "Not reachable right now")
        case .needsAttention: String(localized: "Needs your attention")
        }
    }

    /// How the Mac is reached, in words: the local network, Tailscale, or an address.
    static func describe(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.hasSuffix(".ts.net") || lower.hasPrefix("100.") { return String(localized: "Tailscale (\(host))") }
        if lower.hasSuffix(".local") { return String(localized: "your network (\(host))") }
        return host
    }
}

// MARK: - Requests

struct RequestsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(tint: BrandColor.attention) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Waiting for you", systemImage: "hand.raised.fill")
                    .font(.headline).foregroundStyle(BrandColor.attention)
                ForEach(model.questions) { question in
                    Button {
                        model.present(question)
                    } label: {
                        switch question {
                        case .signIn(let request):
                            RequestRow(symbol: request.field == .code ? "number.square" : "person.badge.key", title: request.host,
                                       detail: request.field == .code
                                           ? String(localized: "\(request.agent) asks for a one-time code")
                                           : String(localized: "\(request.agent) asks for a sign-in"))
                        case .approval(let request):
                            RequestRow(symbol: "macwindow.badge.plus",
                                       title: request.purpose.isEmpty ? String(localized: "Open the workspace") : request.purpose,
                                       detail: String(localized: "\(request.agent) wants to open the workspace"))
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.helpRequests) { request in
                    Button {
                        model.showHelp(request)
                    } label: {
                        RequestRow(symbol: "hand.point.up.left", title: request.purpose.isEmpty ? String(localized: "Help in the workspace") : request.purpose,
                                   detail: String(localized: "\(request.agent) asks for your help"))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct RequestRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 32).foregroundStyle(BrandColor.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Workspace

struct WorkspaceCard: View {
    @Environment(AppModel.self) private var model
    let connection: MacConnection

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(BrandColor.indigo).frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workspace").font(.headline)
                        Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let workspace = connection.workspace, workspace.state == .open || workspace.state == .starting {
                    if !workspace.purpose.isEmpty {
                        Text("\u{201E}\(workspace.purpose)\u{201C}").font(.callout).italic()
                    }
                    if let until = workspace.until {
                        Text("Open until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let sessions = connection.workspace?.sessions, !sessions.isEmpty {
                    ForEach(sessions) { session in
                        HStack(spacing: 8) {
                            StatusDot(color: session.state == "running" ? .green : .gray)
                            Text(session.title).font(.subheadline)
                            Spacer()
                            Text(Self.describe(sessionState: session.state)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if connection.workspace?.state == .open {
                    Button {
                        model.screenTarget = .workspace
                        model.tab = .screen
                    } label: {
                        Label("Show the screen", systemImage: "display")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    /// The states the Mac reports for sessions, in words; unknown ones as they come.
    static func describe(sessionState state: String) -> String {
        switch state {
        case "running": String(localized: "Running")
        case "starting": String(localized: "Starting")
        case "stopped": String(localized: "Stopped")
        case "waiting", "asking": String(localized: "Waiting for you")
        case "failed": String(localized: "Failed")
        default: state
        }
    }

    private var symbol: String {
        switch connection.workspace?.state {
        case .open: "macwindow.on.rectangle"
        case .starting: "hourglass"
        case .closing: "arrow.down.right.and.arrow.up.left"
        default: "moon.zzz"
        }
    }

    private var stateText: String {
        guard connection.companionState == .ready, let workspace = connection.workspace else {
            return String(localized: "No news from the Mac")
        }
        switch workspace.state {
        case .stopped: return String(localized: "Closed. It opens when your agent needs it.")
        case .starting: return String(localized: "Starting")
        case .open: return String(localized: "Open")
        case .closing: return String(localized: "Closing")
        case .other(let raw): return raw
        }
    }
}

/// What is where, said plainly.
struct PromiseCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FactRow(symbol: "faceid", text: "Your passwords stay on this iPhone, locked with Face ID.")
            FactRow(symbol: "eye.slash", text: "Your agent never sees a password. Annex fills it into the workspace for you.")
            FactRow(symbol: "lock", text: "The iPhone talks to your Mac over SSH with a key that never leaves this iPhone.")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            AppIconImage(size: 88)
            VStack(spacing: 8) {
                Text("Annex on your iPhone").font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                Text("Stay in touch with your agent's Mac, wherever you are.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    WelcomePoint(symbol: "person.badge.key", title: "Sign-ins for your agent",
                                 text: "Your agent asks, you approve with Face ID. It never sees the password.")
                    WelcomePoint(symbol: "apple.terminal", title: "Terminal",
                                 text: "SSH to your Mac and to other computers.")
                    WelcomePoint(symbol: "display", title: "Screen",
                                 text: "Your Mac and the workspace, live, with touch and keyboard.")
                }
            }
            Button {
                model.isPairingPresented = true
            } label: {
                Label("Pair with your Mac", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Text("On your Mac, click Annex in the menu bar, then \u{201C}Pair\u{201D} next to iPhone. Then scan the code it shows.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

private struct WelcomePoint: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(BrandColor.indigo).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
