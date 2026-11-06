import SwiftUI
import UniformTypeIdentifiers

/// The vault tab ("Tresor"): logins on this iPhone, behind Face ID.
struct VaultTab: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var editing: VaultEntry?
    @State private var adding = false
    @State private var importing = false
    @State private var path: [VaultEntry.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.vault.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .annexBackground()
            .navigationTitle("Vault")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New login", systemImage: "plus") { adding = true }
                        Button("Import from Bitwarden", systemImage: "square.and.arrow.down") { importing = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: VaultEntry.ID.self) { id in
                VaultDetailView(id: id)
            }
            .sheet(isPresented: $adding) { VaultEditorView(entry: nil) }
            .sheet(isPresented: $importing) { ImportView() }
            .onAppear {
                #if DEBUG
                guard model.isDemo, Demo.tab == "vault" else { return }
                switch Demo.sheet {
                case "import": importing = true
                case "editor": adding = true
                case "detail": if let first = model.vault.entries.first(where: { $0.hasTOTP }) { path = [first.id] }
                default: break
                }
                #endif
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.vault.entries(matching: search)) { entry in
                    NavigationLink(value: entry.id) { VaultRow(entry: entry) }
                }
            } footer: {
                Label("Your passwords stay on this iPhone, locked with Face ID.", systemImage: "faceid")
                    .font(.footnote)
                    .padding(.top, 8)
            }
        }
        .searchable(text: $search, prompt: Text("Search logins"))
        .overlay {
            if !search.isEmpty && model.vault.entries(matching: search).isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                HeroSymbol(systemName: "key.horizontal", size: 76).padding(.top, 40)
                Text("No logins yet").font(.title2.weight(.semibold))
                Text("When your agent needs to sign in somewhere, Annex finds the login here and asks you first.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Button {
                        importing = true
                    } label: {
                        Label("Import from Bitwarden", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button {
                        adding = true
                    } label: {
                        Label("Add a login", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                PromiseList().padding(.top, 8)
            }
            .padding()
        }
    }
}

struct PromiseList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FactRow(symbol: "iphone", text: "Your passwords stay on this iPhone, in its keychain. They aren't synced or backed up.")
            FactRow(symbol: "faceid", text: "Every look at a password needs Face ID or your passcode.")
            FactRow(symbol: "eye.slash", text: "Your agent never sees them. Annex fills them in for it after you approve.")
        }
    }
}

struct VaultRow: View {
    let entry: VaultEntry

    var body: some View {
        HStack(spacing: 12) {
            Monogram(text: entry.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                Text(entry.username.isEmpty ? (entry.primaryHost ?? "") : entry.username)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.hasTOTP {
                Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Has a one-time code"))
            }
        }
    }
}

/// A letter in a tinted circle instead of a site's icon (nothing is loaded from the web).
struct Monogram: View {
    let text: String
    var size: CGFloat = 36

