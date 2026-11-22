import ScreenClient
import SwiftUI

/// Settings > Screen: Open Screen Sharing's settings (general, keyboard, control), with aOS's one setting for both
/// screens on top: the iPhone's size, and Open Screen Sharing's resolution. What a session remembers per screen
/// (quality, clipboard, pointer lock) is chosen in the session's menu, as in Open Screen Sharing.
struct ScreenSettingsPage: View {
    @Environment(AppModel.self) private var model
    /// Whether the Mac's login is saved (read without Face ID, as the page appears).
    @State private var savedLogin = false

    var body: some View {
        @Bindable var settings = model.settings
        ScreenClientSettings {
            if let mac = model.activeMac {
                Section {
                    NavigationLink {
                        MacLoginPage(mac: mac)
                    } label: {
                        LabeledContent {
                            Text(savedLogin ? String(localized: "Saved") : String(localized: "Not saved"))
                        } label: {
                            Label("Mac Login", systemImage: "person.badge.key")
                        }
                    }
                } footer: {
                    Text("The name and password of your Mac account, for its screen sharing and its lock screen.")
                }
            }
            Section {
                Toggle("Screens in the iPhone's size", isOn: $settings.screenMatchesPhone)
                Picker("Resolution", selection: $settings.screenResolution) {
                    ForEach(ScreenClient.resolutionScales, id: \.self) { scale in
                        Text(ScreenClient.resolutionTitle(scale)).tag(scale)
                    }
                }
                .disabled(!settings.screenMatchesPhone)
            } header: {
                Text("Display")
            } footer: {
                Text("Both screens take the iPhone's shape and turn with it: aOS resizes the workspace's display, your Mac gets a virtual display in Open Screen Sharing's high performance mode, directly in the same Wi-Fi or with the Tailscale app's VPN. Through SSH alone your Mac keeps its own size. More resolution gives more room and less sharpness.")
            }
        }
        .onAppear { savedLogin = model.activeMac.map(SecretStore.hasScreenLogin(for:)) ?? false }
    }
}

/// Settings > Screen > Mac Login: the Mac account's name and password ahead of time (the same keychain item the
/// screen's login form saves, behind Face ID), and whether aOS unlocks the Mac with it when its screen is locked at
/// connecting. Whether one is saved is read without Face ID (the item's attributes only).
struct MacLoginPage: View {
    @Environment(AppModel.self) private var model
    let mac: PairedMac
    @State private var saved = false
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Login of \(mac.name)") {
                    Text(saved ? String(localized: "Saved") : String(localized: "Not saved"))
                }
                Button(saved ? "Change Login" : "Save Login", systemImage: "person.crop.square") { editing = true }
                if saved {
                    Button("Delete Login", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            } footer: {
                Text("The name and password of your Mac account, kept on this iPhone behind \(Biometrics.name), which every use asks for. They go only to your Mac's screen sharing.")
            }
            Section {
                Toggle("Unlock the Mac when connecting", isOn: $settings.screenUnlocksMac)
                    .disabled(!saved)
                if saved, settings.unlockFailed(for: mac.id) {
                    Label("Last time your Mac stayed locked after the saved password. aOS doesn't type it into the lock screen again until you save the login anew.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("If your Mac's screen is locked when you connect, aOS types the saved password into the lock screen and presses Return: once per connect, and only when the Mac reports its screen locked for this account and its password field in front. In your Mac's screen, Type Password (the key in the toolbar) types it into a password field after \(Biometrics.name), without Return.")
            }
        }
        .navigationTitle("Mac Login")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { saved = SecretStore.hasScreenLogin(for: mac) }
        .sheet(isPresented: $editing) {
            NavigationStack {
                MacScreenLoginForm(mac: mac, purpose: .save) { _ in
                    editing = false
                    saved = SecretStore.hasScreenLogin(for: mac)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = false } }
                }
            }
            .presentationSizing(.form)
        }
        .confirmationDialog("Delete the login of \(mac.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Login", role: .destructive) {
                SecretStore.deleteScreenLogin(for: mac)
                saved = false
            }
        } message: {
            Text("The Mac's screen then asks for it again when you connect.")
        }
    }
}

/// Settings > Acknowledgements: where the screen comes from, its license and its source.
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Text("The screen of the workspace and of the Mac is based on Open Screen Sharing by nekohasekai, used under the GNU General Public License, version 3. aOS changed it for its own use: the screens are reached through the connection to your Mac (your Mac in the iPhone's size also directly), and aOS's sign-in replaces the app's own.")
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: ScreenClient.sourceCode) {
                    Label("Source code of Open Screen Sharing", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicenseText(title: "License notice", text: ScreenClient.licenseNotice)
                } label: {
                    Label("License notice", systemImage: "doc.text")
                }
                NavigationLink {
                    LicenseText(title: "GNU General Public License", text: ScreenClient.licenseText)
                } label: {
                    Label("GNU General Public License, version 3", systemImage: "doc.plaintext")
                }
            } header: {
                Text("Open Screen Sharing")
            } footer: {
                Text("aOS is not made by the author of Open Screen Sharing and is not associated with it.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseText: View {
    let title: LocalizedStringKey
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
