import ScreenClient
import SwiftUI

/// Settings > Screen: Open Screen Sharing's settings (general, keyboard, control), with aOS's one setting for both
/// screens on top: the iPhone's size, and Open Screen Sharing's resolution. What a session remembers per screen
/// (quality, clipboard, pointer lock) is chosen in the session's menu, as in Open Screen Sharing.
struct ScreenSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ScreenClientSettings {
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
                Text("The workspace and your Mac take the iPhone's shape and follow it when you turn it. aOS resizes the workspace's display; your Mac gets a virtual display from Open Screen Sharing, which needs the direct way to the Mac with high performance: the same Wi-Fi, or Tailscale on both. Through SSH alone your Mac keeps its own size. A higher resolution gives more room and is less sharp.")
            }
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
