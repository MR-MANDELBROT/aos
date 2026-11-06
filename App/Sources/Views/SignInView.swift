import AOSKit
import LocalAuthentication
import SwiftUI

/// "<Agent> wants to sign in on <website>": the user picks one of their Bitwarden logins for the site (aOS gets it
/// from Bitwarden), or fills the fields from another password app (AutoFill works in them), or approves on their
/// iPhone. aOS types it into the workspace; the agent never sees it.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// The chosen Bitwarden login (its id).
    @State private var selection: String?
    @State private var showOther = false
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var masterPassword = ""
    @FocusState private var focus: Field?

    enum Field { case username, password, code, master }

    var body: some View {
        let _ = model.bitwardenTick
        VStack(spacing: 16) {
            if let e = model.signIns.first {
                HeroSymbol(systemName: e.field == "code" ? "number" : "person.badge.key.fill")
                VStack(spacing: 6) {
                    Text(e.field == "code" ? "\(e.agent ?? String(localized: "Your agent")) asks for a one-time code"
                         : "\(e.agent ?? String(localized: "Your agent")) wants to sign in")
                        .font(.title3.bold()).multilineTextAlignment(.center)
                    Text(e.host ?? "").font(.title2.weight(.semibold)).foregroundStyle(BrandColor.indigo)
                        .textSelection(.enabled)
                    if let purpose = e.purpose {
                        Text(purpose).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                bitwardenPart(e)
                otherPart(e)
                Label("\(Brand.name) types this into the workspace and submits it. Your agent never sees it.",
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let expires = e.expires {
                    Text("Waiting until \(expires.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    Button { decline(e) } label: { Text("Don't Sign In").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    // No Return shortcut: a Bitwarden login is approved with Touch ID or the Mac's password.
                    Button { approve(e) } label: { Text(e.field == "code" ? "Fill In" : "Sign In").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                        .disabled(!ready(e))
                }
                .controlSize(.large)
            } else {
                AppIconImage(size: 48)
                Text("No sign-in waiting.").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 420)
        .onAppear { prepare(model.signIns.first) }
        .onChange(of: model.signIns.first?.request) { _, _ in clear(); prepare(model.signIns.first) }
        .onChange(of: model.signIns.first?.logins) { _, _ in
            // The request came again with Bitwarden's logins (for example after unlocking): pick the first one.
            if selection == nil { prepare(model.signIns.first) }
        }
    }

    // MARK: Bitwarden

    /// The logins that can answer this request: all matching ones, for a code those with an authenticator key.
    func choices(_ e: CompanionEvent) -> [CompanionLogin] {
        let logins = e.logins ?? []
        return e.field == "code" ? logins.filter(\.totp) : logins
    }

    @ViewBuilder
    func bitwardenPart(_ e: CompanionEvent) -> some View {
        switch e.bitwarden {
        case "unlocked":
            let logins = choices(e)
            if logins.isEmpty {
                GlassCard {
                    Label(e.field == "code" ? "No login with a one-time code for this website in Bitwarden."
                          : "No login for this website in Bitwarden.", systemImage: "key.horizontal")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.field == "code" ? "Code from Bitwarden" : "From Bitwarden").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(logins) { login in
                            loginRow(login, code: e.field == "code")
                            if login.id != logins.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        case "locked":
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bitwarden is locked", systemImage: "lock.fill").font(.headline)
                    Text("Unlock it to see your logins for this website.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        SecureField("Master password", text: $masterPassword)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .master)
                            .onSubmit(unlock)
                        Button("Unlock", action: unlock)
                            .buttonStyle(.glass)
                            .disabled(masterPassword.isEmpty || model.bitwarden.phase == .unlocking)
                    }
                    if model.bitwarden.phase == .unlocking {
                        ProgressView().controlSize(.small)
                    } else if model.bitwarden.phase == .locked, let problem = model.bitwarden.problem {
                        Text(model.bitwardenProblemText(problem)).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        case "unavailable":
            GlassCard {
                Label("Bitwarden didn't answer. Fill in from another password app, or ask your agent to try again.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    func loginRow(_ login: CompanionLogin, code: Bool) -> some View {
        Button {
            selection = login.id
            username = ""; password = ""; self.code = ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection == login.id ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection == login.id ? BrandColor.indigo : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(login.username.isEmpty ? login.name : login.username).fontWeight(.medium)
                    Text(code ? String(localized: "\(login.name) · the current code") : login.name
                         + (login.totp ? String(localized: " · with one-time code") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == login.id ? .isSelected : [])
    }

    func unlock() {
        guard !masterPassword.isEmpty else { return }
        model.unlockBitwarden(password: masterPassword)
        masterPassword = ""
    }

    // MARK: Another password app, or a code typed by hand

    @ViewBuilder
    func otherPart(_ e: CompanionEvent) -> some View {
        let fields = VStack(alignment: .leading, spacing: 10) {
            switch e.field {
            case "code":
                TextField("One-time code", text: $code)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
            default:
                TextField("User name or email", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: username + password + code) { _, typed in if !typed.isEmpty { selection = nil } }

        if choices(e).isEmpty {
            GlassCard { fields }
        } else {
            DisclosureGroup(isExpanded: $showOther) {
                fields.padding(.top, 6)
            } label: {
                Text(e.field == "code" ? "Type the code yourself" : "From another password app").font(.callout)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Answering

    func prepare(_ e: CompanionEvent?) {
        guard let e else { return }
        selection = choices(e).first?.id
        if selection == nil { focus = e.field == "code" ? .code : (e.bitwarden == "locked" ? .master : .username) }
    }

    func ready(_ e: CompanionEvent) -> Bool {
        if let selection, choices(e).contains(where: { $0.id == selection }) { return true }
        switch e.field {
        case "code": return !code.isEmpty
        case "password": return !password.isEmpty
        default: return !username.isEmpty
        }
    }

    func approve(_ e: CompanionEvent) {
        if let selection, let choice = choices(e).first(where: { $0.id == selection }) {
            // A login from Bitwarden: only the person at this Mac can approve it (Touch ID or the Mac's password,
            // in macOS's own dialog), not a click or a key press another program sends.
            let site = e.host ?? ""
            Task {
                guard await MacApproval.confirm(String(localized: "sign in as \(choice.username.isEmpty ? choice.name : choice.username) on \(site)")) else { return }
                model.answerSignIn(e, login: selection)
                clear()
                if model.signIns.count <= 1 { dismissWindow(id: WindowID.signIn) }
            }
            return
        } else {
            model.answerSignIn(e, username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password,
                               code: code.isEmpty ? nil : code)
        }
        clear()
        if model.signIns.count <= 1 { dismissWindow(id: WindowID.signIn) }
    }

    func decline(_ e: CompanionEvent) {
        model.declineSignIn(e)
        clear()
        if model.signIns.count <= 1 { dismissWindow(id: WindowID.signIn) }
    }

    func clear() {
        username = ""; password = ""; code = ""; masterPassword = ""; selection = nil; showOther = false
    }
}

/// The person at this Mac confirms with Touch ID or the Mac's password (macOS's own dialog; another program can't
/// answer it).
enum MacApproval {
    @MainActor
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { return false }
    }
}
