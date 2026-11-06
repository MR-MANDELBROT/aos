import AOSRFB
import SwiftUI

/// The Screen tab: a full-screen viewer of the workspace or the Mac while connected, with a compact toolbar that
/// hides by itself; the tab's own page (connect, log in, what went wrong) otherwise.
struct ScreenTab: View {
    @Environment(AppModel.self) private var model
    @State private var keyboard = false
    @State private var focus = RemoteScreen.FocusRequest()
    @State private var toolbarVisible = true
    @State private var hideToolbar: Task<Void, Never>?
    @State private var showGestures = false
    @State private var showSettings = false
    /// The options the running session was started with; a change restarts it.
    @State private var startedOptions: ScreenOptions?

    private var session: ScreenSession { model.screen(for: model.screenTarget) }
    /// Viewing: everything else gives way (tab bar, status bar).
    private var fullScreen: Bool { session.isRunning }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack {
                (fullScreen ? Color.black : Color.clear).ignoresSafeArea()
                if fullScreen {
                    RemoteScreen(session: session, options: viewerOptions, focus: focus) { touched() }
                        .ignoresSafeArea()
                        .accessibilityAddTraits(.isImage)
                }
                stateOverlay
                KeyCapture(isActive: $keyboard, session: session).frame(width: 1, height: 1).allowsHitTesting(false)
            }
            .aosBackground()
            .overlay(alignment: .top) {
                if fullScreen { topControls }
            }
            .overlay(alignment: .bottom) {
                if fullScreen { bottomControls }
            }
            .toolbar {
                if !fullScreen {
                    ToolbarItem(placement: .principal) { targetPicker.frame(width: 220) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Gestures", systemImage: "hand.tap") { showGestures = true }
                    }
                }
            }
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar(fullScreen ? .hidden : .visible, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .statusBarHidden(fullScreen)
            .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
            .defersSystemGestures(on: fullScreen ? .vertical : [])
            .sheet(isPresented: $showGestures) { GestureHelp().presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ScreenSettingsForm(target: model.screenTarget)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            .alert(session.notice ?? "", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
                Button("OK") { session.notice = nil }
            }
        }
        .task(id: model.screenTarget) {
            // One screen at a time: the other one lets go (the workspace gets its own size back).
            model.screen(for: model.screenTarget == .mac ? .workspace : .mac).stop()
            await start()
        }
        // The Mac is back (after a network change, for example): pick the screen up again.
        .onChange(of: model.connection?.isConnected) { _, connected in
            guard connected == true else { return }
            if case .failed = session.phase { Task { await start() } }
        }
        // A setting that needs a new connection (quality, pace, pointer, shape).
        .onChange(of: currentOptions) { _, options in
            guard session.isRunning, let started = startedOptions, started != options else { return }
            Task { await start() }
        }
        .onChange(of: model.activeHelp, initial: true) { _, help in
            if let region = help?.region {
                focus = .init(region: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .live, let region = model.activeHelp?.region, model.screenTarget == .workspace {
                focus = .init(region: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            }
            if phase == .live { showToolbar() }
        }
        .onDisappear {
            keyboard = false
            if !model.isDemo { session.stop() }
        }
    }

    private var currentOptions: ScreenOptions {
        ScreenOptions(settings: model.settings, cellular: NetworkKind.shared.isCellular)
    }

    private var viewerOptions: ViewerOptions {
        let s = model.settings
        return ViewerOptions(inputMode: s.inputMode,
                             scaling: model.screenTarget == .mac ? s.macScaling : .fit,
                             naturalScrolling: s.naturalScrolling, pointerSpeed: CGFloat(s.pointerSpeed),
                             haptics: s.haptics, localCursor: s.pointerStyle == .local)
    }

    private var targetPicker: some View {
        @Bindable var model = model
        return Picker("Screen", selection: $model.screenTarget) {
            Text("Workspace").tag(ScreenTarget.workspace)
            Text("Mac").tag(ScreenTarget.mac)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Toolbar

    private func touched() {
        // Working on the screen: the toolbar makes room sooner.
        if toolbarVisible, model.settings.autoHideToolbar { scheduleHide(after: 1.2) }
    }

    private func showToolbar() {
        withAnimation(.snappy) { toolbarVisible = true }
        scheduleHide(after: 4)
    }

    private func scheduleHide(after seconds: Double) {
        hideToolbar?.cancel()
        guard model.settings.autoHideToolbar else { return }
        hideToolbar = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toolbarVisible = false }
        }
    }

    @ViewBuilder private var topControls: some View {
        VStack(spacing: 8) {
            if toolbarVisible {
                ScreenToolbar(session: session, keyboard: $keyboard, showSettings: $showSettings,
                              showGestures: $showGestures, focus: $focus, interacted: { showToolbar() },
                              close: { close() }, picker: AnyView(targetPicker.frame(width: 200)))
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Button {
                    showToolbar()
                } label: {
                    Capsule().fill(.white.opacity(0.55)).frame(width: 44, height: 5)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Show the screen's toolbar"))
                .transition(.opacity)
            }
            if let status = statusText {
                Label(status, systemImage: "hourglass")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect()
            }
            if let help = model.activeHelp, model.screenTarget == .workspace {
                HelpBanner(request: help) { Task { await model.finishHelp(help) } }
                    .padding(.horizontal)
            }
        }
        .padding(.top, 4)
    }

    private var statusText: LocalizedStringKey? {
        switch session.phase {
        case .connecting where session.hasPicture: "Connecting again …"
        case .live where !session.inputReady: "Input works in a moment …"
        default: nil
        }
    }

    @ViewBuilder private var bottomControls: some View {
        VStack(spacing: 8) {
            if model.settings.showsScreenStats, session.phase == .live {
                StatsBadge(stats: session.stats).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }
            if keyboard, model.settings.showsKeyBar { KeyBar(session: session).padding(.horizontal, 8) }
        }
        .padding(.bottom, keyboard ? 6 : 10)
    }

    private func close() {
        keyboard = false
        session.stop()
    }

    // MARK: States

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.phase {
        case .idle:
            if model.connection?.isConnected != true {
                Placeholder(symbol: "wifi.slash", title: "Not connected to your Mac",
                            text: "The screen comes through the connection to your Mac. See the overview.")
            } else if model.screenTarget == .workspace, model.connection?.workspace?.state != .open {
                Placeholder(symbol: "moon.zzz", title: "The workspace is closed",
                            text: "It opens when your agent needs it. Then you can watch here.") {
                    Button("Try anyway") { Task { await start() } }.buttonStyle(.glass)
                }
            } else {
                Placeholder(symbol: model.screenTarget == .mac ? "laptopcomputer" : "macwindow",
                            title: model.screenTarget == .mac ? "Your Mac's screen" : "The workspace",
                            text: "Full screen, with the trackpad or touch.") {
                    Button("Connect") { Task { await start() } }.buttonStyle(.glassProminent)
                }
            }
        case .needsLogin:
            if let mac = model.activeMac {
                MacScreenLoginForm(mac: mac) { Task { await start() } }
            }
        case .connecting:
            if !session.hasPicture {
                ProgressView("Connecting to the screen …")
                    .padding(20)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 20))
                    .environment(\.colorScheme, .dark)
            }
        case .failed(let message):
            Placeholder(symbol: "exclamationmark.triangle", title: "No picture", text: LocalizedStringKey(message)) {
                HStack {
                    Button("Try again") { Task { await start() } }.buttonStyle(.glassProminent)
                    if model.screenTarget == .mac, let mac = model.activeMac, SecretStore.hasScreenLogin(for: mac) {
                        Button("Change login") {
                            SecretStore.deleteScreenLogin(for: mac)
                            session.showNeedsLogin()
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        case .live:
            EmptyView()
        }
    }

    private func start() async {
        #if DEBUG
        if model.isDemo { return }
        #endif
        let session = self.session
        guard let connection = model.connection, connection.isConnected else {
            session.stop()
            return
        }
        let options = currentOptions
        startedOptions = options
        if model.screenTarget == .workspace {
            await session.start(mac: connection, login: nil, options: options)
            return
        }
        guard let mac = model.activeMac else { return }
        guard SecretStore.hasScreenLogin(for: mac) else {
            session.showNeedsLogin()
            return
        }
        do {
            let context = try await Biometrics.authenticate(reason: String(localized: "Show the screen of \(mac.name)"))
            defer { context.invalidate() }
            let login = try SecretStore.screenLogin(for: mac, context: context)
            await session.start(mac: connection, login: login, options: options)
        } catch Biometrics.Failure.cancelled {
            session.stop()
        } catch {
            session.showNeedsLogin()
        }
    }
}

/// The agent asks for help in the workspace: what for, and a button to say it's done.
struct HelpBanner: View {
    let request: HelpRequest
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
            }
            Spacer(minLength: 0)
            Button("Done", action: done).buttonStyle(.glassProminent).tint(BrandColor.attention)
        }
        .padding(14)
        .glassEffect(.regular.tint(BrandColor.attention.opacity(0.2)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct Placeholder<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var actions: Actions

    init(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        } actions: {
            actions
        }
    }
}

/// The Mac account for the Mac's own screen sharing, entered once.
struct MacScreenLoginForm: View {
    let mac: PairedMac
    let saved: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroSymbol(systemName: "person.crop.square", size: 56)
                Text("Log in to the screen of \(mac.name)").font(.title3.weight(.semibold))
                Text("Screen sharing on the Mac asks for the name and password of your Mac account, once.")
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    TextField("Account name", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                }
                .textFieldStyle(.roundedBorder)
                FactRow(symbol: "faceid", text: "Kept on this iPhone behind Face ID. It only goes to the Mac's screen sharing, through the SSH connection.")
                FactRow(symbol: "switch.2", text: "Screen Sharing must be on, on the Mac: System Settings > General > Sharing.")
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Button {
                    save()
                } label: {
                    Text("Save and connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(username.isEmpty || password.isEmpty)
            }
            .padding()
            .frame(maxWidth: 520)
        }
        .onAppear { if username.isEmpty { username = mac.user } }
    }

    private func save() {
        do {
            try SecretStore.setScreenLogin(.init(username: username, password: password), for: mac)
            password = ""
            saved()
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode).")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
