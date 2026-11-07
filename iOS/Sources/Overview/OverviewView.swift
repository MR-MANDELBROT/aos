import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
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
                        // What aOS on the Mac does now: not while the Mac sleeps or doesn't answer (it would be old).
                        if connection.macStatus != nil, connection.companionState == .ready, connection.sleepingSince == nil {
                            AOSCard(connection: connection)
                        }
                        PromiseCard()
                    } else {
                        WelcomeView()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .defaultScrollAnchor(Self.startAnchor)
            .aosBackground()
            .navigationTitle(model.isPaired ? "aOS" : "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .refreshable {
                model.connection?.retryNow()
                await model.connection?.refreshStatus()
                await model.connection?.refreshMacStatus()
            }
            // The Mac's status while the Overview is on screen: now and every 15 s.
            .task(id: StatusPoll(ready: model.connection?.companionState == .ready, active: scenePhase == .active)) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await model.connection?.refreshMacStatus()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                #if DEBUG
                if model.isDemo, Demo.sheet == "settings" { showSettings = true }
                #endif
            }
        }
    }

    private struct StatusPoll: Hashable {
        var ready: Bool
        var active: Bool
    }

    private static var startAnchor: UnitPoint {
        #if DEBUG
        if Demo.scrollToBottom { return .bottom }
        #endif
        return .top
    }
}

/// Every row of the Overview: a symbol in a column of the same width, the text after it at the same place.
struct OverviewRow<Accessory: View>: View {
    let symbol: String
    var tint: Color = BrandColor.indigo
    let title: String
    var detail: String?
    var detailTint: Color = .secondary
    @ViewBuilder var accessory: Accessory

    static var iconWidth: CGFloat { 30 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundStyle(detailTint).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .accessibilityElement(children: .combine)
    }
}

extension OverviewRow where Accessory == EmptyView {
    init(symbol: String, tint: Color = BrandColor.indigo, title: String, detail: String? = nil, detailTint: Color = .secondary) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, detailTint: detailTint) { EmptyView() }
    }
}

/// An action that is running, or what went wrong with the last one, under a card.
@MainActor @Observable
final class ActionState {
    private(set) var running: MacAction?
    private(set) var problem: String?
    private var clear: Task<Void, Never>?

    func run(_ action: MacAction, value: String? = nil, on connection: MacConnection,
             then done: ((MacActionResult) -> Void)? = nil) {
        guard running == nil else { return }
        running = action
        problem = nil
        Task {
            do {
                let result = try await connection.perform(action, value: value)
                done?(result)
            } catch let refusal as MacRefusal {
                show(refusal.text)
            } catch {
                show(error.localizedDescription)
            }
            running = nil
        }
    }

    private func show(_ text: String) {
        problem = text
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.problem = nil }
        }
    }
}

private struct ProblemLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label {
                Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Mac

struct MacCard: View {
    @Environment(AppModel.self) private var model
    let connection: MacConnection
    @State private var actions = ActionState()
    @State private var confirmSleep = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    HeroSymbol(systemName: connection.sleepingSince != nil ? "moon.zzz.fill" : "laptopcomputer", tint: tint, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.mac.name).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            StatusDot(color: tint)
                            Text(stateLine).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if connection.sleepingSince != nil {
                    // Put to sleep from here: the Mac doesn't answer until it is woken on the Mac.
                    Text("It wakes when you open the lid or press a key on the Mac. aOS connects again by itself.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
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
                        connectedContent
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .confirmationDialog("Put \(connection.mac.name) to sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Sleep", role: .destructive) {
                actions.run(.sleep, on: connection)
            }
        } message: {
            Text("This iPhone loses the connection until the Mac wakes up again (open the lid or press a key). The workspace and your agents pause meanwhile.")
        }
    }

