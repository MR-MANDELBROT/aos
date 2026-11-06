import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import aOS

/// What the key bar's keys send (TerminalKeyEncoder), as xterm and Terminal.app send it.
struct TerminalKeyEncoderTests {
    private func bytes(_ key: TerminalKey, _ modifiers: TerminalModifiers = [], app: Bool = false) -> [UInt8] {
        TerminalKeyEncoder.bytes(for: key, modifiers: modifiers, applicationCursor: app)
    }

    private func esc(_ rest: String) -> [UInt8] { [0x1b] + Array(rest.utf8) }

    @Test func plainKeys() {
        #expect(bytes(.escape) == [0x1b])
        #expect(bytes(.tab) == [0x09])
        #expect(bytes(.enter) == [0x0d])
        #expect(bytes(.backspace) == [0x7f])
        #expect(bytes(.text("~")) == Array("~".utf8))
        #expect(bytes(.text("ä")) == Array("ä".utf8))
    }

    @Test func arrowsFollowTheCursorKeyMode() {
        #expect(bytes(.up) == esc("[A"))
        #expect(bytes(.down) == esc("[B"))
        #expect(bytes(.right) == esc("[C"))
        #expect(bytes(.left) == esc("[D"))
        #expect(bytes(.up, app: true) == esc("OA"))
        #expect(bytes(.home, app: true) == esc("OH"))
        #expect(bytes(.end) == esc("[F"))
    }

    @Test func modifiedArrowsUseTheXtermParameter() {
        #expect(bytes(.up, .control) == esc("[1;5A"))
        #expect(bytes(.left, .alt) == esc("[1;3D"))
        #expect(bytes(.right, [.shift, .control]) == esc("[1;6C"))
        // Modifiers win over application cursor mode, as in xterm
        #expect(bytes(.down, .shift, app: true) == esc("[1;2B"))
    }

    @Test func navigationAndFunctionKeys() {
        #expect(bytes(.pageUp) == esc("[5~"))
        #expect(bytes(.pageDown, .control) == esc("[6;5~"))
        #expect(bytes(.forwardDelete) == esc("[3~"))
        #expect(bytes(.insert) == esc("[2~"))
        #expect(bytes(.function(1)) == esc("OP"))
        #expect(bytes(.function(4)) == esc("OS"))
        #expect(bytes(.function(5)) == esc("[15~"))
        #expect(bytes(.function(10)) == esc("[21~"))
        #expect(bytes(.function(12)) == esc("[24~"))
        #expect(bytes(.function(1), .shift) == esc("[1;2P"))
        #expect(bytes(.function(5), .control) == esc("[15;5~"))
        #expect(bytes(.function(13)).isEmpty)
    }

    @Test func tabEscapeAndBackspaceWithModifiers() {
        #expect(bytes(.tab, .shift) == esc("[Z"))
        #expect(bytes(.tab, .alt) == [0x1b, 0x09])
        #expect(bytes(.escape, .alt) == [0x1b, 0x1b])
        #expect(bytes(.backspace, .control) == [0x08])
        #expect(bytes(.backspace, .alt) == [0x1b, 0x7f])
        #expect(bytes(.enter, .alt) == [0x1b, 0x0d])
    }

    @Test func controlTurnsCharactersIntoControlCodes() {
        #expect(bytes(.text("c"), .control) == [0x03])
        #expect(bytes(.text("C"), .control) == [0x03])
        #expect(bytes(.text("a"), .control) == [0x01])
        #expect(bytes(.text("z"), .control) == [0x1a])
        #expect(bytes(.text("["), .control) == [0x1b])
        #expect(bytes(.text("\\"), .control) == [0x1c])
        #expect(bytes(.text("]"), .control) == [0x1d])
        #expect(bytes(.text("^"), .control) == [0x1e])
        #expect(bytes(.text("_"), .control) == [0x1f])
        #expect(bytes(.text("/"), .control) == [0x1f])
        #expect(bytes(.text(" "), .control) == [0x00])
        #expect(bytes(.text("@"), .control) == [0x00])
        #expect(bytes(.text("?"), .control) == [0x7f])
        // Nothing to map: sent as typed
        #expect(bytes(.text("ä"), .control) == Array("ä".utf8))
        #expect(bytes(.text("ab"), .control) == Array("ab".utf8))
    }

