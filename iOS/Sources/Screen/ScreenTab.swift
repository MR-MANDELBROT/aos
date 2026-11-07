import ScreenClient
import SwiftUI
import UIKit

/// The Screen tab: Open Screen Sharing's selection view with two cards, the workspace and the Mac (the last picture,
/// a dot that is green while the screen can be reached). A tap on a card connects that screen, nothing connects by
/// itself; the session then fills the screen (Open Screen Sharing's toolbar, menus and gestures).
struct ScreenTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showSettings = false
    @State private var confirmStart = false
    @State private var confirmClose = false
    /// The workspace was started from its card to be shown: it connects once it runs.
    @State private var showsWhenRunning = false
    @State private var notice: String?
    @State private var actions = ActionState()

    /// The session on screen (one at a time).
    private var shown: ScreenSession? {
        [model.workspaceScreen, model.macScreen].first { $0.phase == .running && $0.client != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session = shown, let client = session.client {
                    ScreenClientView(session: client) { [weak client] in
                        if let client { session.closed(client) }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .top) { helpBanner(over: session.target) }
                    .id(client.id)
                } else {
                    selection.aosBackground()
                }
            }
            .navigationTitle(shown == nil ? String(localized: "Screen") : "")
            .toolbar {
                if shown == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Screen settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
            }
            .toolbar(shown == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar(shown == nil ? .visible : .hidden, for: .tabBar)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ScreenSettingsPage()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
            }
            .sheet(isPresented: loginShown) {
                if let mac = model.activeMac {
                    NavigationStack {
                        MacScreenLoginForm(mac: mac, problem: model.macScreen.loginProblem) { login in
                            connectMac(with: login)
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.macScreen.cancelLogin() }
                            }
                        }
                    }
                }
            }
            .confirmationDialog("The workspace is closed", isPresented: $confirmStart, titleVisibility: .visible) {
                Button("Start and show") { startWorkspace(showing: true) }
            } message: {
                Text("It starts now and shows up here as soon as it runs.")
            }
            .confirmationDialog("Close the workspace?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Close", role: .destructive) { stopWorkspace() }
            } message: {
                if let purpose = model.connection?.workspace?.purpose, !purpose.isEmpty {
                    Text("Your agent is using it for \u{201E}\(purpose)\u{201C}. Its work there stops.")
                } else {
                    Text("Programs in the workspace end; sign-ins on websites expire as set on the Mac.")
                }
            }
        }
        // Requests from elsewhere (the overview's "Show the screen", a help request the person opened): taps too.
        .onAppear(perform: takeRequest)
        .onChange(of: model.screenRequest) { _, _ in takeRequest() }
        .onChange(of: model.tab) { _, _ in takeRequest() }
        .onChange(of: workspaceViewable) { _, viewable in
            guard viewable, showsWhenRunning else { return }
            showsWhenRunning = false
            connect(.workspace)
        }
        .onChange(of: model.activeHelp, initial: true) { _, _ in focusOnHelp() }
        .onChange(of: shown?.client?.hasPicture) { _, _ in focusOnHelp() }
        .onDisappear {
            model.macScreen.stop()
            model.workspaceScreen.stop()
        }
        #if DEBUG
        .onAppear { if model.isDemo, Demo.sheet == "screen-settings" { showSettings = true } }
        #endif
    }

    private var loginShown: Binding<Bool> {
        Binding(get: { model.macScreen.phase == .needsLogin && shown == nil },
                set: { if !$0 { model.macScreen.cancelLogin() } })
    }

    // MARK: The cards

    private var columns: [GridItem] {
        // One column on an iPhone held upright, as Open Screen Sharing's grid
        sizeClass == .compact ? [GridItem(.flexible(), alignment: .top)]
            : [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)]
    }

    private var selection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let help = model.activeHelp {
                    HelpBanner(request: help, show: { tapWorkspace() }) { Task { await model.finishHelp(help) } }
                }
                if let message = problem {
                    NoticeBanner(text: message) { clearProblem() }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    workspaceCard
                    macCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.snappy(duration: 0.2), value: problem)
        }
        // The workspace's state while the cards are on screen: now and every 15 s (as the overview does).
        .task(id: model.connection?.companionState == .ready) {
            while !Task.isCancelled {
                await model.connection?.refreshMacStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var workspaceCard: some View {
        let session = model.workspaceScreen
        let id = screenID(.workspace)
        let record = id.flatMap { ScreenClient.record(of: $0) }
        return VStack(alignment: .leading, spacing: 12) {
            Button { tapWorkspace() } label: {
                ScreenCard(name: String(localized: "Workspace"), detail: workspaceText, model: record?.model ?? "",
                           enclosureColor: record?.enclosureColor ?? "", thumbnail: id.flatMap(picture),
                           availability: workspaceAvailability)
                    .overlay { if session.phase == .preparing || session.phase == .paused { Connecting() } }
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityHint(Text("Shows the workspace's screen"))
            workspaceActions
        }
    }

    private var macCard: some View {
        let session = model.macScreen
        let id = screenID(.mac)
        let record = id.flatMap { ScreenClient.record(of: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Button { connect(.mac) } label: {
                ScreenCard(name: model.activeMac?.name ?? "Mac", detail: macText(record), model: record?.model ?? "",
                           enclosureColor: record?.enclosureColor ?? "", thumbnail: id.flatMap(picture),
                           availability: macAvailability)
                    .overlay { if session.phase == .preparing || session.phase == .paused { Connecting() } }
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityHint(Text("Shows your Mac's screen"))
            .contextMenu {
                if let mac = model.activeMac {
                    Button("Change login", systemImage: "person.crop.square") {
                        SecretStore.deleteScreenLogin(for: mac)
                        model.workspaceScreen.stop()
                        model.macScreen.showNeedsLogin()
                    }
                }
            }
            if let note = macNote {
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func screenID(_ target: ScreenTarget) -> UUID? {
        model.activeMac.map { ScreenRoute.screenID(target, mac: $0) }
    }

    private func picture(_ id: UUID) -> Data? { ScreenPictures.shared.picture(for: id) }

    // MARK: The workspace's state

    /// The state as the Mac reports it: mac.status if this Mac knows it, else the older status (as the overview).
    private var workspaceState: String? {
        guard let connection = model.connection, connection.companionState == .ready else { return nil }
        if let state = connection.macStatus?.workspace?.state { return state }
        switch connection.workspace?.state {
        case .open?: return "open"
        case .running?: return "running"
        case .starting?: return "starting"
        case .closing?: return "closing"
        case .stopped?: return "stopped"
        case .other(let raw)?: return raw
        case nil: return nil
        }
    }

    private var workspaceViewable: Bool {
        model.isDemo || (model.connection?.isConnected == true && (workspaceState == "open" || workspaceState == "running"))
    }

    private var workspaceAvailability: ScreenCard.Availability? {
        if model.isDemo { return .available }
        guard model.connection?.isConnected == true else { return .unavailable }
        guard workspaceState != nil else { return nil }
        return workspaceViewable ? .available : .unavailable
    }

    private var macAvailability: ScreenCard.Availability? {
        if model.isDemo { return .available }
        guard let connection = model.connection else { return nil }
        return connection.isConnected ? .available : .unavailable
    }

    private var workspaceText: String {
        if model.isDemo { return String(localized: "Running, without an agent in it") }
        guard model.connection?.isConnected == true else { return String(localized: "Not connected to your Mac") }
        if model.connection?.macStatus?.workspace?.setupComplete == false { return String(localized: "Not set up yet") }
        switch workspaceState {
        case "stopped"?: return String(localized: "Closed")
        case "starting"?: return String(localized: "Starting")
        case "open"?: return String(localized: "Open for your agent")
        case "running"?: return String(localized: "Running, without an agent in it")
        case "closing"?: return String(localized: "Closing")
        case "failed"?: return String(localized: "Didn't start")
        case let other?: return other
        case nil: return String(localized: "No news from the Mac")
        }
    }

    private func macText(_ record: ScreenRecord?) -> String {
        if model.isDemo { return String(localized: "Connected") }
        guard model.connection?.isConnected == true else { return String(localized: "Not connected to your Mac") }
        return record?.lastConnectedText ?? String(localized: "Connected")
    }

    /// Why the Mac kept its own size (the iPhone's size was wanted, the direct path wasn't there).
    private var macNote: String? {
        guard model.settings.screenMatchesPhone, let reason = model.macScreen.tunnelReason else { return nil }
        switch reason {
        case .noAddress, .unreachable:
            return String(localized: "Through SSH your Mac keeps its own size. In the iPhone's size it comes directly: in the same Wi-Fi, or with the Tailscale app's VPN on.")
        case .tailnetWithoutVPN:
            return String(localized: "Through aOS's Tailscale your Mac keeps its own size. In the iPhone's size it comes with the Tailscale app's VPN on, or in the same Wi-Fi.")
        case .noHighPerformance:
            return String(localized: "Your Mac keeps its own size: its screen sharing has no high performance mode (that needs macOS 14 or later on Apple silicon).")
        case .failed:
            let text = String(localized: "Your Mac came through SSH in its own size: the direct way didn't work this time.")
            guard let detail = model.macScreen.tunnelDetail, !detail.isEmpty else { return text }
            return text + " (" + detail + ")"
        }
    }

    // MARK: Start and close

    @ViewBuilder private var workspaceActions: some View {
        let ready = model.connection?.companionState == .ready && model.connection?.macStatusUnsupported == false
        HStack(spacing: 10) {
            if ready, let state = workspaceState {
                if state == "stopped" || state == "failed" {
                    Button { startWorkspace(showing: false) } label: { Label("Start", systemImage: "play.fill") }
                        .disabled(model.connection?.macStatus?.workspace?.setupComplete == false)
                } else if state == "open" || state == "running" || state == "starting" {
                    Button {
                        if state == "open" { confirmClose = true } else { stopWorkspace() }
                    } label: {
                        Label("Close", systemImage: "stop.fill")
                    }
                }
            }
            if actions.running != nil || showsWhenRunning { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.glass)
        .disabled(actions.running != nil)
        if let problem = actions.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startWorkspace(showing: Bool) {
        guard let connection = model.connection else { return }
        showsWhenRunning = showing
        actions.run(.workspaceStart, on: connection) { _ in }
    }

    private func stopWorkspace() {
        guard let connection = model.connection else { return }
        showsWhenRunning = false
        model.workspaceScreen.stop()
        actions.run(.workspaceStop, on: connection)
    }

    // MARK: Connecting

    private func tapWorkspace() {
        guard model.isDemo || model.connection?.isConnected == true else {
            notice = String(localized: "Not connected to your Mac. The overview shows why.")
            return
        }
        if !workspaceViewable, model.connection?.companionState == .ready, workspaceState != nil {
            if model.connection?.macStatus?.workspace?.setupComplete == false {
                notice = String(localized: "The workspace isn't set up yet. Finish the setup in aOS on the Mac.")
            } else if workspaceState == "starting" {
                showsWhenRunning = true
            } else {
                confirmStart = true
            }
            return
        }
        connect(.workspace)
    }

    /// A request from elsewhere: the screen someone asked to see, once.
    private func takeRequest() {
        guard model.tab == .screen, let target = model.screenRequest else { return }
        model.screenRequest = nil
        target == .workspace ? tapWorkspace() : connect(.mac)
    }

    /// Connects a screen (the other one lets go): the workspace with its sealed login, the Mac behind Face ID once.
    private func connect(_ target: ScreenTarget) {
        notice = nil
        let session = model.screen(for: target)
        model.screen(for: target == .mac ? .workspace : .mac).stop()
        guard session.phase != .preparing else { return }
        let options = ScreenOptions(settings: model.settings)
        let area = ScreenSession.currentArea(resolutionScale: options.resolutionScale)
        session.onResolutionScale = { [settings = model.settings] in settings.screenResolution = $0 }
        #if DEBUG
        if model.isDemo {
            connectDemo(target, area: area)
            return
        }
        #endif
        guard let connection = model.connection, connection.isConnected else {
            notice = String(localized: "Not connected to your Mac. The overview shows why.")
            return
        }
        Task { await session.connect(mac: connection, options: options, area: area) }
    }

    /// The login was just typed (and saved): this connect uses it as it is, without Face ID.
    private func connectMac(with login: SecretStore.ScreenLogin) {
        let session = model.macScreen
        let options = ScreenOptions(settings: model.settings)
        #if DEBUG
        if model.isDemo {
            session.stop()
            connectDemo(.mac, area: ScreenSession.currentArea(resolutionScale: options.resolutionScale))
            return
        }
        #endif
        guard let connection = model.connection, connection.isConnected else {
            session.stop()
            notice = String(localized: "Not connected to your Mac. The overview shows why.")
            return
        }
        session.onResolutionScale = { [settings = model.settings] in settings.screenResolution = $0 }
        Task {
            await session.start(mac: connection, login: login, options: options,
                                area: ScreenSession.currentArea(resolutionScale: options.resolutionScale))
        }
    }

    #if DEBUG
    /// The demo: a still picture from a screen sharing server in the app, shown with the real session.
    private func connectDemo(_ target: ScreenTarget, area: ScreenArea) {
        let session = model.screen(for: target)
        // `-AOSScreenDirect HOST:PORT`: the workspace straight from a screen sharing server (no Mac, no SSH).
        if let direct = Demo.directScreen, target == .workspace {
            let env = ProcessInfo.processInfo.environment
            session.startDirect(host: direct.host, port: direct.port, username: env["AOS_SCREEN_USER"] ?? "",
                                password: env["AOS_SCREEN_PASSWORD"] ?? "")
            return
        }
        if target == .mac, Demo.screen?.hasPrefix("mac-login") == true, session.phase != .needsLogin {
            session.showNeedsLogin()
            return
        }
        let mac = target == .mac
        guard let picture = mac ? Demo.macPicture() : Demo.workspacePicture(fitting: area.points),
              let id = screenID(target) else { return }
        Task { await session.startDemo(picture, name: mac ? model.activeMac?.name ?? "Mac" : String(localized: "Workspace"), screenID: id) }
    }
    #endif

    /// What went wrong with the last connect, or a notice.
    private var problem: String? {
        if let notice { return notice }
        for target in [ScreenTarget.workspace, .mac] {
            if case .failed(let message) = model.screen(for: target).phase {
                return target == .workspace ? String(localized: "No picture from the workspace: \(message)")
                    : String(localized: "No picture from your Mac: \(message)")
            }
        }
        return nil
    }

    private func clearProblem() {
        notice = nil
        for target in [ScreenTarget.workspace, .mac] {
            if case .failed = model.screen(for: target).phase { model.screen(for: target).stop() }
        }
    }

    // MARK: Help requests

    @ViewBuilder private func helpBanner(over target: ScreenTarget) -> some View {
        if let help = model.activeHelp {
            HelpBanner(request: help, show: target == .workspace ? nil : { tapWorkspace() }) {
                Task { await model.finishHelp(help) }
            }
            .padding(.horizontal)
            // Below the session's toolbar handle
            .padding(.top, 52)
        }
    }

    /// The agent's help request points at a region of the workspace: the screen zooms onto it.
    private func focusOnHelp() {
        guard model.workspaceScreen.phase == .running, let region = model.activeHelp?.region, region.width > 0,
              region.height > 0, let client = model.workspaceScreen.client, client.hasPicture else { return }
        client.focus(on: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
    }
}

/// Connecting: over the card's picture.
private struct Connecting: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .padding(18)
            .glassEffect(in: Circle())
    }
}

/// The agent asks for help in the workspace: what for, a button to show the workspace (when it isn't on screen), and
/// one to say it's done.
struct HelpBanner: View {
    let request: HelpRequest
    var show: (() -> Void)?
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.title3).foregroundStyle(BrandColor.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.agent.isEmpty ? String(localized: "Your agent") : request.agent) asks for help")
                    .font(.subheadline.weight(.semibold))
                if !request.purpose.isEmpty {
                    Text(request.purpose).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                // Above the cards: the workspace to show, then done
                if let show {
                    HStack(spacing: 10) {
                        Button("Show the workspace", action: show).buttonStyle(.glassProminent).tint(BrandColor.attention)
                        Button("Done", action: done).buttonStyle(.glass)
                    }
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
            if show == nil {
                Button("Done", action: done).buttonStyle(.glassProminent).tint(BrandColor.attention)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(BrandColor.attention.opacity(0.2)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// What went wrong, above the cards, until the person dismisses it or connects again.
private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("OK", action: dismiss).buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .transition(.opacity)
    }
}

/// The Mac account for the Mac's own screen sharing, entered once. A form: the field with the focus scrolls into view,
/// and "Save and connect" stays above the keyboard (Return in the password field does the same).
struct MacScreenLoginForm: View {
    let mac: PairedMac
    var problem: String?
    /// The login, saved: this connect uses it right away (no Face ID for what was just typed).
    let saved: (SecretStore.ScreenLogin) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case username, password }

    private var canSave: Bool { !username.isEmpty && !password.isEmpty }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HeroSymbol(systemName: "person.crop.square", size: 56)
                    Text("Log in to the screen of \(mac.name)").font(.title3.weight(.semibold))
                    Text("Screen sharing on the Mac asks for the name and password of your Mac account, once.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Account name", text: $username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(save)
            } footer: {
                if let message = error ?? problem {
                    Text(message).foregroundStyle(.red)
                }
            }
            Section {
                FactRow(symbol: "faceid", text: "Kept on this iPhone behind Face ID. It only goes to the Mac's screen sharing, through the SSH connection or directly in the same network.")
                FactRow(symbol: "switch.2", text: "Screen Sharing must be on, on the Mac: System Settings > General > Sharing.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Always above the keyboard
        .safeAreaInset(edge: .bottom) {
            Button {
                save()
            } label: {
                Text("Save and connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!canSave)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Mac account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if username.isEmpty { username = mac.user }
            #if DEBUG
            // The demo's look at the form with the keyboard up (`-AOSDemoScreen mac-login-keyboard`)
            if Demo.isRequested, Demo.screen == "mac-login-keyboard" {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    focus = .password
                }
            }
            #endif
        }
    }

    private func save() {
        guard canSave else { return }
        let login = SecretStore.ScreenLogin(username: username, password: password)
        do {
            #if DEBUG
            if Demo.isRequested {
                focus = nil
                saved(login)
                return
            }
            #endif
            try SecretStore.setScreenLogin(login, for: mac)
            password = ""
            focus = nil
            saved(login)
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode).")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
