import AnnexRFB
import Foundation

/// One key press on the remote screen: an X11 key symbol and whether Shift is held for it (US/ABC layout).
struct RemoteKeyStroke: Equatable, Sendable {
    var keysym: UInt32
    var shift: Bool

    init(_ keysym: UInt32) {
        self.keysym = keysym
        shift = Keysyms.needsShift(keysym)
    }
}

/// What typing a piece of text on the iPhone keyboard turns into on the remote screen.
enum KeyInput {
    enum Step: Equatable, Sendable {
        /// Characters with a key symbol, typed key by key.
        case keys([RemoteKeyStroke])
        /// Characters without one (ä, €, emoji): on the Mac they go through its clipboard, elsewhere they can't be typed.
        case paste(String)
    }

    static let backspace: UInt32 = 0xff08
    static let escape: UInt32 = 0xff1b
    static let forwardDelete: UInt32 = 0xffff
    static let up: UInt32 = 0xff52
    static let down: UInt32 = 0xff54
    static let left: UInt32 = 0xff51
    static let right: UInt32 = 0xff53

    /// Typed text in order. iOS' smart punctuation is turned off on the input view; if it slips through anyway,
    /// typographic quotes and dashes are typed as their ASCII forms rather than pasted.
    static func steps(for text: String) -> [Step] {
        Keysyms.runs(for: asciiFallbacks(text)).map { run in
            switch run {
            case .keys(let keysyms): .keys(keysyms.map(RemoteKeyStroke.init))
            case .paste(let text): .paste(text)
            }
        }
    }

    static func asciiFallbacks(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "\u{2018}", "\u{2019}", "\u{201A}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}": out.append("\"")
            case "\u{2013}", "\u{2014}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\u{00A0}": out.append(" ")
            default: out.append(c)
            }
        }
        return out
    }
}
