import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section {
                    ForEach(model.macs) { mac in
                        NavigationLink {
                            MacDetailView(mac: mac)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").foregroundStyle(BrandColor.indigo).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                    Text("\(mac.user)@\(mac.lastHost ?? mac.hosts.first ?? "")")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                if mac.id == model.activeMac?.id, model.macs.count > 1 {
                                    Spacer()
                                    Text("In use").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("Pair with a Mac", systemImage: "qrcode.viewfinder") {
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            model.isPairingPresented = true
                        }
                    }
                } header: {
                    Text("Paired Macs")
                }

                Section {
                    Toggle(isOn: Binding(get: { settings.requireUnlock }, set: { newValue in
                        Task { _ = await model.lock.setRequired(newValue) }
                    })) {
                        Label("\(Biometrics.name) to open aOS", systemImage: Biometrics.symbol)
                    }
                    if settings.requireUnlock {
                        Picker("Lock again", selection: $settings.autoLockMinutes) {
                            ForEach(AppSettings.autoLockChoices, id: \.self) { minutes in
                                Text(Self.lockText(minutes)).tag(minutes)
                            }
                        }
                    }
                    Picker("Clear copied passwords", selection: $settings.clipboardSeconds) {
                        ForEach(AppSettings.clipboardChoices, id: \.self) { seconds in
                            Text("after \(seconds) s").tag(seconds)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Passwords in the vault always need Face ID, whether or not the app itself is locked.")
                }

                Section("Screen") {
                    Picker("Picture rate", selection: $settings.frameRate) {
                        Text("Smooth").tag(AppSettings.FrameRate.smooth)
                        Text("Balanced").tag(AppSettings.FrameRate.balanced)
                        Text("Saves data").tag(AppSettings.FrameRate.saver)
                    }
                    Picker("One finger", selection: $settings.inputMode) {
                        Text("Moves the pointer (trackpad)").tag(AppSettings.InputMode.trackpad)
                        Text("Touches directly").tag(AppSettings.InputMode.direct)
                    }
                }

                Section {
                    NavigationLink {
                        DeviceKeyView()
                    } label: {
                        Label("SSH key of this iPhone", systemImage: "key")
                    }
                } header: {
                    Text("This iPhone")
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("What is where", systemImage: "info.circle")
                    }
                    LabeledContent("Version", value: MacConnection.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    static func lockText(_ minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "Right away")
        case 60: String(localized: "After 1 hour")
        default: String(localized: "After \(minutes) min")
        }
    }
}

struct MacDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mac: PairedMac
    @State private var confirmUnpair = false
    @State private var hasScreenLogin = false

    var body: some View {
        Form {
            Section {
                LabeledContent("User", value: mac.user)
                LabeledContent("Paired", value: mac.pairedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Addresses") {
                ForEach(mac.hosts, id: \.self) { host in
                    HStack {
                        Text(host).font(.callout)
                        if host == mac.lastHost {
                            Spacer()
                            Text("worked last").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                KeyText(text: mac.hostKeyFingerprint)
            } header: {
                Text("The Mac's SSH key")
            } footer: {
                Text("Pinned at pairing. If the Mac answers with another key, the app stops and tells you.")
            }
            if hasScreenLogin {
                Section {
                    Button("Forget the login for the Mac's screen", systemImage: "person.crop.circle.badge.minus") {
                        SecretStore.deleteScreenLogin(for: mac)
                        hasScreenLogin = false
                    }
                } footer: {
                    Text("The Mac account name and password for screen sharing, kept on this iPhone behind Face ID.")
                }
            }
            if model.macs.count > 1, model.activeMac?.id != mac.id {
                Section {
                    Button("Connect to this Mac", systemImage: "arrow.left.arrow.right") { model.makeActive(mac) }
                }
            }
            Section {
                Button("Unpair", systemImage: "link.badge.minus", role: .destructive) { confirmUnpair = true }
            } footer: {
                Text("This iPhone forgets the Mac. To remove the iPhone's key from the Mac too, open aOS on the Mac and remove it from the paired devices.")
            }
        }
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasScreenLogin = SecretStore.hasScreenLogin(for: mac) }
        .confirmationDialog("Unpair \(mac.name)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                model.unpair(mac)
                dismiss()
            }
        } message: {
            Text("Sign-in requests and help requests from this Mac no longer reach this iPhone.")
        }
    }
}

struct DeviceKeyView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Form {
            if let key = model.deviceKey {
                Section {
                    KeyText(text: key.publicKey, lineLength: 36)
                    Button(copied ? "Copied" : "Copy the public key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        Clipboard.copyPlain(key.publicKey + " aos-iphone")
                        copied = true
                    }
                    ShareLink(item: key.publicKey + " aos-iphone") {
                        Label("Share the public key", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Public key")
                } footer: {
                    Text("To log in to another computer with this iPhone's key, add this line to ~/.ssh/authorized_keys there. The public key isn't secret.")
                }
                Section {
                    LabeledContent("Fingerprint") {
                        KeyText(text: key.fingerprint)
                    }
                    LabeledContent("Kept in") {
                        Text(key.storage == .secureEnclave ? String(localized: "Secure Enclave") : String(localized: "Keychain"))
                    }
                } footer: {
                    Text(key.storage == .secureEnclave
                         ? "The private key was made in this iPhone's Secure Enclave and can't leave it."
                         : "The private key is in this device's keychain and is never synced.")
                }
            } else {
                Section {
                    Text(model.deviceKeyError ?? String(localized: "The key isn't available."))
                    Button("Try again") { model.loadDeviceKey() }
                }
            }
        }
        .navigationTitle("SSH key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What is where, in plain words.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    AppIconImage(size: 60)
                    VStack(alignment: .leading) {
                        Text("aOS").font(.title2.weight(.bold))
                        Text("A Mac of its own for your coding agent.").foregroundStyle(.secondary)
                    }
                }
                AboutSection(title: "Your passwords", symbol: "key.horizontal", lines: [
                    "They stay on this iPhone, in its keychain, only on this device. They aren't synced to iCloud and aren't part of backups.",
                    "Every look at a password and every approval needs Face ID or your passcode.",
                    "Approved sign-ins go once, encrypted over SSH, to aOS on your Mac, which types them into the workspace. Neither the app nor the Mac keeps them.",
                ])
                AboutSection(title: "Your agent", symbol: "sparkles", lines: [
                    "It asks for a sign-in by naming the site and why. You see the request and decide.",
                    "It never gets the password; it only learns whether the sign-in worked.",
                ])
                AboutSection(title: "The connection", symbol: "lock", lines: [
                    "The iPhone reaches your Mac over SSH (the Mac's Remote Login), with a key made on this iPhone that never leaves it. The Mac's key is checked every time.",
                    "There is no server of ours in between. Outside your home network you need Tailscale or another VPN to reach the Mac.",
                ])
                AboutSection(title: "The screen", symbol: "display", lines: [
                    "The pictures of your Mac and the workspace travel through the same SSH connection and aren't stored.",
                    "The Mac account name and password for its screen stay on this iPhone behind Face ID and only go to the Mac's screen sharing.",
                ])
            }
            .padding()
        }
        .aosBackground()
        .navigationTitle("What is where")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutSection: View {
    let title: LocalizedStringKey
    let symbol: String
    let lines: [LocalizedStringKey]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.headline).foregroundStyle(BrandColor.indigo)
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index]).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                AppIconImage(size: 84)
                Text("aOS is locked").font(.title2.weight(.semibold))
                if let message = model.lock.failureMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.lock.unlock() }
                } label: {
                    Label("Unlock with \(Biometrics.name)", systemImage: Biometrics.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .task { if !model.isDemo { await model.lock.unlock() } }
    }
}
