import AOSKit
import SwiftUI

/// Settings > Bitwarden: sign in to the user's own Bitwarden account (email, master password once, the codes
/// Bitwarden asks for), the signed-in account, lock and unlock, sign out, when it locks again, and the tool.
struct BitwardenSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var server: ServerChoice = .us
    @State private var serverAddress = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    enum ServerChoice: Hashable { case us, eu, selfHosted }
    enum Field: Hashable { case email, password, code }

    var body: some View {
        let _ = model.bitwardenTick
        let vault = model.bitwarden
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    HeroSymbol(systemName: "key.horizontal.fill", tint: BrandColor.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bitwarden").font(.headline)
                        Text("\(Brand.name) asks Bitwarden for exactly the login you approve; your passwords stay in Bitwarden.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("When your agent needs to sign in, you see which of your Bitwarden logins fit the website and approve one on your iPhone or here. \(Brand.name) then gets that one login from Bitwarden and types it into the workspace. Your agent never sees it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // What went wrong last, above the fields where the user tries again
            if let problem = vault.problem {
                Section {
                    Label(model.bitwardenProblemText(problem), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            switch vault.phase {
            case .unknown:
                Section { HStack { ProgressView().controlSize(.small); Text("Checking …").foregroundStyle(.secondary) } }
            case .installing:
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Downloading Bitwarden's command line tool from Bitwarden and checking its signature …")
                            .foregroundStyle(.secondary)
                    }
                }
            case .noTool, .signedOut:
                signInSection(firstTime: vault.phase == .noTool)
            case .signingIn(let step):
                stepSection(step)
            case .locked, .unlocking:
                lockedSection
            case .unlocked:
                unlockedSection
            }

            Section {
                Picker("Lock again", selection: binding(\.bitwardenLockHours)) {
                    ForEach(AgentSettings.bitwardenLockChoices, id: \.self) { hours in
                        Text(hours == 1 ? String(localized: "After 1 hour") : String(localized: "After \(hours) hours")).tag(hours)
                    }
                }
                Text("Counted from unlocking. Bitwarden also locks when this Mac goes to sleep or restarts. While it is locked, sign-in requests show no Bitwarden logins until you unlock it here or in the sign-in window.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Locking")
            }

            toolSection
        }
        .formStyle(.grouped)
        .onAppear {
            if email.isEmpty { email = vault.email ?? "" }
            switch vault.server {
            case .us: server = .us
            case .eu: server = .eu
            case .selfHosted(let url): server = .selfHosted; serverAddress = url
            }
            if !AppModel.isPreview { Task { await vault.refresh() } }
        }
        .onDisappear { password = ""; code = "" }
    }

    // MARK: Signed out

    @ViewBuilder
    func signInSection(firstTime: Bool) -> some View {
        Section {
            Picker("Server", selection: $server) {
                Text(verbatim: "bitwarden.com").tag(ServerChoice.us)
                Text(verbatim: "bitwarden.eu").tag(ServerChoice.eu)
                Text("Self-hosted").tag(ServerChoice.selfHosted)
            }
            if server == .selfHosted {
                TextField("Server address", text: $serverAddress, prompt: Text(verbatim: "https://vault.example.com"))
            }
            TextField("Email", text: $email)
                .textContentType(.username)
                .focused($focus, equals: .email)
            SecureField("Master password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(signIn)
            HStack {
                Spacer()
                Button("Sign In", action: signIn)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSignIn)
            }
        } header: {
            Text("Sign in to Bitwarden")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your master password goes to Bitwarden's command line tool once and isn't stored. If Bitwarden asks for a code (two-step login, or because \(Brand.name) is a new device for your account), you enter it here.")
                if firstTime {
                    Text("The first time, \(Brand.name) downloads Bitwarden's official command line tool from Bitwarden (about 45 MB) and checks that Bitwarden signed it.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    var chosenServer: BitwardenServer? {
        switch server {
        case .us: return .us
        case .eu: return .eu
        case .selfHosted: return BitwardenServer.selfHosted(address: serverAddress)
        }
    }

    var canSignIn: Bool {
        email.contains("@") && !password.isEmpty && chosenServer != nil
    }

    func signIn() {
        guard canSignIn, let server = chosenServer else { return }
        model.signInToBitwarden(email: email, password: password, server: server)
        password = ""
    }

    // MARK: Signing in

    @ViewBuilder
    func stepSection(_ step: BitwardenLoginConversation.Step) -> some View {
        Section {
            switch step {
            case .working:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Talking to Bitwarden …").foregroundStyle(.secondary)
                }
            case .chooseMethod(let methods):
                Text("Your account has several ways to confirm it's you. Which one do you want to use?")
                ForEach(methods.indices, id: \.self) { index in
                    Button {
                        model.bitwarden.choose(method: index)
                    } label: {
                        Label(AppModel.twoStepMethodName(methods[index]), systemImage: Self.symbol(for: methods[index]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                }
            case .twoStepCode(let method):
                Text(Self.codeHint(method))
                codeField(prompt: String(localized: "Code"))
            case .newDeviceCode:
                Text("Bitwarden sent a verification code to \(email.isEmpty ? String(localized: "your email address") : email). It asks for it because \(Brand.name) signs in from a new device.")
                codeField(prompt: String(localized: "Verification code"))
            case .question(let text, let secret):
                Text("Bitwarden asks: \(text)")
                codeField(prompt: text, secret: secret)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.bitwarden.cancelSignIn() }
                    .buttonStyle(.glass)
            }
        } header: {
            Text("Signing in to Bitwarden")
        }
    }

    @ViewBuilder
    func codeField(prompt: String, secret: Bool = false) -> some View {
        HStack {
            Group {
                if secret {
                    SecureField(prompt, text: $code)
                } else {
                    TextField(prompt, text: $code).textContentType(.oneTimeCode)
                }
            }
            .focused($focus, equals: .code)
            .onSubmit(sendCode)
            .onAppear { focus = .code }
            Button("Continue", action: sendCode)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func sendCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.bitwarden.answer(value)
        code = ""
    }

    static func codeHint(_ method: String?) -> String {
        switch method {
        case "Email"?: return String(localized: "Bitwarden emailed you a code. Enter it here.")
        case "Authenticator App"?: return String(localized: "Enter the code from your authenticator app.")
        case "Yubico OTP Security Key"?: return String(localized: "Click into the field and touch your YubiKey.")
        default: return String(localized: "Enter your two-step login code (from your authenticator app, the email Bitwarden sent, or your YubiKey).")
        }
    }

    static func symbol(for method: String) -> String {
        switch method {
        case "Email": return "envelope"
        case "Yubico OTP Security Key": return "key.fill"
        default: return "lock.rotation"
        }
    }

    // MARK: Signed in

    var accountRow: some View {
        LabeledContent("Account") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.bitwarden.email ?? "").textSelection(.enabled)
                Text(model.bitwarden.server.name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var lockedSection: some View {
        Section {
            accountRow
            LabeledContent("Status") {
                Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            HStack {
                SecureField("Master password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.bitwarden.phase == .unlocking)
            }
            HStack {
                Spacer()
                Button("Sign Out", role: .destructive) { model.signOutOfBitwarden() }.buttonStyle(.glass)
            }
        } header: {
            Text("Signed in")
        } footer: {
            Text("Unlock Bitwarden so sign-in requests can offer your logins. The master password goes to Bitwarden's tool and isn't stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func unlock() {
        guard !password.isEmpty else { return }
        model.unlockBitwarden(password: password)
        password = ""
    }

    @ViewBuilder
    var unlockedSection: some View {
        Section {
            accountRow
            LabeledContent("Status") {
                Label(model.bitwardenStateText, systemImage: "lock.open.fill").foregroundStyle(.green)
            }
            LabeledContent("Last sync") {
                HStack(spacing: 8) {
                    if let sync = model.bitwarden.lastSync {
                        Text(sync.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                    }
                    Button("Sync Now") { Task { await model.bitwarden.sync() } }.buttonStyle(.glass).controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Lock Now") { model.lockBitwarden() }.buttonStyle(.glass)
                Button("Sign Out", role: .destructive) { model.signOutOfBitwarden() }.buttonStyle(.glass)
            }
        } header: {
            Text("Signed in")
        }
    }

    // MARK: The tool

    @ViewBuilder
    var toolSection: some View {
        if let tool = model.bitwarden.tool {
            Section {
                LabeledContent("Command line tool") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.bitwarden.toolVersion.map { "Bitwarden CLI \($0)" } ?? "Bitwarden CLI")
                        Text(tool.downloaded ? String(localized: "Downloaded from Bitwarden, signed by Bitwarden")
                             : String(localized: "Yours (\(tool.path)), signed by Bitwarden"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tool.downloaded {
                    HStack {
                        Spacer()
                        Button("Update") { Task { await model.bitwarden.updateTool() } }
                            .buttonStyle(.glass)
                            .disabled(model.bitwarden.isSigningIn || model.bitwarden.phase == .installing)
                    }
                }
            } footer: {
                Text("\(Brand.name) runs Bitwarden's official command line tool as a program of its own and checks Bitwarden's signature before using it. It isn't part of \(Brand.name).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func binding<T>(_ path: WritableKeyPath<AgentSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { v in model.update { $0[keyPath: path] = v } })
    }
}
