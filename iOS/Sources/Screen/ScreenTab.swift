import AnnexRFB
import SwiftUI

struct ScreenTab: View {
    @Environment(AppModel.self) private var model
    @State private var keyboard = false
    @State private var focus = RemoteScreen.FocusRequest()
    @State private var showGestures = false

    private var session: ScreenSession { model.screen(for: model.screenTarget) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack {
                Color.black.opacity(session.frame == nil ? 0 : 1).ignoresSafeArea()
                if session.frame != nil, session.phase == .live || session.phase == .connecting {
                    RemoteScreen(session: session, mode: model.settings.inputMode, focus: focus)
                        .ignoresSafeArea(edges: .horizontal)
                }
                stateOverlay
                KeyCapture(isActive: $keyboard, session: session).frame(width: 1, height: 1).allowsHitTesting(false)
            }
            .annexBackground()
            .safeAreaInset(edge: .top, spacing: 0) {
                if let help = model.activeHelp, model.screenTarget == .workspace {
                    HelpBanner(request: help) { Task { await model.finishHelp(help) } }
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.phase == .live { controls.padding(.horizontal).padding(.bottom, 8) }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Screen", selection: $model.screenTarget) {
                        Text("Workspace").tag(ScreenTarget.workspace)
                        Text("Mac").tag(ScreenTarget.mac)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gestures", systemImage: "hand.tap") { showGestures = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(session.frame != nil ? .dark : nil, for: .navigationBar)
            .sheet(isPresented: $showGestures) { GestureHelp().presentationDetents([.medium, .large]) }
            .alert(session.notice ?? "", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
                Button("OK") { session.notice = nil }
            }
        }
        .task(id: model.screenTarget) { await start() }
        .onChange(of: model.activeHelp, initial: true) { _, help in
            if let region = help?.region {
                focus = .init(region: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .live, let region = model.activeHelp?.region, model.screenTarget == .workspace {
                focus = .init(region: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            }
        }
        .onDisappear {
            keyboard = false
            if !model.isDemo { session.stop() }
        }
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
                Placeholder(symbol: "display", title: "Screen", text: "") {
                    Button("Connect") { Task { await start() } }.buttonStyle(.glassProminent)
                }
            }
        case .needsLogin:
            if let mac = model.activeMac {
                MacScreenLoginForm(mac: mac) { Task { await start() } }
            }
        case .connecting:
            if session.frame == nil {
                ProgressView("Connecting to the screen …").padding(20).glassEffect(in: RoundedRectangle(cornerRadius: 20))
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
            if !session.inputReady {
                Text("Input works in a moment …")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
            }
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
        if model.screenTarget == .workspace {
            await session.start(mac: connection, login: nil, interval: model.settings.frameRate.interval)
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
            await session.start(mac: connection, login: login, interval: model.settings.frameRate.interval)
        } catch Biometrics.Failure.cancelled {
            session.stop()
        } catch {
            session.showNeedsLogin()
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if keyboard { KeyBar(session: session) }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        model.settings.inputMode = model.settings.inputMode == .trackpad ? .direct : .trackpad
                    } label: {
                        Label(model.settings.inputMode == .trackpad ? "Trackpad" : "Direct",
                              systemImage: model.settings.inputMode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.point.up.left")
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint(Text("Switches how one finger works on the screen"))
                    Spacer(minLength: 0)
                    Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { focus = .init(region: nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                    Button(keyboard ? "Hide keyboard" : "Keyboard", systemImage: keyboard ? "keyboard.chevron.compact.down" : "keyboard") {
                        keyboard.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                }
            }
        }
    }
}

/// Esc, Tab, Return, arrows and the modifier keys (they stay on for the next key).
struct KeyBar: View {
    let session: ScreenSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    key("esc") { session.press(KeyInput.escape) }
                    key("tab", symbol: "arrow.right.to.line") { session.press(Keysyms.tab) }
                    key("return", symbol: "return") { session.press(Keysyms.returnKey) }
                    modifier("⌘", Keysyms.command, name: "Command")
                    modifier("⌥", Keysyms.option, name: "Option")
                    modifier("⌃", Keysyms.control, name: "Control")
                    modifier("⇧", Keysyms.shift, name: "Shift")
                    key("left", symbol: "arrow.left") { session.press(KeyInput.left) }
                    key("down", symbol: "arrow.down") { session.press(KeyInput.down) }
                    key("up", symbol: "arrow.up") { session.press(KeyInput.up) }
                    key("right", symbol: "arrow.right") { session.press(KeyInput.right) }
                    key("delete", symbol: "delete.right") { session.press(KeyInput.forwardDelete) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func key(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(verbatim: title).font(.callout.weight(.medium)) }
            }
            .frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(title))
    }

    private func modifier(_ glyph: String, _ keysym: UInt32, name: String) -> some View {
        let on = session.stickyModifiers.contains(keysym)
        return Button {
            session.toggleSticky(keysym)
        } label: {
            Text(verbatim: glyph).font(.title3.weight(.medium)).frame(minWidth: 26, minHeight: 22)
        }
        .buttonStyle(.glass)
        .tint(on ? BrandColor.indigo : nil)
        .overlay {
            if on { Capsule().stroke(BrandColor.indigo, lineWidth: 2) }
        }
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(on ? .isSelected : [])
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

struct GestureHelp: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Trackpad (one finger moves the pointer)") {
                    GestureRow(symbol: "hand.tap", text: "Tap: click where the pointer is")
                    GestureRow(symbol: "hand.draw", text: "Drag one finger: move the pointer")
                }
                Section("Direct (one finger touches the screen)") {
                    GestureRow(symbol: "hand.point.up.left", text: "Tap: click where you tap")
                    GestureRow(symbol: "hand.draw", text: "Drag one finger: drag (select, move windows)")
                }
                Section("Always") {
                    GestureRow(symbol: "hand.tap", text: "Two-finger tap or long press: right click")
                    GestureRow(symbol: "arrow.up.and.down", text: "Two fingers: scroll")
                    GestureRow(symbol: "arrow.up.left.and.arrow.down.right", text: "Pinch: zoom. Three fingers: move the zoomed picture")
                    GestureRow(symbol: "keyboard", text: "Keyboard: type; ⌘ ⌥ ⌃ ⇧ in the key bar apply to the next key")
                }
            }
            .navigationTitle("Gestures")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GestureRow: View {
    let symbol: String
    let text: LocalizedStringKey
    var body: some View {
        Label(text, systemImage: symbol)
    }
}