    @ViewBuilder private var connectedContent: some View {
        if connection.companionState == .needsPairing {
            // Paired before requests were signed (or removed on the Mac): the Mac refuses its answers.
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair again to keep approving from this iPhone.").font(.footnote.weight(.semibold))
                    Text("aOS on the Mac now takes requests only when this iPhone signs them, with a key it gets when you pair. Show the pairing code on the Mac (Settings > iPhone) and scan it.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button {
                model.isPairingPresented = true
            } label: {
                Label("Pair Again", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.glassProminent)
        } else if let problem = connection.macAppProblem {
            Label {
                Text(problem.isEmpty
                     ? String(localized: "aOS on the Mac isn't answering right now. It keeps trying.")
                     : String(localized: "aOS on the Mac isn't answering right now (\(problem)). It keeps trying."))
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
        } else if let status = connection.macStatus {
            Divider()
            MacStatusRows(status: status, connection: connection, actions: actions)
            // Only what makes sense now (Display Off while it's on, On while it's off, Sleep while awake).
            let offer = MacOffer.now(status, features: connection.hello?.features ?? [], sleeping: connection.sleepingSince != nil)
            HStack(spacing: 10) {
                if offer.sleep {
                    Button {
                        confirmSleep = true
                    } label: {
                        Label("Sleep", systemImage: "moon.fill")
                    }
                }
                if offer.displayOff {
                    Button {
                        actions.run(.displayOff, on: connection)
                    } label: {
                        Label("Display Off", systemImage: "display")
                    }
                }
                if offer.displayOn {
                    Button {
                        actions.run(.displayOn, on: connection)
                    } label: {
                        Label("Display On", systemImage: "sun.max")
                    }
                }
                if actions.running != nil { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.glass)
            .disabled(actions.running != nil)
            ProblemLine(text: actions.problem)
        } else if let hello = connection.hello, !hello.aos.isEmpty {
            Text(connection.macStatusUnsupported
                 ? String(localized: "aOS \(hello.aos) on the Mac answers. Update it to see its battery and settings here.")
                 : String(localized: "aOS \(hello.aos) on the Mac answers."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        if connection.sleepingSince != nil { return BrandColor.indigo }
        return switch connection.state {
        case .connected:
            connection.macAppProblem == nil
                && (connection.companionState == .ready || connection.companionState == .starting) ? .green : .orange
        case .connecting, .idle: .gray
        case .unreachable: .orange
        case .needsAttention: .red
        }
    }

    private var stateLine: String {
        if let since = connection.sleepingSince {
            return String(localized: "Sleeping since \(since.formatted(date: .omitted, time: .shortened))")
        }
        return switch connection.state {
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

/// Battery, lid and staying awake, with the choice to change the last.
private struct MacStatusRows: View {
    let status: MacStatus
    let connection: MacConnection
    let actions: ActionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let power = status.power {
                OverviewRow(symbol: MacStatusText.batterySymbol(power), tint: MacStatusText.batteryTint(power),
                            title: MacStatusText.batteryTitle(power), detail: MacStatusText.batteryDetail(power))
                OverviewRow(symbol: power.lid == "closed" ? "laptopcomputer.slash" : "laptopcomputer",
                            title: MacStatusText.lidTitle(power), detail: MacStatusText.thermalDetail(power),
                            detailTint: power.thermal == "serious" || power.thermal == "critical" ? .orange : .secondary)
            }
            if let display = status.display {
                OverviewRow(symbol: "display", tint: display.state == "on" ? BrandColor.indigo : .secondary,
                            title: MacStatusText.displayTitle(display), detail: MacStatusText.displayDetail(display))
            }
            if let awake = status.awake {
                OverviewRow(symbol: awake.setting == .off ? "moon.zzz" : "sun.max", title: String(localized: "Stay awake"),
                            detail: MacStatusText.awakeDetail(awake),
                            detailTint: awake.blocker == "lowBattery" || awake.blocker == "thermal"
                                || awake.blocker == "helperNotReady" ? .orange : .secondary) {
                    if awake.otherService {
                        EmptyView()
                    } else {
                        Menu {
                            Picker("Keep this Mac awake", selection: Binding(get: { awake.setting }, set: { mode in
                                actions.run(.stayAwake, value: mode.rawValue, on: connection)
                            })) {
                                ForEach(MacStayAwake.allCases) { mode in Text(MacStatusText.stayAwakeName(mode)).tag(mode) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(MacStatusText.stayAwakeShortName(awake.setting))
                                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            }
                            .font(.subheadline)
                        }
                        .disabled(actions.running != nil)
                    }
                }
            }
        }
    }
}

/// The Mac's status in words (and symbols), kept apart from the views for the tests.
enum MacStatusText {
    static func batterySymbol(_ p: MacStatus.Power) -> String {
        guard let level = p.battery else { return "powerplug" }
        if p.charging == true { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    static func batteryTint(_ p: MacStatus.Power) -> Color {
        guard let level = p.battery else { return BrandColor.indigo }
        if p.charging == true { return .green }
        return level < 15 && p.source == "battery" ? .red : BrandColor.indigo
    }

    static func batteryTitle(_ p: MacStatus.Power) -> String {
        guard let level = p.battery else { return String(localized: "Power adapter") }
        return String(localized: "Battery \(level) %")
    }

    static func batteryDetail(_ p: MacStatus.Power) -> String {
        let time = p.minutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
        if p.battery == nil { return "" }
        if p.charging == true {
            return time.map { String(localized: "Charging, full in \($0)") } ?? String(localized: "Charging")
        }
        if p.source == "battery" {
            return time.map { String(localized: "On battery, \($0) left") } ?? String(localized: "On battery")
        }
        return String(localized: "On the power adapter, not charging")
    }

    static func lidTitle(_ p: MacStatus.Power) -> String {
        switch p.lid {
        case "closed": String(localized: "Lid closed")
        case "open": String(localized: "Lid open")
        default: String(localized: "No lid")
        }
    }

    static func displayTitle(_ d: MacStatus.Display) -> String {
        switch d.state {
        case "on": String(localized: "Display on")
        case "off": String(localized: "Display off")
        default: String(localized: "No display")
        }
    }

    static func displayDetail(_ d: MacStatus.Display) -> String? {
        if d.state == "none" { return String(localized: "The lid is closed and no monitor is connected.") }
        switch d.external {
        case 0: return nil
        case 1: return String(localized: "With a monitor")
        default: return String(localized: "With \(d.external) monitors")
        }
    }

    static func thermalDetail(_ p: MacStatus.Power) -> String? {
        switch p.thermal {
        case "serious": String(localized: "The Mac is very warm.")
        case "critical": String(localized: "The Mac is too hot and may sleep.")
        default: nil
        }
    }

    static func stayAwakeName(_ mode: MacStayAwake) -> String {
        switch mode {
        case .off: String(localized: "Off")
        case .lidOpen: String(localized: "While the lid is open")
        case .lidClosed: String(localized: "Also with the lid closed")
        }
    }

    static func stayAwakeShortName(_ mode: MacStayAwake) -> String {
        switch mode {
        case .off: String(localized: "Off")
        case .lidOpen: String(localized: "Lid open")
        case .lidClosed: String(localized: "Lid closed too")
        }
    }

    static func awakeDetail(_ a: MacStatus.Awake) -> String {
        if a.otherService { return String(localized: "Another service takes care of this on the Mac.") }
        switch a.blocker {
        case "lowBattery": return String(localized: "Battery below 10 percent: the Mac may sleep now.")
        case "thermal": return String(localized: "The Mac is too hot: it may sleep now.")
        case "nothingToKeep": return String(localized: "Nothing to keep reachable right now: the Mac sleeps as usual.")
        case "helperNotReady":
            return a.helper == "requiresApproval"
                ? String(localized: "Allow aOS's helper on the Mac (System Settings > General > Login Items) to keep it awake with the lid closed.")
                : String(localized: "aOS's helper isn't set up on the Mac yet.")
        default: break
        }
        switch a.setting {
        case .off: return String(localized: "The Mac sleeps as usual.")
        case .lidOpen: return String(localized: "The Mac doesn't fall asleep by itself while something runs. Closing the lid puts it to sleep.")
        case .lidClosed:
            if a.lidClosedMode { return String(localized: "Lid closed: aOS keeps the Mac awake now.") }
            return a.holding ? String(localized: "Ready: the Mac stays awake when the lid closes.")
                             : String(localized: "The Mac stays awake with the lid closed too.")
        }
    }
}

// MARK: - Requests

struct RequestsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassCard(tint: BrandColor.attention) {
            VStack(alignment: .leading, spacing: 12) {
                OverviewRow(symbol: "hand.raised.fill", tint: BrandColor.attention, title: String(localized: "Waiting for you"))
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
        OverviewRow(symbol: symbol, tint: BrandColor.attention, title: title, detail: detail) {
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Workspace

struct WorkspaceCard: View {
    @Environment(AppModel.self) private var model
    let connection: MacConnection
    @State private var actions = ActionState()
    @State private var confirmClose = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                OverviewRow(symbol: symbol, title: String(localized: "Workspace"), detail: stateText)
                if live, let workspace = connection.workspace, workspace.state == .open || workspace.state == .starting {
                    if !workspace.purpose.isEmpty {
                        Text("\u{201E}\(workspace.purpose)\u{201C}").font(.callout).italic()
                            .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                    }
                    if let until = workspace.until {
                        Text("Open until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                    }
                }
                if live, let error = connection.macStatus?.workspace?.error, state == "failed" {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                        .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
                }
                if live, let sessions = connection.workspace?.sessions, !sessions.isEmpty {
                    ForEach(sessions) { session in
                        HStack(spacing: 12) {
                            StatusDot(color: session.state == "running" ? .green : .gray)
                                .frame(width: OverviewRow<EmptyView>.iconWidth)
                            Text(session.title).font(.subheadline)
                            Spacer()
                            Text(Self.describe(sessionState: session.state)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if live { buttons }
                ProblemLine(text: actions.problem)
            }
        }
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .confirmationDialog("Close the workspace?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close", role: .destructive) { actions.run(.workspaceStop, on: connection) }
        } message: {
            if let purpose = connection.workspace?.purpose, !purpose.isEmpty {
                Text("Your agent is using it for \u{201E}\(purpose)\u{201C}. Its work there stops.")
            } else {
                Text("Programs in the workspace end; sign-ins on websites expire as set on the Mac.")
            }
        }
    }

    /// The state as the Mac reports it: mac.status if this Mac knows it, else the older status.
    private var state: String {
        if let state = connection.macStatus?.workspace?.state { return state }
        switch connection.workspace?.state {
        case .open: return "open"
        case .running: return "running"
        case .starting: return "starting"
        case .closing: return "closing"
        case .stopped, nil: return "stopped"
        case .other(let raw): return raw
        }
    }

    /// aOS on the Mac answers now (not while the Mac sleeps or the connection is gone): only then the workspace's
    /// state counts, and its buttons.
    private var live: Bool { connection.companionState == .ready && connection.sleepingSince == nil }

    @ViewBuilder private var buttons: some View {
        let ready = connection.companionState == .ready
        HStack(spacing: 10) {
            if state == "open" || state == "running" {
                Button {
                    model.screenTarget = .workspace
                    model.tab = .screen
                } label: {
                    Label("Show the screen", systemImage: "display")
                }
            }
            if connection.macStatus != nil, ready {
                if state == "stopped" || state == "failed" {
                    Button {
                        actions.run(.workspaceStart, on: connection)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(connection.macStatus?.workspace?.setupComplete == false)
                } else if state == "open" || state == "running" || state == "starting" {
                    Button {
                        if state == "open" { confirmClose = true } else { actions.run(.workspaceStop, on: connection) }
                    } label: {
                        Label("Close", systemImage: "stop.fill")
                    }
                }
            }
            if actions.running != nil { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.glass)
        .disabled(actions.running != nil)
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
        guard live else { return "macwindow" }
        return switch state {
        case "open", "running": "macwindow.on.rectangle"
        case "starting": "hourglass"
        case "closing": "arrow.down.right.and.arrow.up.left"
        case "failed": "exclamationmark.triangle"
        default: "moon.zzz"
        }
    }

    private var stateText: String {
        guard live, connection.workspace != nil || connection.macStatus != nil else {
            return String(localized: "No news from the Mac")
        }
        if connection.macStatus?.workspace?.setupComplete == false {
            return String(localized: "Not set up yet. Finish the setup in aOS on the Mac.")
        }
        switch state {
        case "stopped": return String(localized: "Closed. It opens when your agent needs it.")
        case "starting": return String(localized: "Starting")
        case "open": return String(localized: "Open for your agent")
        case "running": return String(localized: "Running, without an agent in it")
        case "closing": return String(localized: "Closing")
        case "failed": return String(localized: "Didn't start")
        default: return state
        }
    }
}

// MARK: - aOS

/// aOS on the Mac: its Claude Code session, new chats from the Claude app, kept conversations, Bitwarden.
struct AOSCard: View {
    @Environment(AppModel.self) private var model
    let connection: MacConnection
    @State private var actions = ActionState()
    @State private var confirmRestart = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                if let session = connection.macStatus?.session {
                    OverviewRow(symbol: "bubble.left.and.text.bubble.right", title: String(localized: "Claude Code session"),
                                detail: Self.sessionText(session),
                                detailTint: ["needsLogin", "needsAttention", "failed", "missingClaude"].contains(session.state ?? "")
                                    ? .orange : .secondary) {
                        if session.enabled, session.state != nil {
                            Button("Restart", systemImage: "arrow.clockwise") { confirmRestart = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .disabled(actions.running != nil)
                                .accessibilityLabel(Text("Restart the Claude Code session"))
                        }
                    }
                }
                // What to do, under the row that asks for the sign-in (the session's first).
                let sessionSignIn = connection.macStatus?.session.map { $0.enabled && $0.state == "needsLogin" } ?? false
                if sessionSignIn {
                    SignInHelp { model.openNewTerminal() }
                }
                if let chats = connection.macStatus?.newChats {
                    OverviewRow(symbol: "plus.bubble", title: String(localized: "New chats from the Claude app"),
                                detail: Self.chatsText(chats),
                                detailTint: chats.enabled && chats.state == "needsLogin" ? .orange : .secondary)
                }
                if !sessionSignIn, Self.needsSignIn(connection.macStatus) {
                    SignInHelp { model.openNewTerminal() }
                }
                if let kept = connection.macStatus?.kept {
                    OverviewRow(symbol: "bubble.left.and.bubble.right", title: String(localized: "Kept conversations"),
                                detail: kept == 1 ? String(localized: "1 is reachable in the Claude app")
                                                  : String(localized: "\(kept) are reachable in the Claude app"))
                }
                if let vault = connection.macStatus?.bitwarden {
                    OverviewRow(symbol: vault.state == "unlocked" ? "lock.open" : "lock", title: "Bitwarden",
                                detail: Self.vaultText(vault)) {
                        if vault.state == "unlocked" {
                            Button("Lock", systemImage: "lock.fill") { actions.run(.bitwardenLock, on: connection) }
                                .buttonStyle(.glass)
                                .disabled(actions.running != nil)
                        }
                    }
                }
                ProblemLine(text: actions.problem)
            }
        }
        .animation(.snappy(duration: 0.2), value: actions.problem)
        .confirmationDialog("Restart the Claude Code session?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") { actions.run(.sessionRestart, on: connection) }
        } message: {
            Text("aOS on the Mac starts Claude Code again. The conversation continues where it was.")
        }
    }

    /// Claude Code on the Mac waits for a sign-in (the session or new chats say so).
    static func needsSignIn(_ status: MacStatus?) -> Bool {
        (status?.session?.enabled == true && status?.session?.state == "needsLogin")
            || (status?.newChats?.enabled == true && status?.newChats?.state == "needsLogin")
    }

    static func sessionText(_ s: MacStatus.Session) -> String {
        guard s.enabled else { return String(localized: "Off in aOS's settings") }
        switch s.state {
        case "running": return String(localized: "Running, reachable in the Claude app")
        case "starting": return String(localized: "Starting")
        case "restarting": return String(localized: "Restarting")
        case "waitingForNetwork": return String(localized: "Waiting for the network")
        case "needsLogin": return String(localized: "Needs a sign-in to Claude Code on the Mac")
        case "needsAttention": return String(localized: "Claude Code asks something on the Mac")
        case "missingClaude": return String(localized: "Claude Code isn't installed on the Mac")
        case "stopped": return String(localized: "Stopped")
        case "failed": return String(localized: "Keeps stopping. Restart it, or look on the Mac.")
        case nil: return String(localized: "Not set up")
        default: return s.state ?? ""
        }
    }

    static func chatsText(_ c: MacStatus.NewChats) -> String {
        guard c.enabled else { return String(localized: "Off") }
        switch c.state {
        case "running": return String(localized: "On: the Mac appears in the Claude app")
        case "needsLogin": return String(localized: "Needs a sign-in to Claude Code on the Mac")
        case "needsTrust": return String(localized: "Waits for you on the Mac (trust the folder)")
        case "waitingForNetwork": return String(localized: "Waiting for the network")
        case "missingClaude": return String(localized: "Claude Code isn't installed on the Mac")
        default: return String(localized: "Starting")
        }
    }

    static func vaultText(_ v: MacStatus.Vault) -> String {
        switch v.state {
        case "unlocked":
            if let until = v.until {
                return String(localized: "Unlocked until \(until.formatted(date: .omitted, time: .shortened))")
            }
            return String(localized: "Unlocked: sign-ins can use your logins")
        case "locked": return String(localized: "Locked. Unlock it in aOS on the Mac.")
        case "needsHelper": return String(localized: "Needs aOS's background helper on the Mac")
        case "signedOut": return String(localized: "Not signed in")
        default: return String(localized: "Checking …")
        }
    }
}

/// What to do when Claude Code on the Mac needs a sign-in: `claude` once in a terminal there, from here too.
private struct SignInHelp: View {
    let openTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the Mac, run \(Text(verbatim: "claude").font(.footnote.monospaced().weight(.semibold))) once in a terminal and sign in. You can do that from here: Open Terminal starts a new session on the Mac.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openTerminal) {
                Label("Open Terminal", systemImage: "apple.terminal")
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.leading, OverviewRow<EmptyView>.iconWidth + 12)
    }
}

/// What is where, said plainly.
struct PromiseCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FactRow(symbol: "faceid", text: "Your passwords stay in Bitwarden. You approve every sign-in with Face ID.")
            FactRow(symbol: "eye.slash", text: "Your agent never sees a password. aOS fills it into the workspace for you.")
            FactRow(symbol: "lock", text: "The iPhone talks to your Mac over SSH with a key that never leaves this iPhone.")
        }
        .padding(.horizontal, 16)
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
                Text("aOS on your iPhone").font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                Text("Stay in touch with your agent's Mac, wherever you are.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    WelcomePoint(symbol: "person.badge.key", title: "Sign-ins for your agent",
                                 text: "Your agent asks, you approve with Face ID. It never sees the password.")
                    WelcomePoint(symbol: "apple.terminal", title: "Terminal",
                                 text: "Your Mac's shells, which keep running when the connection drops.")
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
            Text("On your Mac, click aOS in the menu bar, then \u{201C}Pair\u{201D} next to iPhone. Then scan the code it shows.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

private struct WelcomePoint: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(BrandColor.indigo).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