    @Test func optionIsMeta() {
        #expect(bytes(.text("x"), .alt) == [0x1b, UInt8(ascii: "x")])
        #expect(bytes(.text("b"), .alt) == [0x1b, UInt8(ascii: "b")])
        #expect(bytes(.text("c"), [.alt, .control]) == [0x1b, 0x03])
    }
}

/// The key bar's modifiers: tap for one key, double tap to lock, hold like a hardware key.
struct StickyModifierTests {
    @Test func aTapHoldsAModifierForOneKey() {
        var m = StickyModifiers()
        #expect(m.active.isEmpty)
        #expect(m.tap(.control, at: 0) == .once)
        #expect(m.active == .control)
        m.consume()
        #expect(m.state(of: .control) == .off)
        #expect(m.active.isEmpty)
    }

    @Test func aSecondTapTurnsItOffAgain() {
        var m = StickyModifiers()
        m.tap(.control, at: 0)
        #expect(m.tap(.control, at: 1) == .off)
        #expect(m.active.isEmpty)
    }

    @Test func aDoubleTapLocksUntilTheNextTap() {
        var m = StickyModifiers()
        m.tap(.alt, at: 10)
        #expect(m.tap(.alt, at: 10.2) == .locked)
        m.consume()
        m.consume()
        #expect(m.state(of: .alt) == .locked)
        #expect(m.active == .alt)
        // A quick third tap unlocks; it doesn't start a new double tap
        #expect(m.tap(.alt, at: 10.3) == .off)
        #expect(m.tap(.alt, at: 10.4) == .once)
    }

    @Test func aTapAfterAKeyIsNotADoubleTap() {
        var m = StickyModifiers()
        m.tap(.control, at: 0)
        m.consume()
        #expect(m.tap(.control, at: 0.1) == .once)
    }

    @Test func taps_ofDifferentModifiersDontLock() {
        var m = StickyModifiers()
        m.tap(.control, at: 0)
        #expect(m.tap(.alt, at: 0.1) == .once)
        #expect(m.active == [.control, .alt])
        m.consume()
        #expect(m.active.isEmpty)
    }

    @Test func holdingWorksLikeAHardwareKey() {
        var m = StickyModifiers()
        m.press(.control)
        #expect(m.active == .control)
        m.consume()  // a key was sent while held
        #expect(m.active == .control)
        #expect(m.release(.control, at: 1) == .off)
        #expect(m.active.isEmpty)
    }

    @Test func pressAndReleaseWithoutAKeyIsATap() {
        var m = StickyModifiers()
        m.press(.control)
        #expect(m.release(.control, at: 1) == .once)
        m.press(.control)
        #expect(m.release(.control, at: 1.2) == .locked)
    }

    @Test func aCancelledTouchChangesNothing() {
        var m = StickyModifiers()
        m.press(.alt)
        #expect(m.release(.alt, at: 1, cancelled: true) == .off)
        #expect(m.active.isEmpty)
    }

    @Test func resetClearsEverything() {
        var m = StickyModifiers()
        m.tap(.control, at: 0)
        m.tap(.control, at: 0.1)
        m.press(.alt)
        m.reset()
        #expect(m.active.isEmpty)
        #expect(m.state(of: .control) == .off)
    }
}

/// Pasting: bracketed when the shell asked for it, control characters taken out, line breaks as the program
/// expects them.
struct PasteEncoderTests {
    private let start = "\u{1b}[200~", end = "\u{1b}[201~"

    @Test func bracketedPasteWrapsTheText() {
        let bytes = PasteEncoder.bytes(for: "echo hi\nls", bracketed: true)
        #expect(String(decoding: bytes, as: UTF8.self) == start + "echo hi\nls" + end)
    }

    @Test func withoutBracketsLineBreaksAreReturns() {
        #expect(PasteEncoder.bytes(for: "a\nb\r\nc\rd", bracketed: false) == Array("a\rb\rc\rd".utf8))
    }

    @Test func insideBracketsLineBreaksAreNewlines() {
        #expect(PasteEncoder.sanitized("a\r\nb\rc\n", bracketed: true) == "a\nb\nc\n")
    }

