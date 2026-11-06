import CoreGraphics
import Foundation

// The terminal's input logic without UIKit: what a key sends, how the key bar's modifiers behave, how a paste is
// encoded, and how text is found on the screen. The views in TerminalKeyBar.swift and AOSTerminalView.swift use it;
// Tests/TerminalKeyTests.swift covers it.

/// Modifiers for the next key. The raw values are the xterm modifier bits, so `xtermParameter` is 1 + rawValue.
struct TerminalModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let shift = TerminalModifiers(rawValue: 1)
    /// Option on Apple keyboards. Sent as meta: Esc before the key.
    static let alt = TerminalModifiers(rawValue: 2)
    static let control = TerminalModifiers(rawValue: 4)

    /// The parameter in `ESC [ 1 ; <p> A` and friends.
    var xtermParameter: Int { 1 + rawValue }
}

/// A key the key bar (or a key command) sends.
enum TerminalKey: Hashable, Sendable {
    case escape, tab, enter, backspace
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, forwardDelete
    /// F1 to F12.
    case function(Int)
    /// Text as typed (a symbol of the key bar, a letter of the on-screen keyboard).
    case text(String)
}

/// What a key sends to the program in the terminal: the sequences xterm and Terminal.app send (TERM is
/// xterm-256color), with modifiers in the xterm way.
enum TerminalKeyEncoder {
    static let esc: UInt8 = 0x1b

    static func bytes(for key: TerminalKey, modifiers: TerminalModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
        let meta: [UInt8] = modifiers.contains(.alt) ? [esc] : []
        switch key {
        case .escape:
            return meta + [esc]
        case .tab:
            return modifiers.contains(.shift) ? meta + csi("Z") : meta + [0x09]
        case .enter:
            return meta + [0x0d]
        case .backspace:
            return meta + [modifiers.contains(.control) ? 0x08 : 0x7f]
        case .up: return cursor("A", modifiers, applicationCursor)
        case .down: return cursor("B", modifiers, applicationCursor)
        case .right: return cursor("C", modifiers, applicationCursor)
        case .left: return cursor("D", modifiers, applicationCursor)
        case .home: return cursor("H", modifiers, applicationCursor)
        case .end: return cursor("F", modifiers, applicationCursor)
        case .insert: return tilde(2, modifiers)
        case .forwardDelete: return tilde(3, modifiers)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .function(let n):
            switch n {
            case 1...4:
                let final = Character(UnicodeScalar(UInt8(ascii: "P") + UInt8(n - 1)))
                return modifiers.isEmpty ? [esc, UInt8(ascii: "O"), final.asciiValue!] : csi("1;\(modifiers.xtermParameter)\(final)")
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return tilde(codes[n - 5], modifiers)
            default:
                return []
            }
        case .text(let text):
            return meta + textBytes(text, control: modifiers.contains(.control))
        }
    }

    /// Text with Control held: a letter or one of the classic symbols becomes its control character; anything else
    /// is sent as it is.
    static func textBytes(_ text: String, control: Bool) -> [UInt8] {
        if control, text.count == 1, let character = text.first, let byte = controlByte(for: character) {
            return [byte]
        }
        return Array(text.utf8)
    }

    /// Control and a character, as a terminal keyboard sends it (Control-2 is NUL, Control-/ is US and so on).
    static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch character {
        case "a"..."z": return ascii - 0x60
        case "A"..."Z": return ascii - 0x40
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1b
        case "\\", "4": return 0x1c
        case "]", "5": return 0x1d
        case "^", "6", "~": return 0x1e
        case "_", "7", "-", "/": return 0x1f
        case "?", "8": return 0x7f
        default: return nil
        }
    }

    private static func csi(_ rest: String) -> [UInt8] { [esc, UInt8(ascii: "[")] + Array(rest.utf8) }

    /// Arrows, Home and End: `ESC [ A` (or `ESC O A` in application cursor mode); with modifiers `ESC [ 1 ; m A`.
    private static func cursor(_ final: Character, _ modifiers: TerminalModifiers, _ applicationCursor: Bool) -> [UInt8] {
        if !modifiers.isEmpty { return csi("1;\(modifiers.xtermParameter)\(final)") }
        return [esc, UInt8(ascii: applicationCursor ? "O" : "["), final.asciiValue!]
    }

    /// `ESC [ n ~`, with modifiers `ESC [ n ; m ~`.
    private static func tilde(_ code: Int, _ modifiers: TerminalModifiers) -> [UInt8] {
        modifiers.isEmpty ? csi("\(code)~") : csi("\(code);\(modifiers.xtermParameter)~")
    }
}

