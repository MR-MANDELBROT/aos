import SwiftTerm
import SwiftUI

struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SSHHost?
    @State private var adding = false
    @State private var path: [TerminalSession.Target] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let mac = model.activeMac {
                    Section("Your Mac") {
                        NavigationLink(value: TerminalSession.Target.mac(mac.id)) {
                            HostRow(symbol: "laptopcomputer", title: mac.name, detail: "\(mac.user)@\(mac.lastHost ?? mac.hosts.first ?? "")",
                                    active: model.terminals[.mac(mac.id)]?.isActive == true)
                        }
                    }
                }
                Section {
                    ForEach(model.hosts) { host in
                        NavigationLink(value: TerminalSession.Target.host(host.id)) {
                            HostRow(symbol: "server.rack", title: host.displayName,
                                    detail: host.label.isEmpty ? (host.port == 22 ? "" : ":\(host.port)") : "\(host.user)@\(host.host)",
                                    active: model.terminals[.host(host.id)]?.isActive == true)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.remove(host) }
                            Button("Edit", systemImage: "pencil") { editing = host }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = host }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.remove(host) }
                        }
                    }
                    Button("Add a computer", systemImage: "plus") { adding = true }
                } header: {
                    Text("Other computers")
                } footer: {
                    Text("SSH with this iPhone's key (Settings > SSH key of this iPhone) or a password kept behind Face ID.")
                }
            }
            .navigationTitle("Terminal")
            .navigationDestination(for: TerminalSession.Target.self) { target in
                TerminalScreen(session: model.terminal(for: target))
            }
            .sheet(isPresented: $adding) { HostEditor(host: nil) }
            .sheet(item: $editing) { host in HostEditor(host: host) }
            .overlay {
                if model.activeMac == nil && model.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No computers yet", systemImage: "apple.terminal")
                    } description: {
                        Text("Pair your Mac or add a computer to open a terminal on it.")
                    } actions: {
                        Button("Add a computer") { adding = true }.buttonStyle(.glass)
                    }
                }
            }
            .onAppear {
                #if DEBUG
                if model.isDemo, Demo.tab == "terminal", let mac = model.activeMac, path.isEmpty, Demo.sheet == "shell" {
                    path = [.mac(mac.id)]
                }
                #endif
            }
        }
    }
}

private struct HostRow: View {
    let symbol: String
    let title: String
    let detail: String
    let active: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(BrandColor.indigo).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            if active { StatusDot(color: .green) }
        }
    }
}

// MARK: - The terminal

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let session: TerminalSession
    @State private var visible = false

    var body: some View {
        ZStack {
            TerminalViewRepresentable(view: session.view)
                .ignoresSafeArea(.container, edges: .bottom)
            switch session.phase {
            case .connecting:
                ProgressView("Connecting …").padding(20).glassEffect(in: RoundedRectangle(cornerRadius: 20))
            case .failed(let message):
                StateOverlay(symbol: "exclamationmark.triangle", text: message, action: "Try again") { connect() }
            case .ended:
                StateOverlay(symbol: "power", text: String(localized: "The session ended."), action: "Connect again") { connect() }
            default:
                EmptyView()
            }
        }
        .overlay(alignment: .top) {
            if let notice = session.notice {
                Text(notice.text)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(in: Capsule())
                    .padding(.top, 10)
                    .id(notice.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: session.notice)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        // The terminal gets the rows the tab bar would take.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(session.keyboardShown ? "Hide Keyboard" : "Show Keyboard",
                       systemImage: session.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard") {
                    session.toggleKeyboard()
                }
                TerminalMenu(session: session)
            }
        }
        .alert(pasteTitle, isPresented: Binding(get: { session.pendingPaste != nil }, set: { if !$0 { session.pendingPaste = nil } }),
               presenting: session.pendingPaste) { text in
            Button("Paste") { session.confirmPaste(text) }
            Button("Cancel", role: .cancel) { session.pendingPaste = nil }
        } message: { _ in
            Text("The shell runs each line as soon as it arrives.")
        }
        .onAppear {
            visible = true
            session.setFontSize(model.settings.terminalFontSize)
        }
        .onDisappear { visible = false }
        .onChange(of: session.fontSize) { _, size in model.settings.terminalFontSize = Double(size) }
        .onChange(of: keepsScreenOn, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .task {
            if session.phase == .idle { connect() }
        }
        .sheet(isPresented: Binding(get: { if case .confirmHostKey = session.phase { true } else { false } },
                                    set: { if !$0, case .confirmHostKey = session.phase { session.disconnect() } })) {
            if case .confirmHostKey(let host, let key, let fingerprint) = session.phase, case .host(let id) = session.id,
               let entry = model.hosts.first(where: { $0.id == id }) {
                HostKeyPrompt(host: host, fingerprint: fingerprint) {
                    model.trust(key: key, for: entry)
                    connect()
                }
            }
        }
        .alert("The key of this computer changed", isPresented: Binding(
            get: { if case .hostKeyChanged = session.phase { true } else { false } }, set: { _ in })) {
            Button("Cancel", role: .cancel) { session.disconnect() }
            Button("Forget the old key", role: .destructive) {
                if case .host(let id) = session.id, let entry = model.hosts.first(where: { $0.id == id }) {
                    model.forgetKey(of: entry)
                    connect()
                }
            }
        } message: {
            if case .hostKeyChanged(let host, let fingerprint) = session.phase {
                Text("\(host) now presents \(fingerprint). That happens when the computer was set up again, but it can also mean that someone is in between. Only continue if you know why it changed.")
            }
        }
    }

    /// While the terminal is on screen and connected, if the person wants that.
    private var keepsScreenOn: Bool {
        visible && scenePhase == .active && session.phase == .connected && model.settings.terminalKeepsScreenOn
    }

    private var pasteTitle: String {
        let lines = session.pendingPaste?.split(whereSeparator: \.isNewline).count ?? 0
        return String(localized: "Paste \(lines) lines?")
    }

    private func connect() {
        Task {
            #if DEBUG
            if model.isDemo {
                session.showDemo(Demo.terminalText)
                // -AOSDemoTerminal selection|keys|menu: states of the terminal for screenshots
                if let state = UserDefaults.standard.string(forKey: "AOSDemoTerminal") {
                    try? await Task.sleep(for: .seconds(1.5))
                    session.view.showDemoState(state)
                }
                return
            }
            #endif
            switch session.id {
            case .mac:
                if let connection = model.connection { await session.connect(mac: connection) }
            case .host(let id):
                guard let host = model.hosts.first(where: { $0.id == id }) else { return }
                var password: String?
                if host.auth == .password {
                    do {
                        let context = try await Biometrics.authenticate(reason: String(localized: "Use the password for \(host.displayName)"))
                        password = try SecretStore.password(for: host, context: context)
                        context.invalidate()
                    } catch {
                        return
                    }
                }
                await session.connect(host: host, key: model.deviceKey, password: password)
            }
        }
    }
}