    @Test func anEscapeInTheTextCannotEndTheBracket() {
        let text = "safe\u{1b}[201~rm -rf ~\n"
        let pasted = String(decoding: PasteEncoder.bytes(for: text, bracketed: true), as: UTF8.self)
        #expect(pasted == start + "safe[201~rm -rf ~\n" + end)
        #expect(pasted.components(separatedBy: end).count == 2)
    }

    @Test func controlCharactersAreDroppedTabsStay() {
        #expect(PasteEncoder.sanitized("a\tb\u{03}c\u{00}d\u{7f}e\u{9b}f\u{08}", bracketed: false) == "a\tbcdef")
        #expect(PasteEncoder.sanitized("ä € 😀 日本", bracketed: true) == "ä € 😀 日本")
    }

    @Test func onlyUnbracketedLineBreaksRunCommands() {
        #expect(PasteEncoder.runsLines("ls\npwd", bracketed: false))
        #expect(PasteEncoder.runsLines("ls\n", bracketed: false))
        #expect(!PasteEncoder.runsLines("ls\npwd", bracketed: true))
        #expect(!PasteEncoder.runsLines("ls -la", bracketed: false))
    }
}

struct ArrowPadTests {
    @Test func directionsPastTheDeadZone() {
        #expect(ArrowPad.key(for: CGSize(width: 5, height: 5)) == nil)
        #expect(ArrowPad.key(for: CGSize(width: 20, height: 4)) == .right)
        #expect(ArrowPad.key(for: CGSize(width: -20, height: 10)) == .left)
        #expect(ArrowPad.key(for: CGSize(width: 3, height: -15)) == .up)
        #expect(ArrowPad.key(for: CGSize(width: -6, height: 30)) == .down)
    }

    @Test func fartherIsFaster() {
        let near = ArrowPad.repeatInterval(distance: 12)
        let middle = ArrowPad.repeatInterval(distance: 50)
        let far = ArrowPad.repeatInterval(distance: 200)
        #expect(near > middle && middle > far)
        #expect(abs(near - 0.3) < 0.001)
        #expect(abs(far - 0.04) < 0.001)
    }
}

/// Finding words and links in a row, and text for copying.
struct TerminalTextTests {
    private func cells(_ text: String) -> [TextCell] { text.map { TextCell(String($0)) } }

    @Test func aWordIncludesPathCharacters() {
        let row = cells("ls -la /usr/local/bin; echo")
        #expect(TerminalText.wordRange(in: row, at: 10) == 7...20)
        #expect(TerminalText.wordRange(in: row, at: 4) == 3...5)
        // Not a word character: a word of its own
        #expect(TerminalText.wordRange(in: row, at: 2) == 2...2)
        #expect(TerminalText.wordRange(in: row, at: 21) == 21...21)
        #expect(TerminalText.wordRange(in: row, at: 99) == 23...26)
    }

    @Test func wideCharactersCountAsOne() {
        let row = [TextCell("日", width: 2), TextCell("", width: 0), TextCell("本", width: 2), TextCell("", width: 0),
                   TextCell(" "), TextCell("a")]
        #expect(TerminalText.wordRange(in: row, at: 1) == 0...3)
        #expect(TerminalText.wordRange(in: row, at: 5) == 5...5)
        let layout = TerminalText.layout(row)
        #expect(layout.string == "日本 a")
        #expect(layout.starts == [0, 1, 1, 2, 2, 3])
        // Cells nothing was written to come as NUL from SwiftTerm
        #expect(TerminalText.layout([TextCell("a"), TextCell("\u{0}"), TextCell("b")]).string == "a b")
    }

    @Test func aLinkIsFoundWhole() throws {
        let row = cells("open https://example.com/a?b=1 (now)")
        let link = try #require(TerminalText.linkRange(in: row, at: 12))
        #expect(link.columns == 5...29)
        #expect(link.url.absoluteString == "https://example.com/a?b=1")
        #expect(TerminalText.linkRange(in: row, at: 1) == nil)
        #expect(TerminalText.linkRange(in: cells("get ftp://example.com/file"), at: 8) == nil)
    }

    @Test func rowsJoinWhereTheyWrapped() {
        let rows = [TerminalRowText(row: 0, text: "$ echo aaaa", isWrapped: false),
                    TerminalRowText(row: 1, text: "bbbb  ", isWrapped: true),
                    TerminalRowText(row: 2, text: "aaaabbbb", isWrapped: false),
                    TerminalRowText(row: 3, text: "   ", isWrapped: false),
                    TerminalRowText(row: 4, text: "", isWrapped: false)]
        #expect(TerminalText.joined(rows) == "$ echo aaaabbbb\naaaabbbb")
    }

