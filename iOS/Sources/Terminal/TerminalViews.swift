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
    let session: TerminalSession

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
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.isActive {
                Button("Disconnect", systemImage: "xmark.circle") { session.disconnect() }
            }
        }
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

    private func connect() {
        Task {
            #if DEBUG
            if model.isDemo {
                session.showDemo(Demo.terminalText)
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

/// SwiftTerm's iOS terminal view (with its key bar: esc, ctrl, tab, arrows) in SwiftUI.
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
                    Text("Annex remembers the key and warns you if it ever changes.")
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
