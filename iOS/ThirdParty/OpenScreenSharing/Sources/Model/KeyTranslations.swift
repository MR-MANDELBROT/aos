// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import SwiftUI

enum KeyTranslations {
    static func output(for shortcut: KeyShortcut) -> KeyShortcut? {
        if let output = table[shortcut] {
            return output
        }
        guard shortcut.eventModifiers.contains(.shift) else { return nil }
        let unshifted = KeyShortcut(key: shortcut.key, modifiers: shortcut.eventModifiers.subtracting(.shift))
        guard let output = table[unshifted] else { return nil }
        return KeyShortcut(key: output.key, modifiers: output.eventModifiers.union(.shift))
    }

    private static let table: [KeyShortcut: KeyShortcut] = {
        var table: [KeyShortcut: KeyShortcut] = [:]
        for character in "zxcvafgsonpwtlrdbiuk0=-,/" {
            table[KeyShortcut(key: String(character), modifiers: .command)] = KeyShortcut(key: String(character), modifiers: .control)
        }
        let pairs: [(KeyShortcut, KeyShortcut)] = [
            (KeyShortcut(key: "z", modifiers: [.shift, .command]), KeyShortcut(key: "y", modifiers: .control)),
            (KeyShortcut(key: "q", modifiers: .command), KeyShortcut(key: "f4", modifiers: .option)),
            (KeyShortcut(key: "m", modifiers: .command), KeyShortcut(key: "downArrow", modifiers: .command)),
            (KeyShortcut(key: "[", modifiers: .command), KeyShortcut(key: "leftArrow", modifiers: .option)),
            (KeyShortcut(key: "]", modifiers: .command), KeyShortcut(key: "rightArrow", modifiers: .option)),
            (KeyShortcut(key: "[", modifiers: [.shift, .command]), KeyShortcut(key: "tab", modifiers: [.control, .shift])),
            (KeyShortcut(key: "]", modifiers: [.shift, .command]), KeyShortcut(key: "tab", modifiers: .control)),
            (KeyShortcut(key: "return", modifiers: .command), KeyShortcut(key: "return", modifiers: .control)),
            (KeyShortcut(key: "tab", modifiers: .command), KeyShortcut(key: "tab", modifiers: .option)),
            (KeyShortcut(key: "leftArrow", modifiers: .command), KeyShortcut(key: "home", modifiers: [])),
            (KeyShortcut(key: "rightArrow", modifiers: .command), KeyShortcut(key: "end", modifiers: [])),
            (KeyShortcut(key: "upArrow", modifiers: .command), KeyShortcut(key: "home", modifiers: .control)),
            (KeyShortcut(key: "downArrow", modifiers: .command), KeyShortcut(key: "end", modifiers: .control)),
            (KeyShortcut(key: "leftArrow", modifiers: .option), KeyShortcut(key: "leftArrow", modifiers: .control)),
            (KeyShortcut(key: "rightArrow", modifiers: .option), KeyShortcut(key: "rightArrow", modifiers: .control)),
            (KeyShortcut(key: "delete", modifiers: .option), KeyShortcut(key: "delete", modifiers: .control)),
            (KeyShortcut(key: "deleteForward", modifiers: .option), KeyShortcut(key: "deleteForward", modifiers: .control)),
        ]
        for (trigger, output) in pairs {
            table[trigger] = output
        }
        return table
    }()
}
