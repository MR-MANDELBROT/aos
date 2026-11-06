import SwiftUI

/// The agent asks to sign in somewhere. The person sees who asks for what and which of their Bitwarden logins fit the
/// site (name and user name; the passwords stay in Bitwarden), approves one with Face ID, fills the fields from
/// another password app, or declines. aOS on the Mac then gets the approved login from Bitwarden and fills it. This
/// iPhone never talks to Bitwarden, and nothing it sends is stored or logged.
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SignInRequest

    enum Phase: Equatable { case choosing, sending, sent(fromBitwarden: Bool), declined, failed(String) }

    @State private var selection: BitwardenLogin.ID?
    @State private var phase: Phase = .choosing
    @State private var showOtherApp = false
    @State private var otherUser = ""
    @State private var otherPassword = ""
    @State private var code = ""

    private var result: SignInResult? { model.signInResults[request.id] }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = request.expires.map { $0 <= context.date } ?? false
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(now: context.date, expired: expired)
                        if let result {
                            outcome(result)
                        } else if expired {
                            notice(symbol: "clock.badge.xmark", text: "This request has expired.", tint: .secondary)
                        } else {
                            switch phase {
                            case .choosing, .failed:
                                if request.field == .code { codeChooser } else { chooser }
                            case .sending: ProgressView("Sending …").frame(maxWidth: .infinity)
                            case .sent(let fromBitwarden):
                                notice(symbol: "paperplane.fill",
                                       text: fromBitwarden ? "Approved. aOS on your Mac gets this login from Bitwarden and fills it in."
                                           : "Sent. aOS fills it into the workspace.", tint: BrandColor.mint)
                            case .declined:
                                notice(symbol: "hand.raised.fill", text: "Declined. The agent gets no sign-in.", tint: .secondary)
                            }
                            if case .failed(let message) = phase {
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
                            }
                        }
                    }
                    .padding()
                }
            }
            .aosBackground()
            .navigationTitle("Sign-in request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .onAppear {
            if selection == nil { selection = request.choices.first?.id }
            showOtherApp = request.choices.isEmpty
        }
        .onChange(of: request.logins) { _, _ in
            // The Mac sent the request again with Bitwarden's logins (it was unlocked meanwhile).
            if !request.choices.contains(where: { $0.id == selection }) { selection = request.choices.first?.id }
            if !request.choices.isEmpty { showOtherApp = false }
        }
        .onDisappear {
            otherUser = ""
            otherPassword = ""
            code = ""
        }
        .presentationDetents([.large])
    }

    // MARK: Parts

    private func header(now: Date, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                let agent = request.agent.isEmpty ? String(localized: "Your agent") : request.agent
                Text(request.field == .code ? "\(agent) asks for a one-time code" : "\(agent) asks to sign in")
            } icon: {
                Image(systemName: request.field == .code ? "number.square.fill" : "person.badge.key.fill")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(BrandColor.attention)

            Text(request.host)
                .font(.largeTitle.weight(.bold))
                .minimumScaleFactor(0.5)
                .lineLimit(2)
                .textSelection(.enabled)

            if !request.purpose.isEmpty {
                Text("\u{201E}\(request.purpose)\u{201C}")
                    .font(.title3)
                    .foregroundStyle(.primary.opacity(0.85))
            }

            if request.field != .code {
                Text(request.field == .username ? "The page asks for the user name." : "The page asks for the password.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let expires = request.expires, result == nil {
                let left = max(0, Int(expires.timeIntervalSince(now)))
                Label {
                    Text(expired ? String(localized: "Expired") : String(localized: "\(left / 60):\(String(format: "%02d", left % 60)) left"))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "timer")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(left < 30 ? .orange : .secondary)
            }
        }
        .padding(.top, 8)
    }

    /// What Bitwarden on the Mac can offer, when it offers nothing to choose.
    enum BitwardenNotice: Equatable {
        case locked, noLogin, unavailable
    }

    static func bitwardenNotice(for request: SignInRequest) -> BitwardenNotice? {
        switch request.bitwarden {
        case .locked: return .locked
        case .unavailable: return .unavailable
        case .unlocked: return request.choices.isEmpty ? .noLogin : nil
        case .off: return nil
        }
    }

    @ViewBuilder
    private func bitwardenNoticeCard(_ kind: BitwardenNotice) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                switch kind {
                case .locked:
                    Label("Bitwarden is locked on your Mac", systemImage: "lock.fill").font(.headline)
                    Text("Unlock it in aOS on the Mac. The logins for this website then appear here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                case .noLogin:
                    Label(request.field == .code ? "No login with a one-time code for \(request.host) in Bitwarden"
                          : "No login for \(request.host) in Bitwarden", systemImage: "key.horizontal")
                        .font(.headline)
                    Text(request.field == .code ? "Type the code below, or decline."
                         : "Use a login from another password app below, or decline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                case .unavailable:
                    Label("Bitwarden didn't answer on your Mac", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(request.field == .code ? "Type the code below, or decline."
                         : "Use a login from another password app below, or decline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let kind = Self.bitwardenNotice(for: request) { bitwardenNoticeCard(kind) }
            if !request.choices.isEmpty {
                Text("From Bitwarden").font(.headline)
                VStack(spacing: 0) {
                    ForEach(request.choices) { login in
                        Button {
                            selection = login.id
                        } label: {
                            HStack(spacing: 12) {
                                Monogram(text: login.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(login.username.isEmpty ? login.name : login.username).font(.body.weight(.medium))
                                    Text(login.name + (login.hasCode ? String(localized: " · with one-time code") : ""))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selection == login.id ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection == login.id ? BrandColor.indigo : .secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == login.id ? .isSelected : [])
                        if login.id != request.choices.last?.id { Divider().padding(.leading, 62) }
                    }
                }
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    Task { await approve(selection) }
                } label: {
                    Label("Approve with \(Biometrics.name)", systemImage: Biometrics.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(selection == nil || phase == .sending)
            }

            Button(role: .destructive) {
                Task { await decline() }
            } label: {
                Label("Decline", systemImage: "hand.raised").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            DisclosureGroup(isExpanded: $showOtherApp) {
                VStack(spacing: 12) {
                    TextField("User name or email", text: $otherUser)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $otherPassword)
                        .textContentType(.password)
                    Button {
                        Task { await sendOther() }
                    } label: {
                        Label("Send this sign-in", systemImage: "paperplane").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(otherPassword.isEmpty || phase == .sending)
                    Text("Your password app (1Password, Passwords, Bitwarden's app) fills these fields with its own Face ID. aOS sends them once and doesn't keep them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 10)
            } label: {
                Text("From another password app").font(.subheadline.weight(.medium))
            }
            .padding(14)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            FactRow(symbol: "eye.slash", text: "The agent never sees the password. aOS types it into the sign-in page in the workspace, only on this site.")
            if request.bitwarden == .unlocked || request.bitwarden == .locked {
                FactRow(symbol: "key.horizontal", text: "Your passwords stay in Bitwarden. aOS on your Mac gets only the login you approve, right before it fills it in.")
            }
        }
    }

    private func outcome(_ result: SignInResult) -> some View {
        switch result {
        case .filled: notice(symbol: "checkmark.circle.fill", text: "Signed in. aOS filled it into the workspace.", tint: .green)
        case .declined: notice(symbol: "hand.raised.fill", text: "Declined.", tint: .secondary)
        case .expired: notice(symbol: "clock.badge.xmark", text: "This request has expired.", tint: .secondary)
        case .failed, .unknown:
            notice(symbol: "exclamationmark.triangle.fill", text: "aOS couldn't fill it in. The agent can ask again.", tint: .orange)
        }
    }

    private func notice(symbol: String, text: LocalizedStringKey, tint: Color) -> some View {
        GlassCard {
            Label {
                Text(text).font(.headline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }

    // MARK: One-time code

    private var codeChooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let kind = Self.bitwardenNotice(for: request) { bitwardenNoticeCard(kind) }
            if !request.choices.isEmpty {
                Text("From Bitwarden").font(.headline)
                ForEach(request.choices) { login in
                    Button {
                        Task { await approve(login.id) }
                    } label: {
                        Label("Fill in the code from \(login.name)", systemImage: Biometrics.symbol).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(phase == .sending)
                }
                Text("aOS on your Mac gets the current code from Bitwarden and fills it in.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Text(request.choices.isEmpty ? "One-time code" : "Or type the code").font(.headline)
            TextField(text: $code, prompt: Text(verbatim: "123456")) { Text("One-time code") }
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .autocorrectionDisabled()
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .padding(14)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            let send = Button {
                Task { await sendCode() }
            } label: {
                Label("Send the code", systemImage: "paperplane").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || phase == .sending)
            if request.choices.isEmpty { send.buttonStyle(.glassProminent) } else { send.buttonStyle(.glass) }

            Button(role: .destructive) {
                Task { await decline() }
            } label: {
                Label("Decline", systemImage: "hand.raised").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            FactRow(symbol: "number.square", text: "The agent gets only this code. aOS types it into the field it chose, only on this site.")
        }
    }

    // MARK: Actions

    /// Approves a Bitwarden login after Face ID: the Mac gets it (or its current code) from Bitwarden.
    private func approve(_ login: BitwardenLogin.ID?) async {
        guard let login, let connection = model.connection else { return }
        do {
            try await model.confirmWithBiometrics(reason: request.field == .code
                ? String(localized: "Fill in the code for \(request.host)")
                : String(localized: "Approve the sign-in for \(request.host)"))
            phase = .sending
            try await connection.answerSignIn(request: request.id, host: request.host, login: login)
            phase = .sent(fromBitwarden: true)
            closeSoon()
        } catch Biometrics.Failure.cancelled {
            phase = .choosing
        } catch Biometrics.Failure.unavailable {
            phase = .failed(String(localized: "Set a passcode for this iPhone first (Settings > Face ID & Passcode). Approving a sign-in needs Face ID or the passcode."))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func sendCode() async {
        guard let connection = model.connection else { return }
        let value = code.trimmingCharacters(in: .whitespaces)
        phase = .sending
        do {
            try await connection.answerSignInCode(request: request.id, host: request.host, code: value)
            code = ""
            phase = .sent(fromBitwarden: false)
            closeSoon()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func sendOther() async {
        guard let connection = model.connection else { return }
        phase = .sending
        do {
            try await connection.answerSignIn(request: request.id, host: request.host, username: otherUser, password: otherPassword, totp: nil)
            otherPassword = ""
            phase = .sent(fromBitwarden: false)
            closeSoon()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func decline() async {
        phase = .sending
        do {
            try await model.connection?.declineSignIn(request: request.id, host: request.host)
            phase = .declined
            closeSoon()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The Mac reports the result with `signin.closed`; if that takes long, the sheet closes anyway.
    private func closeSoon() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if model.presentedSignIn?.id == request.id { dismiss() }
        }
    }
}
