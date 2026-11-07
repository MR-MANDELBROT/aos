// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

#if os(iOS)
import UIKit
#else
import Carbon
#endif

nonisolated struct MacKey: Hashable, Sendable {
    var keyCode: UInt16?
    var keysym: UInt32

    init(keyCode: UInt16?, keysym: UInt32) {
        self.keyCode = keyCode
        self.keysym = keysym
    }

    init(keysym: UInt32) {
        self.init(keyCode: Self.namedKeyCodes[keysym], keysym: keysym)
    }

    var isModifier: Bool { Keysym.isModifier(keysym) }

    static let returnKey = MacKey(keyCode: 36, keysym: Keysym.returnKey)
    static let tab = MacKey(keyCode: 48, keysym: Keysym.tab)
    static let space = MacKey(keyCode: 49, keysym: Keysym.space)
    static let backspace = MacKey(keyCode: 51, keysym: Keysym.backSpace)
    static let escape = MacKey(keyCode: 53, keysym: Keysym.escape)
    static let forwardDelete = MacKey(keyCode: 117, keysym: Keysym.forwardDelete)
    static let home = MacKey(keyCode: 115, keysym: Keysym.home)
    static let end = MacKey(keyCode: 119, keysym: Keysym.end)
    static let pageUp = MacKey(keyCode: 116, keysym: Keysym.pageUp)
    static let pageDown = MacKey(keyCode: 121, keysym: Keysym.pageDown)
    static let left = MacKey(keyCode: 123, keysym: Keysym.left)
    static let right = MacKey(keyCode: 124, keysym: Keysym.right)
    static let down = MacKey(keyCode: 125, keysym: Keysym.down)
    static let up = MacKey(keyCode: 126, keysym: Keysym.up)
    static let command = MacKey(keyCode: 55, keysym: Keysym.commandLeft)
    static let shift = MacKey(keyCode: 56, keysym: Keysym.shiftLeft)
    static let option = MacKey(keyCode: 58, keysym: Keysym.optionLeft)
    static let control = MacKey(keyCode: 59, keysym: Keysym.controlLeft)
    static let insert = MacKey(keyCode: nil, keysym: Keysym.insert)
    static let printScreen = MacKey(keyCode: nil, keysym: Keysym.printScreen)
    static let menu = MacKey(keyCode: nil, keysym: Keysym.menu)
    // ScreensharingAgent sets the Caps Lock flag on key-down and clears it on key-up
    // (ScreensharingAgent 756.36.5.2, macOS 27.0.1 26A434, UUID DA1CD9BA-97A1-3758-B425-00FA34B428A3,
    // sub_1000350fc 0x1000351a4..0x10003529c, keyCode 0x39 jump table entry 0x1000352b8;
    // ScreensharingAgent 766.8, macOS 27.2 26B5101f, UUID D8791A89-6EDB-3A0A-A720-EC3F5FB1AD4F,
    // sub_100035484 0x10003552c..0x100035624, keyCode 0x39 jump table entry 0x100035640).
    static let capsLock = MacKey(keyCode: 57, keysym: 0)

    private static let functionKeyCodes: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    static func function(_ number: Int) -> MacKey {
        let keyCode = (1...functionKeyCodes.count).contains(number) ? functionKeyCodes[number - 1] : nil
        return MacKey(keyCode: keyCode, keysym: Keysym.function(number))
    }

    private static let namedKeyCodes: [UInt32: UInt16] = {
        var table: [UInt32: UInt16] = [:]
        let keys: [MacKey] = [
            .returnKey, .tab, .space, .backspace, .escape, .forwardDelete, .home, .end, .pageUp, .pageDown,
            .left, .right, .down, .up, .command, .shift, .option, .control,
            MacKey(keyCode: 54, keysym: Keysym.commandRight), MacKey(keyCode: 60, keysym: Keysym.shiftRight),
            MacKey(keyCode: 61, keysym: Keysym.optionRight), MacKey(keyCode: 62, keysym: Keysym.controlRight),
            MacKey(keyCode: 114, keysym: Keysym.help),
        ]
        for key in keys {
            table[key.keysym] = key.keyCode
        }
        for (index, keyCode) in functionKeyCodes.enumerated() {
            table[Keysym.function(index + 1)] = keyCode
        }
        return table
    }()

    #if os(iOS)
    static func keyCode(for usage: UIKeyboardHIDUsage, type: MacKeyboardType) -> UInt16? {
        switch usage {
        case .keyboardGraveAccentAndTilde: return type == .iso ? 10 : 50
        case .keyboardNonUSBackslash: return type == .iso ? 50 : 10
        default: return hidKeyCodes[usage.rawValue]
        }
    }

    private static let hidKeyCodes: [Int: UInt16] = {
        var table: [Int: UInt16] = [:]
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (index, keyCode) in letters.enumerated() {
            table[UIKeyboardHIDUsage.keyboardA.rawValue + index] = keyCode
        }
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (index, keyCode) in digits.enumerated() {
            table[UIKeyboardHIDUsage.keyboard1.rawValue + index] = keyCode
        }
        let others: [(UIKeyboardHIDUsage, UInt16)] = [
            (.keyboardReturnOrEnter, 36), (.keyboardReturn, 36), (.keyboardEscape, 53), (.keyboardDeleteOrBackspace, 51), (.keyboardTab, 48),
            (.keyboardSpacebar, 49), (.keyboardHyphen, 27), (.keyboardEqualSign, 24), (.keyboardOpenBracket, 33),
            (.keyboardCloseBracket, 30), (.keyboardBackslash, 42), (.keyboardNonUSPound, 42), (.keyboardSemicolon, 41),
            (.keyboardQuote, 39), (.keyboardComma, 43), (.keyboardPeriod, 47), (.keyboardSlash, 44),
            (.keyboardCapsLock, 57),
            (.keyboardF1, 122), (.keyboardF2, 120), (.keyboardF3, 99), (.keyboardF4, 118), (.keyboardF5, 96),
            (.keyboardF6, 97), (.keyboardF7, 98), (.keyboardF8, 100), (.keyboardF9, 101), (.keyboardF10, 109),
            (.keyboardF11, 103), (.keyboardF12, 111), (.keyboardPrintScreen, 105), (.keyboardScrollLock, 107),
            (.keyboardPause, 113), (.keyboardInsert, 114), (.keyboardHome, 115), (.keyboardPageUp, 116),
            (.keyboardDeleteForward, 117), (.keyboardEnd, 119), (.keyboardPageDown, 121), (.keyboardRightArrow, 124),
            (.keyboardLeftArrow, 123), (.keyboardDownArrow, 125), (.keyboardUpArrow, 126),
            (.keypadNumLock, 71), (.keypadSlash, 75), (.keypadAsterisk, 67), (.keypadHyphen, 78), (.keypadPlus, 69),
            (.keypadEnter, 76), (.keypad1, 83), (.keypad2, 84), (.keypad3, 85), (.keypad4, 86), (.keypad5, 87),
            (.keypad6, 88), (.keypad7, 89), (.keypad8, 91), (.keypad9, 92), (.keypad0, 82), (.keypadPeriod, 65),
            (.keypadEqualSign, 81), (.keypadComma, 95), (.keyboardApplication, 110),
            (.keyboardF13, 105), (.keyboardF14, 107), (.keyboardF15, 113), (.keyboardF16, 106), (.keyboardF17, 64),
            (.keyboardF18, 79), (.keyboardF19, 80), (.keyboardF20, 90), (.keyboardHelp, 114),
            (.keyboardMute, 74), (.keyboardVolumeUp, 72), (.keyboardVolumeDown, 73),
            (.keyboardInternational1, 94), (.keyboardInternational3, 93), (.keyboardLANG1, 104), (.keyboardLANG2, 102),
            (.keyboardLeftControl, 59), (.keyboardLeftShift, 56), (.keyboardLeftAlt, 58), (.keyboardLeftGUI, 55),
            (.keyboardRightControl, 62), (.keyboardRightShift, 60), (.keyboardRightAlt, 61), (.keyboardRightGUI, 54),
        ]
        for (usage, keyCode) in others {
            table[usage.rawValue] = keyCode
        }
        return table
    }()
    #endif

    static func usKeystroke(for character: Character) -> (key: MacKey, shift: Bool)? {
        guard let ascii = character.asciiValue else { return nil }
        let keysym = UInt32(ascii)
        if let (keyCode, shift) = usKeystrokes[ascii] {
            return (MacKey(keyCode: keyCode, keysym: keysym), shift)
        }
        return nil
    }

    private static let usKeystrokes: [UInt8: (UInt16, Bool)] = {
        var table: [UInt8: (UInt16, Bool)] = [:]
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (index, keyCode) in letters.enumerated() {
            table[UInt8(ascii: "a") + UInt8(index)] = (keyCode, false)
            table[UInt8(ascii: "A") + UInt8(index)] = (keyCode, true)
        }
        let plain: [(Character, UInt16)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
            ("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42), (";", 41), ("'", 39), (",", 43), (".", 47),
            ("/", 44), ("`", 50), (" ", 49),
        ]
        let shifted: [(Character, UInt16)] = [
            ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23), ("^", 22), ("&", 26), ("*", 28), ("(", 25), (")", 29),
            ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42), (":", 41), ("\"", 39), ("<", 43), (">", 47),
            ("?", 44), ("~", 50),
        ]
        for (character, keyCode) in plain {
            table[character.asciiValue!] = (keyCode, false)
        }
        for (character, keyCode) in shifted {
            table[character.asciiValue!] = (keyCode, true)
        }
        return table
    }()
}