/// The key bar's modifiers. A tap holds one for the next key, a double tap locks it until the next tap, and holding
/// it down while pressing another key works like on a hardware keyboard.
struct StickyModifiers: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case off
        /// For the next key only.
        case once
        /// Until tapped again.
        case locked
    }

    static let all: [TerminalModifiers] = [.control, .alt, .shift]

    /// Two taps closer than this lock a modifier.
    var doubleTapInterval: TimeInterval = 0.35
    private var states: [Int: State] = [:]
    /// Modifiers whose key is down right now, and whether a key was sent while it was.
    private var held: [Int: Bool] = [:]
    private var lastTap: (modifier: Int, time: TimeInterval)?

    static func == (a: StickyModifiers, b: StickyModifiers) -> Bool { a.states == b.states && a.held == b.held }

    func state(of modifier: TerminalModifiers) -> State { states[modifier.rawValue] ?? .off }
    func isHeld(_ modifier: TerminalModifiers) -> Bool { held[modifier.rawValue] != nil }

    /// What applies to the next key: modifiers that are on and modifiers whose key is down.
    var active: TerminalModifiers {
        var result: TerminalModifiers = []
        for modifier in Self.all where state(of: modifier) != .off || isHeld(modifier) { result.insert(modifier) }
        return result
    }

    /// The modifier key went down.
    mutating func press(_ modifier: TerminalModifiers) {
        held[modifier.rawValue] = false
    }

    /// The modifier key went up. If no key was sent while it was down, that was a tap. `cancelled` (the touch was
    /// taken away) changes nothing.
    @discardableResult
    mutating func release(_ modifier: TerminalModifiers, at time: TimeInterval, cancelled: Bool = false) -> State {
        let usedWhileHeld = held.removeValue(forKey: modifier.rawValue) ?? false
        guard !usedWhileHeld, !cancelled else { return state(of: modifier) }
        return tap(modifier, at: time)
    }

    /// A tap: off becomes once; once becomes locked if the tap before was moments ago, else off; locked becomes off.
    @discardableResult
    mutating func tap(_ modifier: TerminalModifiers, at time: TimeInterval) -> State {
        let quick = lastTap.map { $0.modifier == modifier.rawValue && time - $0.time <= doubleTapInterval } ?? false
        let next: State
        switch state(of: modifier) {
        case .off: next = .once
        case .once: next = quick ? .locked : .off
        case .locked: next = .off
        }
        states[modifier.rawValue] = next
        lastTap = next == .once ? (modifier.rawValue, time) : nil
        return next
    }

    /// A key was sent with the active modifiers: the ones for one key are used up.
    mutating func consume() {
        for (key, state) in states where state == .once { states[key] = .off }
        for key in held.keys { held[key] = true }
        lastTap = nil
    }

    mutating func reset() {
        states = [:]
        held = [:]
        lastTap = nil
    }
}

/// Pasted text for the terminal. With bracketed paste (the shell asked for it with `CSI ? 2004 h`) the text is
/// wrapped in `ESC [ 200 ~` and `ESC [ 201 ~`, so the shell inserts it instead of running it. Control characters
/// are taken out in both cases: an Esc in the text could end the bracket early and run what follows.
enum PasteEncoder {
    static let bracketStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    static let bracketEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

    static func bytes(for text: String, bracketed: Bool) -> [UInt8] {
        let body = Array(sanitized(text, bracketed: bracketed).utf8)
        return bracketed ? bracketStart + body + bracketEnd : body
    }

