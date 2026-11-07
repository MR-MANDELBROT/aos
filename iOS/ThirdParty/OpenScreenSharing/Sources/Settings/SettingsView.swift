// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Perception
import SwiftUI

// aOS: the screen's page in aOS's settings. Open Screen Sharing's settings tab with what concerns the screen: its
// "App" page as "General" (cache and tips; the language is iOS's per app setting for aOS), Keyboard and Control; aOS
// puts its own rows on top (`extra`). The macOS app's updates are left out.
struct SettingsView<Extra: View>: View {
    static var sourceCode: URL { URL(string: "https://github.com/nekohasekai/open-screen-sharing")! }

    @ViewBuilder var extra: Extra

    var body: some View {
        Form {
            extra
            Section {
                NavigationLink {
                    AppSettingsView()
                } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink {
                    KeyboardView()
                } label: {
                    Label("Keyboard", systemImage: "keyboard")
                }
                NavigationLink {
                    ControlSettingsView()
                } label: {
                    Label("Control", systemImage: "slider.horizontal.3")
                }
            }
            Section("About") {
                Link(destination: Self.sourceCode) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .formRowButtonStyleCompat()
            }
        }
        .navigationTitle("Screen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ControlSettingsView: View {
    private let settings = AppSettings.shared
    private let themes = CursorThemeStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    NavigationLink {
                        CursorStyleView()
                    } label: {
                        LabeledContentCompat {
                            switch settings.cursorStyle {
                            case .system: Text(CursorStyleView.systemStyleName)
                            case .remote: Text("Remote Style")
                            case .theme(let id): Text(verbatim: themes.theme(id: id)?.name ?? "")
                            }
                        } label: {
                            Label("Cursor Style", systemImage: "cursorarrow")
                        }
                    }
                }
            }
            .navigationTitle("Control")
        }
    }
}

private struct AppSettingsView: View {
    @State private var cacheSize: Int64?
    @State private var alert: AlertState?
    private let settings = AppSettings.shared
    @State private var replayedTutorials: [SessionTutorial] = []

    var body: some View {
        Form {
            // aOS: no language picker (iOS has one per app: Settings > Apps > aOS > Language).
            Section("Cache") {
                LabeledContentCompat {
                    if let cacheSize {
                        Text(cacheSize.formatted(.byteCount(style: .file)))
                    }
                } label: {
                    Label("Cache Size", systemImage: "internaldrive")
                }
                if let cacheSize, cacheSize > 0 {
                    Button(role: .destructive) {
                        Task { await clearCache() }
                    } label: {
                        Label {
                            Text("Clear Cache")
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    .formRowButtonStyleCompat()
                }
            }
            WithPerceptionTracking {
                Section("Tips") {
                    Button {
                        setReplayedTutorials(SessionTutorial.allCases.filter(settings.seenTutorials.contains))
                    } label: {
                        Label("Show Tips", systemImage: "lightbulb")
                    }
                    .disabled(settings.seenTutorials.isEmpty)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("General")
        .alert($alert)
        .fullScreenCover(isPresented: Binding(get: { !replayedTutorials.isEmpty }, set: { if !$0 { replayedTutorials = [] } })) {
            SessionTutorialView(pages: replayedTutorials) {
                setReplayedTutorials([])
            }
            .presentationBackgroundCompat(.clear)
        }
        .task {
            cacheSize = await Task.detached(priority: .utility) { AppDirectory.cacheSize() }.value
        }
    }

    private func setReplayedTutorials(_ tutorials: [SessionTutorial]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            replayedTutorials = tutorials
        }
    }

    private func clearCache() async {
        cacheSize = nil
        do {
            try await Task.detached(priority: .userInitiated) { try AppDirectory.clearCaches() }.value
        } catch {
            alert = AlertState(String(localized: "Couldn’t Clear the Cache"), error: error)
        }
        cacheSize = await Task.detached(priority: .utility) { AppDirectory.cacheSize() }.value
    }
}