nonisolated enum MacKeyboardType: Sendable {
    case ansi
    case iso
    case jis

    #if os(iOS)
    func learning(from usage: UIKeyboardHIDUsage) -> MacKeyboardType {
        switch usage {
        case .keyboardLANG1, .keyboardLANG2, .keyboardInternational1, .keyboardInternational3, .keypadComma:
            .jis
        case .keyboardNonUSBackslash, .keyboardNonUSPound:
            self == .jis ? .jis : .iso
        default:
            self
        }
    }
    #else
    static var current: MacKeyboardType {
        switch KBGetLayoutType(Int16(LMGetKbdType())) {
        case OSType(kKeyboardISO): .iso
        case OSType(kKeyboardJIS): .jis
        default: .ansi
        }
    }
    #endif
}

nonisolated enum WindowsKeyboardLayout {
    #if os(iOS)
    static var current: Int { 0 }
    #else
    static var current: Int {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return 0 }
        let name = (Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String).replacingOccurrences(of: "com.apple.keylayout.", with: "")
        return identifiers[name] ?? 0
    }

    private static let identifiers: [String: Int] = [
        "British": 0x0809, "British-PC": 0x0809, "Irish": 0x1809,
        "German": 0x0407, "Austrian": 0x0407, "Swiss German": 0x0807, "Swiss French": 0x100C,
        "French": 0x040C, "French-PC": 0x040C, "French-numerical": 0x040C, "Belgian": 0x080C, "Canadian-CSA": 0x1009,
        "Spanish": 0x040A, "Spanish-ISO": 0x040A, "Italian": 0x0410, "Italian-Pro": 0x0410,
        "Portuguese": 0x0816, "Brazilian": 0x0416, "Brazilian-ABNT2": 0x0416, "Brazilian-Pro": 0x0416,
        "Dutch": 0x0413, "Danish": 0x0406, "Norwegian": 0x0414, "Swedish": 0x041D, "Swedish-Pro": 0x041D, "Finnish": 0x040B,
        "Icelandic": 0x040F, "Polish": 0x0415, "PolishPro": 0x0415, "Czech": 0x0405, "Czech-QWERTY": 0x0405, "Slovak": 0x041B,
        "Slovak-QWERTY": 0x041B, "Hungarian": 0x040E, "Romanian": 0x0418, "Croatian": 0x041A, "Slovenian": 0x0424,
        "Estonian": 0x0425, "Latvian": 0x0426, "Lithuanian": 0x0427, "Turkish": 0x041F, "Turkish-QWERTY-PC": 0x041F,
        "Russian": 0x0419, "RussianWin": 0x0419, "Russian-Phonetic": 0x0419, "Ukrainian": 0x0422, "Ukrainian-PC": 0x0422,
        "Greek": 0x0408, "Hebrew": 0x040D, "Arabic": 0x0401, "Thai": 0x041E,
    ]
    #endif
}

extension ModifierKey {
    var macKey: MacKey {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }
}