    private func screen(_ lines: [String], wrapped: Set<Int> = []) -> [TerminalRowText] {
        lines.enumerated().map { TerminalRowText(row: 100 + $0.offset, text: $0.element, isWrapped: wrapped.contains($0.offset)) }
    }

    @Test func lastOutputIsBetweenTheLastCommandAndThePrompt() {
        let rows = screen(["$ ls", "a.txt", "b.txt", "$ echo hi", "hi", "$ "])
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [100, 103], cursorRow: 105) == "hi")
        // A command row below the cursor (the screen was cleared since) doesn't count
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [100, 103, 130], cursorRow: 105) == "hi")
    }

    @Test func aCommandWithoutOutputIsSkipped() {
        let rows = screen(["$ ls", "a.txt", "b.txt", "$ cd /tmp", "$ "])
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [100, 103], cursorRow: 104) == "a.txt\nb.txt")
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [103], cursorRow: 104) == nil)
    }

    @Test func aWrappedCommandLineIsNotOutput() {
        // Row 103 continues the command typed on row 102; Return was pressed on 103.
        let rows = screen(["$ cat x", "x", "$ a very long comma", "nd", "out", "$ "], wrapped: [3])
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [100, 103], cursorRow: 105) == "out")
        #expect(TerminalText.lastOutput(rows: rows, commandRows: [100, 103], cursorRow: 104) == "x")
    }

    @Test func fontSizesStayInRange() {
        #expect(TerminalFontSize.clamped(3) == 8)
        #expect(TerminalFontSize.clamped(13.4) == 13)
        #expect(TerminalFontSize.clamped(40) == 28)
    }
}

