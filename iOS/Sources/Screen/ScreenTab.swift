import ScreenClient
import SwiftUI
import UIKit

/// The Screen tab: the workspace or the Mac, each in Open Screen Sharing's session (full screen, its toolbar, menus and
/// gestures); the tab's own page otherwise (which screen, connect, log in, what went wrong).
struct ScreenTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    /// The session was shown when the app went to the background (it starts again on return).
    @State private var resumes = false

    private var session: ScreenSession { model.screen(for: model.screenTarget) }
    /// Viewing: everything else gives way (tab bar, navigation bar).
    private var fullScreen: Bool { session.phase == .running }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if let client = session.client, session.phase == .running {
                    let shown = session
                    ScreenClientView(session: client) { shown.stop() }
                        .ignoresSafeArea()
                        .overlay(alignment: .top) { helpBanner }
                        .id(client.id)
                } else {
                    page.aosBackground()
                }
            }
            .toolbar {
                if !fullScreen {
                    ToolbarItem(placement: .principal) { targetPicker.frame(width: 220) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Screen settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
            }
            .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
            .toolbar(fullScreen ? .hidden : .visible, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ScreenSettingsPage()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
            }
        }
        .task(id: model.screenTarget) {
            // One screen at a time: the other one lets go (the workspace gets its own size back).
            model.screen(for: model.screenTarget == .mac ? .workspace : .mac).stop()
            // A closed workspace waits ("Try anyway" on the page); it shows up when it opens.
            if model.screenTarget == .workspace, !model.isDemo, workspaceClosed { return }
            await start()
        }
        .onChange(of: model.connection?.workspace?.state) { _, state in
            guard state?.isViewable == true, model.screenTarget == .workspace, session.phase == .idle else { return }
            Task { await start() }
        }
        // The Mac is back (after a network change, for example): pick the screen up again.
        .onChange(of: model.connection?.isConnected) { _, connected in
            guard connected == true else { return }
            if case .failed = session.phase { Task { await start() } }
            if resumes, session.phase == .idle { resumes = false; Task { await start() } }
        }
        .onChange(of: model.connection?.companionState) { _, state in
            guard state == .ready else { return }
            if case .failed = session.phase { Task { await start() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { resumes = session.isRunning }
            if phase == .active, resumes, session.phase == .idle, model.connection?.isConnected == true {
                resumes = false
                Task { await start() }
            }
        }
        .onChange(of: model.activeHelp, initial: true) { _, _ in focusOnHelp() }
        .onChange(of: session.client?.hasPicture) { _, _ in focusOnHelp() }
        .onDisappear {
            session.stop()
        }
        #if DEBUG
        .onAppear { if model.isDemo, Demo.sheet == "screen-settings" { showSettings = true } }
        #endif
    }

    /// The Mac says the workspace isn't open (unknown counts as open: then it's tried).
    private var workspaceClosed: Bool {
        switch model.connection?.workspace?.state {
        case .stopped?, .starting?, .closing?: true
        default: false
        }
    }

    private var targetPicker: some View {
        @Bindable var model = model
        return Picker("Screen", selection: $model.screenTarget) {
            Text("Workspace").tag(ScreenTarget.workspace)
            Text("Mac").tag(ScreenTarget.mac)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Help requests

    @ViewBuilder private var helpBanner: some View {
        if let help = model.activeHelp, model.screenTarget == .workspace {
            HelpBanner(request: help) { Task { await model.finishHelp(help) } }
                .padding(.horizontal)
                // Below the session's toolbar handle
                .padding(.top, 52)
        }
    }

    /// The agent's help request points at a region of the workspace: the screen zooms onto it.
    private func focusOnHelp() {
        guard model.screenTarget == .workspace, let region = model.activeHelp?.region, region.width > 0, region.height > 0,
              let client = session.client, client.hasPicture else { return }
        client.focus(on: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
    }

    // MARK: The tab's page

    @ViewBuilder
    private var page: some View {
        switch session.phase {
        case .idle, .running:
            if model.connection?.isConnected != true, !model.isDemo {
                Placeholder(symbol: "wifi.slash", title: "Not connected to your Mac",
                            text: "The screen comes through the connection to your Mac. See the overview.")
            } else if model.screenTarget == .workspace, model.connection?.workspace?.state.isViewable != true, !model.isDemo {
                Placeholder(symbol: "moon.zzz", title: "The workspace is closed",
                            text: "It opens when your agent needs it. Then you can watch here.") {
                    Button("Try anyway") { Task { await start() } }.buttonStyle(.glass)
                }
            } else {
                Placeholder(symbol: model.screenTarget == .mac ? "laptopcomputer" : "macwindow",
                            title: model.screenTarget == .mac ? "Your Mac's screen" : "The workspace",
                            text: "Full screen, with touch, the keyboard and a trackpad or mouse.") {
                    Button("Connect") { Task { await start() } }.buttonStyle(.glassProminent)
                }
            }
        case .needsLogin:
            if let mac = model.activeMac {
                MacScreenLoginForm(mac: mac, problem: session.loginProblem) { Task { await start() } }
            }
        case .preparing:
            ProgressView("Connecting to the screen …")
                .padding(20)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20))
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
        }
    }

    // MARK: Starting

    private func start() async {
        let session = self.session
        #if DEBUG
        // `-AOSScreenDirect HOST:PORT`: the workspace straight from a screen sharing server (no Mac, no SSH).
        if model.isDemo, let direct = Demo.directScreen, model.screenTarget == .workspace {
            let env = ProcessInfo.processInfo.environment
            session.startDirect(host: direct.host, port: direct.port, username: env["AOS_SCREEN_USER"] ?? "",
                                password: env["AOS_SCREEN_PASSWORD"] ?? "")
            return
        }
        // The demo: a still picture from a screen sharing server in the app, shown with the real session.
        if model.isDemo {
            if model.screenTarget == .mac, Demo.screen?.hasPrefix("mac-login") == true {
                session.showNeedsLogin()
                return
            }
            let mac = model.screenTarget == .mac
            if let picture = mac ? Demo.macPicture() : Demo.workspacePicture(fitting: Self.pictureArea()) {
                await session.startDemo(picture, name: mac ? model.activeMac?.name ?? "Mac" : String(localized: "Workspace"))
            }
            return
        }
        #endif
        guard let connection = model.connection, connection.isConnected else {
            session.stop()
            return
        }
        let options = ScreenOptions(settings: model.settings)
        if model.screenTarget == .workspace {
            await session.start(mac: connection, login: nil, options: options, area: Self.pictureArea())
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
            guard let login = try SecretStore.screenLogin(for: mac, context: context) else {
                session.showNeedsLogin()
                return
            }
            await session.start(mac: connection, login: login, options: options, area: Self.pictureArea())
        } catch Biometrics.Failure.cancelled {
            session.stop()
        } catch {
            session.showNeedsLogin()
        }
    }

    /// The area the session will show its picture in, from the window (before the session's view measures it itself).
    static func pictureArea() -> CGSize {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window else { return .zero }
        let insets = window.safeAreaInsets
        return ScreenRoute.pictureArea(window: window.bounds.size, top: insets.top, leading: insets.left,
                                       trailing: insets.right)
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

/// The Mac account for the Mac's own screen sharing, entered once. A form: the field with the focus scrolls into view,
/// and "Save and connect" stays above the keyboard (Return in the password field does the same).
struct MacScreenLoginForm: View {
    let mac: PairedMac
    var problem: String?
    let saved: () -> Void
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
                FactRow(symbol: "faceid", text: "Kept on this iPhone behind Face ID. It only goes to the Mac's screen sharing, through the SSH connection.")
                FactRow(symbol: "switch.2", text: "Screen Sharing must be on, on the Mac: System Settings > General > Sharing.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Always above the keyboard and the tab bar
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
        do {
            try SecretStore.setScreenLogin(.init(username: username, password: password), for: mac)
            password = ""
            focus = nil
            saved()
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode).")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
