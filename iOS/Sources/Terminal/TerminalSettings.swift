import CoreLocation
import SwiftUI

/// Settings > Terminal: the key bar's arrows, swiping for arrow keys, the screen, and what keeps terminals going in
/// the background.
struct TerminalSettingsForm: View {
    @Environment(AppModel.self) private var model
    @State private var locationAllowed = TerminalKeepAlive.locationAllowed

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Arrow keys", selection: $settings.terminalArrowKeys) {
                    Text("Arrow pad").tag(TerminalArrowKeys.pad)
                    Text("Four keys").tag(TerminalArrowKeys.fourKeys)
                }
                Toggle("Swipe for arrow keys", isOn: $settings.terminalSwipeArrows)
            } header: {
                Text("Keys")
            } footer: {
                Text("The arrows sit in the middle of the key bar; the whole bar scrolls. Swiping on the terminal works like the pad: sideways for ← and →, a quick flick up or down for ↑ and ↓ while the terminal shows its end (slower drags scroll back). Keep your finger down to repeat.")
            }

            Section {
                Toggle("Keep Screen On", isOn: $settings.terminalKeepsScreenOn)
            } footer: {
                Text("While a terminal is open and connected.")
            }

            Section {
                Toggle("Live Activity", isOn: $settings.terminalLiveActivity)
                Toggle("Keep alive with location", isOn: Binding(get: { settings.terminalKeepAliveLocation }, set: { on in
                    settings.terminalKeepAliveLocation = on
                    if on { TerminalKeepAlive.requestLocationPermission() }
                }))
                if settings.terminalKeepAliveLocation, !locationAllowed {
                    Label("aOS may not use the location service yet. Allow it while using the app in Settings > Privacy & Security > Location Services.",
                          systemImage: "location.slash")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("In the background")
            } footer: {
                Text("Terminals on your Mac keep running there when the connection drops, also with this app closed, and pick up where they left off. On the iPhone, the Live Activity shows open terminals on the Lock Screen with a button to end them. With location, aOS keeps running as long as a terminal is open: it costs battery (aOS asks for the coarsest location and doesn't use it) and iOS shows the location arrow.")
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        // Switched off: the Live Activity goes at once.
        .onChange(of: settings.terminalLiveActivity) { _, _ in model.keepAlive.terminalsChanged() }
        .onAppear { locationAllowed = TerminalKeepAlive.locationAllowed }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            locationAllowed = TerminalKeepAlive.locationAllowed
        }
    }
}