/// The terminal view with SwiftTerm: what reaches the program when keys and the key bar's modifiers are used.
@MainActor
struct TerminalViewInputTests {
    private final class Capture: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
    }

    private func make() -> (AOSTerminalView, Capture) {
        let view = AOSTerminalView(fontSize: 13)
        let capture = Capture()
        view.terminalDelegate = capture
        return (view, capture)
    }

    @Test func aStickyControlAppliesToTheNextLetterOnly() {
        let (view, capture) = make()
        view.pressModifier(.control)
        _ = view.releaseModifier(.control, cancelled: false)
        view.insertText("c")
        view.insertText("c")
        #expect(capture.sent == [0x03, UInt8(ascii: "c")])
    }

    @Test func aLockedModifierStaysForEveryKey() async throws {
        let (view, capture) = make()
        view.pressModifier(.alt)
        _ = view.releaseModifier(.alt, cancelled: false)
        view.pressModifier(.alt)
        #expect(view.releaseModifier(.alt, cancelled: false) == .locked)
        view.insertText("b")
        view.sendKey(.left)
        #expect(capture.sent == [0x1b, UInt8(ascii: "b")] + Array("\u{1b}[1;3D".utf8))
    }

    @Test func keyBarArrowsFollowTheApplicationCursorMode() {
        let (view, capture) = make()
        view.sendKey(.up)
        view.feed(text: "\u{1b}[?1h")
        view.sendKey(.up)
        view.sendKey(.tab, extra: .shift)
        #expect(capture.sent == Array("\u{1b}[A\u{1b}OA\u{1b}[Z".utf8))
    }

    @Test func modifiersApplyToBackspace() {
        let (view, capture) = make()
        view.pressModifier(.control)
        _ = view.releaseModifier(.control, cancelled: false)
        view.deleteBackward()
        #expect(capture.sent == [0x08])
    }

    @Test func theScreenCopiesAsText() {
        let (view, _) = make()
        view.feed(text: "one\r\ntwo   \r\n\r\n")
        #expect(view.screenText() == "one\ntwo")
    }

    @Test func selectingAWordAndExtendingIt() throws {
        let (view, _) = make()
        view.feed(text: "echo hello world\r\nsecond line here\r\n")
        #expect(view.selectWord(at: view.point(column: 7, row: 0)))
        #expect(view.getSelection() == "hello")
        #expect(view.hasTextSelection)
        // Dragging on after the long press, to the "w" of "world"
        view.extendSelection(to: view.point(column: 11, row: 0))
        #expect(view.getSelection() == "hello w")
        // Back before the word: from there to the end of the word
        view.extendSelection(to: view.point(column: 2, row: 0))
        #expect(view.getSelection() == "ho hello")
        // Over two rows
        view.extendSelection(to: view.point(column: 5, row: 1))
        #expect(view.getSelection() == "hello world\nsecond")
    }

    @Test func handlesMoveOneEnd() throws {
        let (view, _) = make()
        view.feed(text: "alpha beta gamma\r\n")
        view.selectWord(at: view.point(column: 7, row: 0))
        #expect(view.getSelection() == "beta")
        // The end handle, dragged to the end of "gamma"
        let end = view.point(column: 10, row: 0)
        view.beginHandleDrag(false, touch: end)
        view.dragHandle(to: view.point(column: 16, row: 0))
        #expect(view.getSelection() == "beta gamma")
        // The start handle, dragged to the start of the row
        view.beginHandleDrag(true, touch: view.point(column: 6, row: 0))
        view.dragHandle(to: view.point(column: 0, row: 0))
        #expect(view.getSelection() == "alpha beta gamma")
    }

    @Test func aLinkIsSelectedWhole() {
        let (view, _) = make()
        view.feed(text: "see https://example.com/path?q=1 ok\r\n")
        view.selectWord(at: view.point(column: 14, row: 0))
        #expect(view.getSelection() == "https://example.com/path?q=1")
    }

    @Test func copyPutsTheSelectionOnTheClipboardAndEndsIt() {
        let (view, _) = make()
        view.feed(text: "copy me please\r\n")
        view.selectLine(at: view.point(column: 3, row: 0))
        view.copySelection()
        #expect(UIPasteboard.general.string == "copy me please")
        #expect(!view.hasTextSelection)
        #expect(!view.selectionActive)
    }

    @Test func aBlankSelectsNothing() {
        let (view, _) = make()
        view.feed(text: "word\r\n")
        #expect(!view.selectWord(at: view.point(column: 20, row: 3)))
        #expect(!view.hasTextSelection)
    }

    @Test func typingEndsTheSelection() {
        let (view, capture) = make()
        view.feed(text: "some text\r\n")
        view.selectWord(at: view.point(column: 1, row: 0))
        view.insertText("x")
        #expect(!view.hasTextSelection)
        #expect(capture.sent == [UInt8(ascii: "x")])
    }

    @Test func lastOutputFollowsReturn() async throws {
        let (view, _) = make()
        view.feed(text: "$ ls")
        view.noteReturnSent()
        try await Task.sleep(for: .milliseconds(50))
        view.feed(text: "\r\na.txt\r\nb.txt\r\n$ ")
        #expect(view.lastOutputText() == "a.txt\nb.txt")
    }

    @Test func theKeyBarLaysOutNarrowAndWide() {
        let (view, _) = make()
        let bar = view.keyBar
        func identifiers(width: CGFloat) -> Set<String> {
            bar.frame = CGRect(x: 0, y: 0, width: width, height: TerminalKeyBar.height)
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
            var found: Set<String> = []
            func walk(_ v: UIView) {
                if let control = v as? UIControl, let id = control.accessibilityIdentifier, control.bounds.height >= 44 { found.insert(id) }
                v.subviews.forEach(walk)
            }
            walk(bar)
            return found
        }
        for width: CGFloat in [375, 402, 874] {
            let found = identifiers(width: width)
            for name in ["escape", "ctrl", "alt", "tab", "tab+1", "up", "arrowPad", "function(12)", "text(\"|\")", "text(\"~\")"] {
                #expect(found.contains(name), "\(name) at \(width) pt")
            }
        }
    }

    @Test func pasteAsksFirstOnlyWhenLinesWouldRun() {
        let session = TerminalSession(id: .host(UUID()), title: "test")
        session.paste("ls\npwd")
        #expect(session.pendingPaste == "ls\npwd")
        session.pendingPaste = nil
        session.view.feed(text: "\u{1b}[?2004h")
        session.paste("ls\npwd")
        #expect(session.pendingPaste == nil)
        session.paste("one line")
        #expect(session.pendingPaste == nil)
    }
}
