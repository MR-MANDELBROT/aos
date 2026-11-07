// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation

nonisolated struct MacInputSource: Hashable, Sendable {
    let id: String

    var isInputMethod: Bool { !id.hasPrefix("com.apple.keylayout.") }
}
