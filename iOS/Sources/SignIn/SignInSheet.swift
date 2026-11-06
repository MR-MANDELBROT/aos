import SwiftUI

/// The agent asks to sign in somewhere. The person sees who asks for what, picks a login and approves with Face ID,
/// or declines. What is sent is never stored or logged.
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SignInRequest

    enum Phase: Equatable { case choosing, sending, sent, declined, failed(String) }

    @State private var selection: VaultEntry.ID?
    @State private var phase: Phase = .choosing
    @State private var showOtherApp = false
    @State private var otherUser = ""
    @State private var otherPassword = ""

    private var matches: [VaultEntry] { model.vault.logins(for: request.host) }
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
                            case .choosing, .failed: chooser
                            case .sending: ProgressView("Sending …").frame(maxWidth: .infinity)
                            case .sent:
                                notice(symbol: "paperplane.fill", text: "Sent. Annex fills it into the workspace.", tint: BrandColor.mint)
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
            .annexBackground()
            .navigationTitle("Sign-in request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .onAppear { if selection == nil { selection = matches.first?.id } }
        .onDisappear {
            otherUser = ""
            otherPassword = ""
        }
        .presentationDetents([.large])
    }

    // MARK: Parts

    private func header(now: Date, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("\(request.agent.isEmpty ? String(localized: "Your agent") : request.agent) asks to sign in")
            } icon: {
                Image(systemName: "person.badge.key.fill")
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

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            if matches.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No login for \(request.host) in your vault", systemImage: "key.horizontal")
                            .font(.headline)
                        Text("Use a login from another password app below, or decline.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("From your vault").font(.headline)
                VStack(spacing: 0) {
                    ForEach(matches) { entry in
                        Button {
                            selection = entry.id
                        } label: {
                            HStack(spacing: 12) {
                                Monogram(text: entry.title)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.username.isEmpty ? entry.title : entry.username).font(.body.weight(.medium))
                                    Text(entry.title + (entry.hasTOTP ? String(localized: " · with one-time code") : ""))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selection == entry.id ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selection == entry.id ? BrandColor.indigo : .secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == entry.id ? .isSelected : [])
                        if entry.id != matches.last?.id { Divider().padding(.leading, 62) }
                    }
                }
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    Task { await approve() }
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
                    Text("Your password app (Bitwarden, 1Password, Passwords) fills these fields with its own Face ID. Annex sends them once and doesn't keep them.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 10)
            } label: {
                Text("From another password app").font(.subheadline.weight(.medium))
            }
            .padding(14)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            FactRow(symbol: "eye.slash", text: "The agent never sees the password. Annex types it into the sign-in page in the workspace, only on this site.")
        }
    }

    private func outcome(_ result: SignInResult) -> some View {
        switch result {
        case .filled: notice(symbol: "checkmark.circle.fill", text: "Signed in. Annex filled it into the workspace.", tint: .green)
        case .declined: notice(symbol: "hand.raised.fill", text: "Declined.", tint: .secondary)
        case .expired: notice(symbol: "clock.badge.xmark", text: "This request has expired.", tint: .secondary)
        case .failed, .unknown:
            notice(symbol: "exclamationmark.triangle.fill", text: "Annex couldn't fill it in. The agent can ask again.", tint: .orange)
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

    // MARK: Actions

    private func approve() async {
        guard let id = selection, let entry = model.vault.entry(id: id), let connection = model.connection else { return }
        do {
            let context = try await model.vault.authenticate(reason: String(localized: "Send the sign-in for \(request.host)"))
            defer { context?.invalidate() }
            phase = .sending
            let secret = try model.vault.secret(for: entry, context: context)
            let code = try? TOTP(parsing: secret.totp).code()
            try await connection.answerSignIn(request: request.id, username: entry.username, password: secret.password,
                                              totp: secret.totp.isEmpty ? nil : code)
            phase = .sent
            closeSoon()
        } catch Biometrics.Failure.cancelled {
            phase = .choosing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func sendOther() async {
        guard let connection = model.connection else { return }
        phase = .sending
        do {
            try await connection.answerSignIn(request: request.id, username: otherUser, password: otherPassword, totp: nil)
            otherPassword = ""
            phase = .sent
            closeSoon()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func decline() async {
        phase = .sending
        do {
            try await model.connection?.declineSignIn(request: request.id)
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
