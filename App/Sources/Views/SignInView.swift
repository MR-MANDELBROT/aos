import AnnexKit
import SwiftUI

/// "<Agent> wants to sign in on <website>": the user fills the sign-in here (AutoFill from their password manager
/// works in these fields) or approves on their iPhone. Annex types it into the workspace; the agent never sees it.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    enum Field { case username, password, code }

    var body: some View {
        VStack(spacing: 16) {
            if let e = model.signIns.first {
                HeroSymbol(systemName: e.field == "code" ? "number" : "person.badge.key.fill")
                VStack(spacing: 6) {
                    Text("\(e.agent ?? String(localized: "Your agent")) wants to sign in")
                        .font(.title3.bold()).multilineTextAlignment(.center)
                    Text(e.host ?? "").font(.title2.weight(.semibold)).foregroundStyle(BrandColor.indigo)
                        .textSelection(.enabled)
                    if let purpose = e.purpose {
                        Text(purpose).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
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
                }
                Label("\(Brand.name) types this into the workspace and submits it. Your agent never sees it.",
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                if let expires = e.expires {
                    Text("Waiting until \(expires.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    Button { decline(e) } label: { Text("Don't Sign In").frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button { approve(e) } label: { Text("Sign In").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
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
        .frame(width: 400)
        .onAppear { focus = model.signIns.first?.field == "code" ? .code : .username }
        .onChange(of: model.signIns.first?.request) { _, _ in clear() }
    }

    func ready(_ e: CompanionEvent) -> Bool {
        switch e.field {
        case "code": return !code.isEmpty
        case "password": return !password.isEmpty
        default: return !username.isEmpty
        }
    }

    func approve(_ e: CompanionEvent) {
        model.answerSignIn(e, username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password,
                           code: code.isEmpty ? nil : code)
        clear()
        if model.signIns.count <= 1 { dismissWindow(id: WindowID.signIn) }
    }

    func decline(_ e: CompanionEvent) {
        model.declineSignIn(e)
        clear()
        if model.signIns.count <= 1 { dismissWindow(id: WindowID.signIn) }
    }

    func clear() {
        username = ""; password = ""; code = ""
    }
}