    /// Line breaks become what the program expects (a newline inside a bracket, Return otherwise); tabs stay;
    /// other control characters (C0, DEL, C1) go.
    static func sanitized(_ text: String, bracketed: Bool) -> String {
        let newline: Unicode.Scalar = bracketed ? "\n" : "\r"
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar.value {
            case 0x0d:
                out.append(newline)
            case 0x0a:
                if !previousWasCR { out.append(newline) }
            case 0x09:
                out.append(scalar)
            case 0x00...0x1f, 0x7f...0x9f:
                continue
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Without bracketed paste every line break is a Return: the shell runs the lines as they arrive.
    static func runsLines(_ text: String, bracketed: Bool) -> Bool {
        !bracketed && sanitized(text, bracketed: false).contains("\r")
    }
}

/// The swipe pad of the key bar: a drag from the pad sends arrows in its direction, faster the farther it goes.
enum ArrowPad {
    static let deadZone: CGFloat = 12

    static func key(for translation: CGSize, deadZone: CGFloat = deadZone) -> TerminalKey? {
        guard hypot(translation.width, translation.height) >= deadZone else { return nil }
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
    }

    /// Time between repeated arrows: 0.3 s just past the dead zone down to 0.04 s at 100 pt.
    static func repeatInterval(distance: CGFloat) -> TimeInterval {
        let t = min(max((distance - deadZone) / (100 - deadZone), 0), 1)
        return 0.3 - Double(t) * 0.26
    }
}

/// One cell of a terminal row as text: what it shows and how many columns it takes (2 for wide characters, whose
/// second cell has width 0 and no text).
struct TextCell: Equatable, Sendable {
    var text: String
    var width: Int

    /// SwiftTerm gives cells nothing was written to as NUL; here they are empty.
    init(_ text: String, width: Int = 1) {
        self.text = text.unicodeScalars.allSatisfy { $0.value == 0 } ? "" : text
        self.width = width
    }
}

/// A row of the terminal as text, for copying.
struct TerminalRowText: Equatable, Sendable {
    /// SwiftTerm's scroll invariant row number.
    var row: Int
    var text: String
    /// The row continues the one before it (the line was longer than the terminal is wide).
    var isWrapped: Bool
}

enum TerminalText {
    /// Characters that belong to a word when selecting by word: letters, digits and what paths, options and
    /// addresses are made of.
    static func isWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "-_./~+@%:=#?&".unicodeScalars.contains(scalar)
    }

    /// The columns of the word at `column` (a character that is no word character is a word of its own). The
    /// second cell of a wide character belongs to the first.
    static func wordRange(in cells: [TextCell], at column: Int) -> ClosedRange<Int> {
        guard !cells.isEmpty else { return 0...0 }
        var column = min(max(column, 0), cells.count - 1)
        while column > 0, cells[column].width == 0 { column -= 1 }
        func extend(_ end: Int) -> Int {
            var end = end
            while end + 1 < cells.count, cells[end + 1].width == 0 { end += 1 }
            return end
        }
        guard isWordCharacter(cells[column].text) else { return column...extend(column) }
        var start = column
        while start > 0 {
            var previous = start - 1
            while previous > 0, cells[previous].width == 0 { previous -= 1 }
            guard isWordCharacter(cells[previous].text) else { break }
            start = previous
        }
        var end = extend(column)
        while end + 1 < cells.count, isWordCharacter(cells[end + 1].text) { end = extend(end + 1) }
        return start...end
    }

    /// The row as a string, and where each column starts in it (UTF-16 offsets, as NSString and the data detector
    /// count). Empty cells are spaces; the second cell of a wide character adds nothing.
    static func layout(_ cells: [TextCell]) -> (string: String, starts: [Int]) {
        var string = ""
        var starts: [Int] = []
        var offset = 0
        for cell in cells {
            starts.append(offset)
            if cell.width == 0 { continue }
            let text = cell.text.isEmpty ? " " : cell.text
            string += text
            offset += text.utf16.count
        }
        return (string, starts)
    }

    /// The columns of a web address at `column`, if there is one.
    static func linkRange(in cells: [TextCell], at column: Int) -> (columns: ClosedRange<Int>, url: URL)? {
        let (string, starts) = layout(cells)
        guard column >= 0, column < starts.count,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let offset = starts[column]
        for match in detector.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  match.range.location <= offset, offset < match.range.location + match.range.length else { continue }
            let first = starts.firstIndex { $0 >= match.range.location } ?? 0
            let last = starts.lastIndex { $0 < match.range.location + match.range.length } ?? first
            return (first...max(first, last), url)
        }
        return nil
    }

    /// Rows as text: a wrapped row continues the line before it; blank lines at the end are dropped.
    static func joined(_ rows: [TerminalRowText]) -> String {
        var lines: [String] = []
        for row in rows {
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += row.text
            } else {
                lines.append(row.text)
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    /// The output of the last command that printed something. `commandRows` are the rows where Return was pressed
    /// at the shell (oldest first), `cursorRow` is where the cursor is now (the next prompt); output is what lies
    /// between a command row and the next one. Rows come from SwiftTerm's history, in the same row numbers.
    static func lastOutput(rows: [TerminalRowText], commandRows: [Int], cursorRow: Int) -> String? {
        // Rows at or below the cursor are from before the screen was cleared.
        let commandRows = commandRows.filter { $0 < cursorRow }
        guard !rows.isEmpty, !commandRows.isEmpty else { return nil }
        let byRow = Dictionary(rows.map { ($0.row, $0) }, uniquingKeysWith: { a, _ in a })
        let ends = Array(commandRows.dropFirst()) + [cursorRow]
        for (command, next) in zip(commandRows, ends).reversed() {
            var end = next
            // The first rows of a long command line that wrapped belong to that line, not to the output before it.
            while end > command + 1, byRow[end]?.isWrapped == true { end -= 1 }
            guard end > command + 1 else { continue }
            let output = joined((command + 1..<end).compactMap { byRow[$0] })
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return output }
        }
        return nil
    }
}

/// Font sizes for pinch to zoom and the key commands.
enum TerminalFontSize {
    static let range: ClosedRange<CGFloat> = 8...28
    static let standard: CGFloat = 13

    static func clamped(_ size: CGFloat) -> CGFloat { min(max(size.rounded(), range.lowerBound), range.upperBound) }
}