    var body: some View {
        let letter = text.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        Text(letter)
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(BrandColor.indigo)
            .frame(width: size, height: size)
            .background(BrandColor.indigo.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

struct VaultDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var secret: VaultSecret?
    @State private var revealPassword = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Group {
            if let entry = model.vault.entry(id: id) {
                form(entry)
            } else {
                ContentUnavailableView("Login deleted", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { secret = nil; revealPassword = false }
    }

    private func form(_ entry: VaultEntry) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Monogram(text: entry.title, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.title3.weight(.semibold))
                        if let host = entry.primaryHost { Text(host).foregroundStyle(.secondary) }
                    }
                }
            }
            Section {
                if !entry.username.isEmpty {
                    LabeledContent("User name") {
                        Text(entry.username).textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Copy user name", systemImage: "doc.on.doc") { Clipboard.copyPlain(entry.username) }
                    }
                }
                LabeledContent("Password") {
                    if revealPassword, let secret {
                        Text(secret.password).font(.body.monospaced()).textSelection(.enabled)
                    } else {
                        Text(verbatim: "••••••••••").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(revealPassword ? "Hide" : "Show", systemImage: revealPassword ? "eye.slash" : "eye") {
                        if revealPassword { revealPassword = false } else { Task { await unlock(entry) { revealPassword = true } } }
                    }
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        Task { await unlock(entry) { copyPassword() } }
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                if let message { Text(message) }
            }
            if entry.hasTOTP {
                Section("One-time code") {
                    if let secret, let totp = try? TOTP(parsing: secret.totp) {
                        TOTPCodeView(totp: totp)
                    } else {
                        Button("Show code", systemImage: "faceid") { Task { await unlock(entry) {} } }
                    }
                }
            }
            if !entry.uris.isEmpty {
                Section("Websites") {
                    ForEach(entry.uris, id: \.self) { uri in
                        Text(uri).font(.callout).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            if entry.hasNotes {
                Section("Notes") {
                    if let secret {
                        Text(secret.notes).textSelection(.enabled)
                    } else {
                        Button("Show notes", systemImage: "faceid") { Task { await unlock(entry) {} } }
                    }
                }
            }
            Section {
                Button("Delete login", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .toolbar {
            Button("Edit") { Task { await unlock(entry) { editing = true } } }
        }
        .sheet(isPresented: $editing, onDismiss: { secret = nil; revealPassword = false }) {
            VaultEditorView(entry: entry, secret: secret)
        }
        .confirmationDialog("Delete \u{201E}\(entry.title)\u{201C}?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? model.vault.delete(entry)
                dismiss()
            }
        } message: {
            Text("The login is removed from this iPhone. This can't be undone.")
        }
    }

    /// Face ID once per visit of the page; the secret stays in memory only while the page is shown.
    private func unlock(_ entry: VaultEntry, then action: () -> Void) async {
        if secret == nil {
            do {
                secret = try await model.vault.unlock(entry, reason: String(localized: "Show the login for \(entry.title)"))
            } catch Biometrics.Failure.cancelled {
                return
            } catch {
                message = error.localizedDescription
                return
            }
        }
        action()
    }

    private func copyPassword() {
        guard let secret else { return }
        Clipboard.copy(secret.password, expiresAfter: model.settings.clipboardSeconds)
        message = String(localized: "Copied. The clipboard forgets it after \(model.settings.clipboardSeconds) seconds.")
    }
}

/// The current one-time code with the seconds it has left.
struct TOTPCodeView: View {
    let totp: TOTP

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = totp.code(at: context.date)
            let remaining = totp.secondsRemaining(at: context.date)
            HStack {
                Text(Self.grouped(code)).font(.title2.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                Spacer()
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(remaining) / CGFloat(totp.period))
                        .stroke(remaining <= 5 ? Color.orange : BrandColor.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(remaining)").font(.caption2.monospacedDigit())
                }
                .frame(width: 30, height: 30)
                .accessibilityLabel(Text("Seconds left: \(remaining)"))
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(code, expiresAfter: 30) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.count / 2
        return String(code.prefix(half)) + " " + String(code.suffix(half))
    }
}

// MARK: - Editor

struct VaultEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: VaultEntry?

    @State private var title: String
    @State private var username: String
    @State private var password: String
    @State private var uris: String
    @State private var totp: String
    @State private var notes: String
    @State private var showPassword = false
    @State private var error: String?

    init(entry: VaultEntry?, secret: VaultSecret? = nil) {
        self.entry = entry
        _title = State(initialValue: entry?.title ?? "")
        _username = State(initialValue: entry?.username ?? "")
        _password = State(initialValue: secret?.password ?? "")
        _uris = State(initialValue: entry?.uris.joined(separator: "\n") ?? "")
        _totp = State(initialValue: secret?.totp ?? "")
        _notes = State(initialValue: secret?.notes ?? "")
    }

    private var totpProblem: Bool {
        let t = totp.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && (try? TOTP(parsing: t)) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                    TextField("User name or email", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        Button(showPassword ? "Hide" : "Show", systemImage: showPassword ? "eye.slash" : "eye") {
                            showPassword.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    Button("Make a strong password", systemImage: "wand.and.stars") {
                        password = PasswordGenerator.make()
                        showPassword = true
                    }
                }
                Section {
                    TextField(text: $uris, prompt: Text(verbatim: "https://example.com"), axis: .vertical) {
                        Text("Websites")
                    }
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...5)
                } header: {
                    Text("Websites")
                } footer: {
                    Text("One per line. The login is offered for these sites and their subdomains.")
                }
                Section {
                    TextField("otpauth://… or the secret", text: $totp, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .lineLimit(1...3)
                } header: {
                    Text("One-time codes (optional)")
                } footer: {
                    if totpProblem {
                        Text("That isn't a valid secret for one-time codes.").foregroundStyle(.red)
                    } else {
                        Text("With a secret here, Annex sends the current code together with the password.")
                    }
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...8)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(entry == nil ? "New login" : "Edit login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || totpProblem
                                  || (username.isEmpty && password.isEmpty))
                }
            }
        }
    }

    private func save() {
        var item = entry ?? VaultEntry(title: "", username: "", uris: [], hasTOTP: false, hasNotes: false)
        item.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        item.uris = uris.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let secret = VaultSecret(password: password, totp: totp.trimmingCharacters(in: .whitespacesAndNewlines),
                                 notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try model.vault.save(item, secret: secret)
            dismiss()
        } catch Keychain.Failure.noPasscode {
            error = String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode). The vault needs it.")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
