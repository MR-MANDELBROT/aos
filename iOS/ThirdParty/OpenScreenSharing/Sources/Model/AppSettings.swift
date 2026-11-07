// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import Perception

@Perceptible
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let showsDebugInfo = "showsDebugInfo"
        static let cursorStyle = "cursorStyle"
        static let computerLayout = "computerLayout"
        static let computerOrder = "computerOrder"
        static let seenTutorials = "seenTutorials"
    }

    var showsDebugInfo: Bool {
        didSet { store.set(showsDebugInfo, for: Key.showsDebugInfo) }
    }

    var cursorStyle: CursorStyle {
        didSet { store.set(cursorStyle, for: Key.cursorStyle) }
    }

    var computerLayout: ComputerLayout {
        didSet { store.set(computerLayout, for: Key.computerLayout) }
    }

    var computerOrder: [UUID] {
        didSet { store.set(computerOrder, for: Key.computerOrder) }
    }

    var seenTutorials: Set<SessionTutorial> {
        didSet { store.set(seenTutorials, for: Key.seenTutorials) }
    }

    private let store = PreferenceStore.shared

    init() {
        showsDebugInfo = store.value(Bool.self, for: Key.showsDebugInfo) ?? false
        cursorStyle = store.value(CursorStyle.self, for: Key.cursorStyle) ?? .system
        computerLayout = store.value(ComputerLayout.self, for: Key.computerLayout) ?? .grid
        computerOrder = store.value([UUID].self, for: Key.computerOrder) ?? []
        seenTutorials = store.value(Set<SessionTutorial>.self, for: Key.seenTutorials) ?? []
    }
}

enum CursorStyle: Codable, Hashable {
    case system
    case remote
    case theme(String)
}

enum ComputerLayout: String, Codable {
    case grid
    case list
}
