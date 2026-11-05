import AnnexKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = AgentSettings()
    @State private var domains = ""

    var body: some View {
        Form {
            Section("Session") {
                TextField("Name in the Claude app", text: $draft.sessionName)
                Toggle("Keep the session running", isOn: $draft.sessionEnabled)
                Toggle("Keep this Mac awake", isOn: $draft.keepAwake)
                Text("The Mac doesn't go to sleep by itself while the session runs. Closing a laptop's lid still puts it to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Start \(Brand.name) at login", isOn: Binding(
                    get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
            }
            Section("Workspace") {
                Toggle("Sign-ins expire when the workspace closes", isOn: $draft.expireSignIns)
                Text(draft.expireSignIns
                     ? "The workspace shuts down after each use; websites forget sign-ins, except the domains below (fewer captchas there)."
                     : "The workspace is suspended after each use and continues exactly where it was, signed in everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Stay signed in on", text: $domains, prompt: Text("[*.]google.com"))
                    .disabled(!draft.expireSignIns)
                Stepper("Close after \(draft.idleMinutes) min without activity", value: $draft.idleMinutes, in: 5...120, step: 5)
            }
            Section("Folders") {
                LabeledContent("Exchange") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.exchange) }
                }
                LabeledContent("Data") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.root) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.bottom, 8)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Changes to sign-ins apply to the workspace at its next start.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    var s = draft
                    s.keepSignedIn = domains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                        .map(String.init).filter { !$0.isEmpty }
                    s.sessionName = s.sessionName.trimmingCharacters(in: .whitespaces).isEmpty ? Brand.defaultSessionName : s.sessionName
                    model.save(s)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .onAppear {
            draft = model.settings
            domains = model.settings.keepSignedIn.joined(separator: ", ")
        }
    }
}
