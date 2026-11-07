// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import SwiftUI

struct SheetForm<Content: View>: View {
    private let title: Text
    private let content: Content

    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        Form {
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        #else
        Form {
            Section {
            } header: {
                title
                    .font(.title3.bold())
            }
            content
        }
        .formStyle(.grouped)
        .toolbar(.hidden, for: .windowToolbar)
        #endif
    }
}
