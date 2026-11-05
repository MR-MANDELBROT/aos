import Foundation

/// Key names and characters as X11 key symbols, the way macOS screen sharing expects them.
public enum Keysyms {
    public static let shift: UInt32 = 0xffe1
    public static let control: UInt32 = 0xffe3
    public static let option: UInt32 = 0xffe9      // Alt_L
    public static let command: UInt32 = 0xffeb     // Super_L: screen sharing maps it to Command
    public static let returnKey: UInt32 = 0xff0d
    public static let tab: UInt32 = 0xff09

    static let named: [String: UInt32] = {
        var m: [String: UInt32] = [
            "cmd": command, "command": command, "super": command, "meta": command, "⌘": command,
            "ctrl": control, "control": control,
            "alt": option, "option": option, "opt": option, "⌥": option,
            "shift": shift, "⇧": shift,
            "return": returnKey, "enter": returnKey,
            "tab": tab, "esc": 0xff1b, "escape": 0xff1b, "space": 0x20,
            "backspace": 0xff08, "delete": 0xffff, "forwarddelete": 0xffff,
            "up": 0xff52, "down": 0xff54, "left": 0xff51, "right": 0xff53,
            "home": 0xff50, "end": 0xff57, "pageup": 0xff55, "pagedown": 0xff56,
            "capslock": 0xffe5, "plus": 0x2b, "minus": 0x2d,
        ]
        for i in 1...12 { m["f\(i)"] = 0xffbe + UInt32(i - 1) }
        return m
    }()

    public enum KeyError: LocalizedError {
        case unknown(String)
        case empty
        public var errorDescription: String? {
            switch self {
            case .unknown(let k): return "Unknown key \"\(k)\". Use names like cmd, shift, alt, ctrl, return, tab, esc, space, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1 to f12, or single characters."
            case .empty: return "No keys given."
            }
        }
    }

    /// One key name or a single character.
    public static func key(_ name: String) throws -> UInt32 {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let k = named[n.lowercased()] { return k }
        if n.count == 1, let k = forCharacter(Character(n.lowercased())) { return k }
        throw KeyError.unknown(name)
    }

    /// "cmd+shift+4" -> key symbols in press order. A lone "+" is the plus key.
    public static func combination(_ text: String) throws -> [UInt32] {
        let trimmed = text.replacingOccurrences(of: " ", with: "")
        if trimmed == "+" { return [0x2b] }
        var parts = trimmed.components(separatedBy: "+")
        // "cmd++" means cmd and plus
        if trimmed.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        parts = parts.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw KeyError.empty }
        return try parts.map(key)
    }

    /// Printable ASCII maps to its code (X11 keysyms equal Latin-1 there); line breaks and tabs to their keys.
    public static func forCharacter(_ c: Character) -> UInt32? {
        if c == "\n" || c == "\r" { return returnKey }
        if c == "\t" { return tab }
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return nil }
        if scalar.value >= 0x20 && scalar.value < 0x7f { return scalar.value }
        return nil
    }

    /// Characters typed with Shift on a US (ABC) layout. Sent with an explicit Shift press, because not every VNC
    /// server adds it (the hypervisor's server types "A" as "a").
    public static func needsShift(_ keysym: UInt32) -> Bool {
        guard keysym < 0x80, let scalar = Unicode.Scalar(keysym) else { return false }
        let c = Character(scalar)
        return c.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(c)
    }

    /// Splits text into runs that can be typed key by key (ASCII) and runs that need the clipboard.
    public enum Run: Equatable { case keys([UInt32]), paste(String) }

    public static func runs(for text: String) -> [Run] {
        var result: [Run] = []
        var keys: [UInt32] = []
        var paste = ""
        for c in text {
            if let k = forCharacter(c) {
                if !paste.isEmpty { result.append(.paste(paste)); paste = "" }
                keys.append(k)
            } else {
                if !keys.isEmpty { result.append(.keys(keys)); keys = [] }
                paste.append(c)
            }
        }
        if !keys.isEmpty { result.append(.keys(keys)) }
        if !paste.isEmpty { result.append(.paste(paste)) }
        return result
    }
}
