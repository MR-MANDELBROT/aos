import ScreenClient
import SwiftUI

/// Settings > Screen: Open Screen Sharing's settings (general, keyboard, control), with aOS's own rows for the
/// workspace on top. What a session remembers per screen (quality, clipboard, pointer lock) is chosen in the session's
/// menu, as in Open Screen Sharing.
struct ScreenSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ScreenClientSettings {
            Section {
                Toggle("The workspace in the iPhone's shape", isOn: $settings.matchWorkspaceShape)
                Toggle("Retina sharpness", isOn: $settings.retinaWorkspace)
                    .disabled(!settings.matchWorkspaceShape)
            } header: {
                Text("Workspace")
            } footer: {
                Text("While you watch it, the workspace's display takes the iPhone's shape and fills the screen. Retina draws it twice as sharp with more data. Applies the next time the workspace screen opens.")
            }
        }
    }
}

/// Settings > Acknowledgements: where the screen comes from, its license and its source.
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Text("The screen of the workspace and of the Mac is based on Open Screen Sharing by nekohasekai, used under the GNU General Public License, version 3. aOS changed it for its own use: the screens are reached through the connection to your Mac, and aOS's sign-in replaces the app's own.")
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