private struct StateOverlay: View {
    let symbol: String
    let text: String
    let action: LocalizedStringKey
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center)
            Button(action, action: perform).buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .glassEffect(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}

/// The terminal's menu: copying, text size, keeping the screen on, disconnecting.
private struct TerminalMenu: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession

    var body: some View {
        Menu {
            Section {
                Button("Copy Screen", systemImage: "doc.on.doc") { session.copyScreen() }
                Button("Copy Last Output", systemImage: "text.line.last.and.arrowtriangle.forward") { session.copyLastOutput() }
                Button("Select All", systemImage: "selection.pin.in.out") { session.view.selectAll(nil) }
            }
            Section("Text Size") {
                ControlGroup {
                    Button("Smaller", systemImage: "textformat.size.smaller") { session.adjustFontSize(by: -1) }
                    Button("Default", systemImage: "textformat.size") { session.adjustFontSize(to: TerminalFontSize.standard) }
                    Button("Bigger", systemImage: "textformat.size.larger") { session.adjustFontSize(by: 1) }
                }
            }
            Section {
                Toggle("Keep Screen On", systemImage: "sun.max", isOn: Binding(
                    get: { model.settings.terminalKeepsScreenOn }, set: { model.settings.terminalKeepsScreenOn = $0 }))
            }
            if session.isActive {
                Section {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { session.disconnect() }
                }
            }
        } label: {
            Label("Terminal", systemImage: "ellipsis")
        }
    }
}

/// The terminal view (AOSTerminalView with its key bar) in SwiftUI.
struct TerminalViewRepresentable: UIViewRepresentable {
    let view: TerminalView

    func makeUIView(context: Context) -> TerminalView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

struct HostKeyPrompt: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    let fingerprint: String
    let trust: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeroSymbol(systemName: "questionmark.key.filled", tint: .orange, size: 60)
                    Text("First connection to \(host)").font(.title2.weight(.semibold))
                    Text("Check that this is the key of your computer. On it, run:")
                    Text("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
                        .font(.footnote.monospaced()).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                    Text("It must show:")
                    KeyText(text: fingerprint, font: .callout.monospaced().weight(.semibold))
                    Text("aOS remembers the key and warns you if it ever changes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        trust()
                        dismiss()
                    } label: {
                        Text("Trust and connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Adding a computer

struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: SSHHost?

    @State private var label: String
    @State private var address: String
    @State private var port: String
    @State private var user: String
    @State private var auth: SSHHost.Auth
    @State private var password = ""
    @State private var error: String?

    init(host: SSHHost?) {
        self.host = host
        _label = State(initialValue: host?.label ?? "")
        _address = State(initialValue: host?.host ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _user = State(initialValue: host?.user ?? "")
        _auth = State(initialValue: host?.auth ?? .deviceKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $label)
                    TextField("Address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("User", text: $user)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Log in with", selection: $auth) {
                        Text("This iPhone's key").tag(SSHHost.Auth.deviceKey)
                        Text("Password").tag(SSHHost.Auth.password)
                    }
                    .pickerStyle(.segmented)
                    if auth == .password {
                        SecureField(host == nil ? "Password" : "New password (empty keeps the old one)", text: $password)
                            .textContentType(.password)
                    }
                } footer: {
                    Text(auth == .deviceKey
                         ? "Add this iPhone's public key (Settings > SSH key of this iPhone) to ~/.ssh/authorized_keys on that computer."
                         : "The password stays on this iPhone, behind Face ID.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(host == nil ? "Add a computer" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || user.trimmingCharacters(in: .whitespaces).isEmpty
                                  || UInt16(port) == nil || (auth == .password && host == nil && password.isEmpty))
                }
            }
        }
    }

    private func save() {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = host ?? SSHHost(label: "", host: "", user: "")
        // A new address is another computer: its key has to be trusted again.
        if updated.host != trimmedAddress || updated.port != UInt16(port) { updated.hostKey = nil }
        updated.label = label.trimmingCharacters(in: .whitespaces)
        updated.host = trimmedAddress
        updated.port = UInt16(port) ?? 22
        updated.user = user.trimmingCharacters(in: .whitespaces)
        updated.auth = auth
        do {
            try model.save(updated, password: auth == .password && !password.isEmpty ? password : nil)
            password = ""
            dismiss()
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode).")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
