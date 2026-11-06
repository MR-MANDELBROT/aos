import SwiftTerm
import UIKit

/// What the terminal view asks of its session.
@MainActor
protocol TerminalInteractionDelegate: AnyObject {
    /// Text to paste: from the edit menu, the key bar's paste key or Command-V.
    func terminalPaste(_ text: String)
    /// A short confirmation, such as "Copied".
    func terminalNotice(_ text: String)
    /// The font size changed by pinching or a key command; `done` once the gesture ended.
    func terminalFontSizeChanged(_ size: CGFloat, done: Bool)
    func terminalFocusChanged(_ focused: Bool)
}

/// SwiftTerm's terminal view with this app's touch handling. SwiftTerm's own long press, taps and selection pan are
/// replaced: a long press selects a word (or a web address) and dragging extends it, handles adjust it without the
/// terminal scrolling instead, the system edit menu copies and pastes, and a pinch changes the font size. The key
/// bar's sticky modifiers apply to the on-screen keyboard too. Selection itself stays SwiftTerm's (drawing, text).
final class AOSTerminalView: TerminalView {
    weak var interaction: TerminalInteractionDelegate?
    private(set) var modifiers = StickyModifiers()
    private(set) lazy var keyBar = TerminalKeyBar(terminal: self)

    /// The selection as this view knows it: buffer rows (as SwiftTerm's selection uses them), start inclusive, end
    /// exclusive. `end.col` may be the column count (up to the end of the row).
    private var selected: (start: Position, end: Position)?
    /// The word a long press began with; dragging extends from it.
    private var anchor: (start: Position, end: Position)?
    private let startHandle = SelectionHandle(kind: .start)
    private let endHandle = SelectionHandle(kind: .end)
    /// The other end while a handle is dragged, and where the finger is relative to the handle's caret.
    private var dragFixed: Position?
    private var dragOffset: CGPoint = .zero
    private var editMenu: UIEditMenuInteraction!
    private var menuVisible = false
    private var loupe: UITextLoupeSession?
    private var autoScrollTask: Task<Void, Never>?
    private var autoScrollDirection = 0
    private var pinch: UIPinchGestureRecognizer!
    private var pinchStartSize: CGFloat = TerminalFontSize.standard
    /// Rows (SwiftTerm's scroll invariant numbers) where Return was pressed at the shell, for "Copy last output".
    private var commandRows: [Int] = []
    private let selectionFeedback = UISelectionFeedbackGenerator()

    init(fontSize: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 600), font: Self.font(size: fontSize))
        optionAsMetaKey = false
        inputAccessoryView = keyBar
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        selectionHandleColor = .clear
        selectedTextBackgroundColor = KeyColors.accent.withAlphaComponent(0.32)
        selectedTextForegroundColor = .label
        applyColors()
        replaceGestures()
        editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
            addSubview(handle)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AOSTerminalView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func font(size: CGFloat) -> UIFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// SwiftTerm takes the colors as values; set them again for light and dark.
    private func applyColors() {
        nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
        nativeForegroundColor = UIColor.label.resolvedColor(with: traitCollection)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyColors() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { interaction?.terminalFocusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            interaction?.terminalFocusChanged(false)
            modifiers.reset()
            keyBar.show(modifiers)
        }
        return resigned
    }

    override func layoutSubviews() {
        let before = terminalDimensions
        super.layoutSubviews()
        if terminalDimensions != before { sizeDidChange() }
        placeHandles()
    }

    /// After a rotation or a new font size the rows are laid out again: positions no longer fit.
    private func sizeDidChange() {
        clearTextSelection()
        commandRows.removeAll()
    }

    override var contentOffset: CGPoint {
        didSet {
            if menuVisible, isTracking { editMenu?.dismissMenu() }
        }
    }

    // MARK: Gestures

    private func replaceGestures() {
        for recognizer in gestureRecognizers ?? []
        where type(of: recognizer) == UILongPressGestureRecognizer.self || type(of: recognizer) == UITapGestureRecognizer.self {
            removeGestureRecognizer(recognizer)
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(tripleTapped(_:)))
        tripleTap.numberOfTapsRequired = 3
        addGestureRecognizer(tripleTap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.require(toFail: tripleTap)
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
    }

    /// A touch on a selection handle belongs to the handle: the terminal neither scrolls nor starts another selection.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer.view === self, recognizer !== pinch, selected != nil {
            let point = recognizer.location(in: self)
            for handle in [startHandle, endHandle] where !handle.isHidden && handle.frame.insetBy(dx: -6, dy: -6).contains(point) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if menuVisible {
            editMenu.dismissMenu()
            if selected == nil { return }
        }
        if selected != nil {
            clearTextSelection()
            return
        }
        // A program that reads the mouse (vim, htop, tmux) gets the click.
        if allowMouseReporting, forwardTap(at: point) { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
            return
        }
        // At the cursor, as in a text field: the menu with Paste.
        let caret = caretFrame
        if !caret.isEmpty, abs(point.x - caret.midX) < caret.width * 4, abs(point.y - caret.midY) < caret.height * 1.5 {
            showMenu(at: point)
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard selectWord(at: recognizer.location(in: self)) else { return }
        selectionFeedback.selectionChanged()
        showMenu(at: recognizer.location(in: self))
    }

    @objc private func tripleTapped(_ recognizer: UITapGestureRecognizer) {
        selectLine(at: recognizer.location(in: self))
        selectionFeedback.selectionChanged()
        showMenu(at: recognizer.location(in: self))
    }

    /// Selects the word or web address at a point; dragging on extends from it (`extendSelection(to:)`). False on
    /// a blank (nothing selected, but a drag from there selects).
    @discardableResult
    func selectWord(at point: CGPoint) -> Bool {
        guard let cell = cell(at: point) else { return false }
        clearTextSelection()
        let word = wordOrLink(at: cell)
        anchor = word ?? (cell, cell)
        if let word { setTextSelection(word) }
        return word != nil
    }

    /// The whole line at a point, also where it wrapped over several rows.
    func selectLine(at point: CGPoint) {
        guard let cell = cell(at: point), let rows = buffer() else { return }
        var first = cell.row, last = cell.row
        while first > 0, rows.isWrapped(first) { first -= 1 }
        while rows.isWrapped(last + 1) { last += 1 }
        setTextSelection((Position(col: 0, row: first), Position(col: columns, row: last)))
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            editMenu.dismissMenu()
            selectWord(at: point)
            selectionFeedback.selectionChanged()
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
        case .changed:
            loupe?.move(to: point, withCaretRect: .null, trackingCaret: false)
            extendSelection(to: point)
            autoScroll(for: recognizer) { [weak self] point in self?.extendSelection(to: point) }
        case .ended, .cancelled, .failed:
            stopAutoScroll()
            loupe?.invalidate()
            loupe = nil
            anchor = nil
            if recognizer.state == .ended { showMenu(at: point) }
        default:
            break
        }
    }

    /// Extends the selection from the word a long press began on to the character at a point.
    func extendSelection(to point: CGPoint) {
        guard let anchor, let cell = cell(at: point) else { return }
        let previous = selected
        if cell < anchor.start {
            setTextSelection((cell, anchor.end))
        } else if cell >= anchor.end {
            setTextSelection((anchor.start, Position(col: cell.col + 1, row: cell.row)))
        } else if anchor.start < anchor.end {
            setTextSelection(anchor)
        } else if selected != nil {
            // Back on the blank the press began on: nothing selected.
            selected = nil
            clearSelection()
            placeHandles()
        }
        if let previous, let selected, previous != selected { selectionFeedback.selectionChanged() }
    }

    @objc private func handleDragged(_ recognizer: UIPanGestureRecognizer) {
        guard let handle = recognizer.view as? SelectionHandle else { return }
        switch recognizer.state {
        case .began:
            guard selected != nil else { return }
            editMenu.dismissMenu()
            let touch = recognizer.location(in: self)
            beginHandleDrag(handle.kind == .start, touch: touch)
            loupe = UITextLoupeSession.begin(at: touch, fromSelectionWidgetView: handle, in: self)
        case .changed:
            let touch = recognizer.location(in: self)
            loupe?.move(to: touch, withCaretRect: .null, trackingCaret: false)
            dragHandle(to: touch)
            autoScroll(for: recognizer) { [weak self] point in self?.dragHandle(to: point) }
        default:
            stopAutoScroll()
            loupe?.invalidate()
            loupe = nil
            dragFixed = nil
            if let selected {
                let area = rect(for: selected)
                showMenu(at: CGPoint(x: area.midX, y: area.minY))
            }
        }
    }

    /// A handle drag begins: the other end stays, the handle follows the finger at the distance it was touched.
    func beginHandleDrag(_ start: Bool, touch: CGPoint) {
        guard let selected else { return }
        dragFixed = start ? selected.end : selected.start
        let caret = (start ? startHandle : endHandle).caretPoint
        dragOffset = CGPoint(x: caret.x - touch.x, y: caret.y - touch.y)
    }

    func dragHandle(to touch: CGPoint) {
        guard let fixed = dragFixed else { return }
        let caret = CGPoint(x: touch.x + dragOffset.x, y: touch.y + dragOffset.y)
        guard var moving = boundary(at: caret) else { return }
        // Never empty: at least the character next to the other end.
        if moving == fixed { moving = moving.col < columns ? Position(col: moving.col + 1, row: moving.row) : moving }
        let previous = selected
        setTextSelection(moving < fixed ? (moving, fixed) : (fixed, moving))
        if let previous, let selected, previous != selected { selectionFeedback.selectionChanged() }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartSize = font.pointSize
            editMenu.dismissMenu()
        case .changed:
            let size = TerminalFontSize.clamped(pinchStartSize * recognizer.scale)
            if size != font.pointSize {
                setFontSize(size)
                selectionFeedback.selectionChanged()
                interaction?.terminalFontSizeChanged(size, done: false)
            }
        case .ended, .cancelled:
            interaction?.terminalFontSizeChanged(font.pointSize, done: true)
        default:
            break
        }
    }

    // MARK: Scrolling while selecting

    /// Near the top or bottom edge a selection drag scrolls the terminal, a line at a time.
    private func autoScroll(for recognizer: UIGestureRecognizer, apply: @escaping @MainActor (CGPoint) -> Void) {
        let y = recognizer.location(in: self).y - contentOffset.y
        let direction = y < 28 ? -1 : (y > bounds.height - 28 ? 1 : 0)
        guard direction != autoScrollDirection else { return }
        stopAutoScroll()
        guard direction != 0 else { return }
        autoScrollDirection = direction
        autoScrollTask = Task { @MainActor [weak self, weak recognizer] in
            while !Task.isCancelled, let self, let recognizer {
                if direction < 0 { self.scrollUp(lines: 1) } else { self.scrollDown(lines: 1) }
                apply(recognizer.location(in: self))
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollDirection = 0
    }

    // MARK: Cells

    /// The middle of a cell, in the view's coordinates.
    func point(column: Int, row: Int) -> CGPoint {
        let size = cellSize
        return CGPoint(x: (CGFloat(column) + 0.5) * size.width, y: (CGFloat(row) + 0.5) * size.height)
    }

    private var columns: Int { max(terminalDimensions.cols, 1) }

    private var cellSize: CGSize {
        let dimensions = terminalDimensions
        let frame = getOptimalFrameSize()
        return CGSize(width: frame.width / CGFloat(max(dimensions.cols, 1)), height: frame.height / CGFloat(max(dimensions.rows, 1)))
    }

    /// Rows of the scrollback and the screen (the scroll view's content; at least the screen, which SwiftTerm's
    /// content size can lag behind until the next frame).
    private var lineCount: Int {
        let height = cellSize.height
        let content = height > 0 ? Int((contentSize.height / height).rounded()) : 0
        return max(content, terminalDimensions.rows, 1)
    }

    /// The cell under a point of the view (its coordinates include the scroll offset, rows count from the top of
    /// the scrollback, as SwiftTerm's own touch handling counts them).
    private func cell(at point: CGPoint) -> Position? {
        let size = cellSize
        guard size.width > 0, size.height > 0 else { return nil }
        let col = min(max(Int(point.x / size.width), 0), columns - 1)
        let row = min(max(Int(point.y / size.height), 0), lineCount - 1)
        return Position(col: col, row: row)
    }

    /// The gap between cells nearest to a point: where a handle goes.
    private func boundary(at point: CGPoint) -> Position? {
        let size = cellSize
        guard size.width > 0, size.height > 0 else { return nil }
        let col = min(max(Int((point.x / size.width).rounded()), 0), columns)
        let row = min(max(Int(point.y / size.height), 0), lineCount - 1)
        return Position(col: col, row: row)
    }

    /// The word or web address at a cell, as a range; nil on a blank.
    private func wordOrLink(at cell: Position) -> (start: Position, end: Position)? {
        guard let rows = buffer() else { return nil }
        let cells = rows.cells(cell.row)
        guard cell.col < cells.count, !cells[cell.col].text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let range = TerminalText.linkRange(in: cells, at: cell.col)?.columns ?? TerminalText.wordRange(in: cells, at: cell.col)
        return (Position(col: range.lowerBound, row: cell.row), Position(col: range.upperBound + 1, row: cell.row))
    }

    /// The active buffer's rows with their cells, by buffer row.
    private func buffer() -> BufferRows? {
        terminalContentSnapshot(region: .history(maximumScrollbackRows: Int.max)).map(BufferRows.init)
    }

    // MARK: Selection

    var hasTextSelection: Bool { selected != nil }

    private func setTextSelection(_ range: (start: Position, end: Position)) {
        let columns = self.columns
        let start = range.start.col >= columns ? Position(col: 0, row: range.start.row + 1) : range.start
        guard start < range.end else { return }
        selected = (start, range.end)
        setSelectionRange(start: start, end: Position(col: min(range.end.col, columns - 1), row: range.end.row))
        placeHandles()
    }

    func clearTextSelection() {
        guard selected != nil || anchor != nil else { return }
        selected = nil
        anchor = nil
        if selectionActive { clearSelection() }
        placeHandles()
        if menuVisible { editMenu.dismissMenu() }
    }

    /// SwiftTerm ends a selection itself when the text under it changes.
    nonisolated override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.selected != nil, !self.selectionActive else { return }
                self.selected = nil
                self.anchor = nil
                self.placeHandles()
                if self.menuVisible { self.editMenu.dismissMenu() }
            }
        }
    }

    private func rect(for range: (start: Position, end: Position)) -> CGRect {
        let size = cellSize
        let top = CGFloat(range.start.row) * size.height
        let bottom = CGFloat(range.end.row + 1) * size.height
        if range.start.row == range.end.row {
            return CGRect(x: CGFloat(range.start.col) * size.width, y: top,
                          width: CGFloat(range.end.col - range.start.col) * size.width, height: bottom - top)
        }
        return CGRect(x: 0, y: top, width: CGFloat(columns) * size.width, height: bottom - top)
    }

    private func placeHandles() {
        guard let selected else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let size = cellSize
        startHandle.place(x: CGFloat(selected.start.col) * size.width, top: CGFloat(selected.start.row) * size.height, lineHeight: size.height)
        endHandle.place(x: CGFloat(selected.end.col) * size.width, top: CGFloat(selected.end.row) * size.height, lineHeight: size.height)
        startHandle.isHidden = false
        endHandle.isHidden = false
        bringSubviewToFront(startHandle)
        bringSubviewToFront(endHandle)
    }

    /// The selected text, if it is one web address.
    private var selectedLink: URL? {
        guard let text = getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.contains(where: \.isWhitespace),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    // MARK: Copy and paste

    func copySelection() {
        guard let text = getSelection(), !text.isEmpty else { return }
        Clipboard.copyPlain(text)
        clearTextSelection()
        interaction?.terminalNotice(String(localized: "Copied"))
    }

    override func copy(_ sender: Any?) {
        copySelection()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        interaction?.terminalPaste(text)
    }

    /// From the key bar's paste key (the system's paste control, no question asked).
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = (object as? NSString).map({ String($0) }), !text.isEmpty else { return }
            Task { @MainActor in self?.interaction?.terminalPaste(text) }
        }
    }

    override func selectAll(_ sender: Any?) {
        guard let rows = buffer(), let last = rows.lastRowWithText else { return }
        setTextSelection((Position(col: 0, row: 0), Position(col: columns, row: last)))
        showMenu(at: CGPoint(x: bounds.midX, y: contentOffset.y + bounds.height / 3))
    }

    /// The screen as text (what is visible, also when scrolled back).
    func screenText() -> String {
        guard let snapshot = terminalContentSnapshot(region: .viewport) else { return "" }
        return TerminalText.joined(snapshot.rows.map(TerminalRowText.init))
    }

    /// The output of the last command (see `TerminalText.lastOutput`).
    func lastOutputText() -> String? {
        guard !commandRows.isEmpty,
              let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: Int.max), buffer: .normal) else { return nil }
        return TerminalText.lastOutput(rows: snapshot.rows.map(TerminalRowText.init), commandRows: commandRows,
                                       cursorRow: snapshot.cursorRow)
    }

    /// Return went to the shell: remember the row (after the current input is processed, outside SwiftTerm's lock).
    func noteReturnSent() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let snapshot = self.terminalContentSnapshot(region: .viewport),
                      !snapshot.inputState.isAlternateBuffer else { return }
                if self.commandRows.last != snapshot.cursorRow { self.commandRows.append(snapshot.cursorRow) }
                if self.commandRows.count > 200 { self.commandRows.removeFirst(self.commandRows.count - 200) }
            }
        }
    }

    // MARK: Edit menu

    func showMenu(at point: CGPoint) {
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    // MARK: Keys

    /// A key from the key bar, with the modifiers that are on.
    func sendKey(_ key: TerminalKey, extra: TerminalModifiers = []) {
        let active = modifiers.active
        let applicationCursor = terminalInputStateSnapshot()?.applicationCursor ?? false
        send(TerminalKeyEncoder.bytes(for: key, modifiers: active.union(extra), applicationCursor: applicationCursor))
        if !active.isEmpty {
            modifiers.consume()
            keyBar.show(modifiers)
        }
        if selected != nil { clearTextSelection() }
    }

    func pressModifier(_ modifier: TerminalModifiers) {
        modifiers.press(modifier)
        keyBar.show(modifiers)
    }

    func releaseModifier(_ modifier: TerminalModifiers, cancelled: Bool) -> StickyModifiers.State {
        let state = modifiers.release(modifier, at: CACurrentMediaTime(), cancelled: cancelled)
        keyBar.show(modifiers)
        return state
    }

    /// The on-screen keyboard (and a hardware keyboard's text): the key bar's modifiers apply to it.
    override func insertText(_ text: String) {
        if selected != nil { clearTextSelection() }
        let active = modifiers.active
        guard !active.isEmpty, !text.isEmpty else {
            super.insertText(text)
            return
        }
        // A program that turned on the kitty keyboard protocol gets Control from SwiftTerm, in its encoding.
        if active == .control, !keyboardEnhancementFlags.isEmpty {
            controlModifier = true
            super.insertText(text)
            controlModifier = false
            modifiers.consume()
            keyBar.show(modifiers)
            return
        }
        sendKey(text == "\n" ? .enter : .text(text))
    }

    override func deleteBackward() {
        if selected != nil { clearTextSelection() }
        guard !modifiers.active.isEmpty else {
            super.deleteBackward()
            return
        }
        sendKey(.backspace)
    }

    // MARK: Font size

    func setFontSize(_ size: CGFloat) {
        let size = TerminalFontSize.clamped(size)
        guard size != font.pointSize else { return }
        font = Self.font(size: size)
        sizeDidChange()
    }

    #if DEBUG
    /// States for screenshots of the demo (-AOSDemoTerminal): a selection with its menu, the key bar's modifiers on,
    /// the menu at the cursor.
    func showDemoState(_ state: String) {
        switch state {
        case "selection":
            selectWord(at: point(column: 27, row: 2))
            extendSelection(to: point(column: 31, row: 3))
            if let selected { showMenu(at: CGPoint(x: rect(for: selected).midX, y: rect(for: selected).minY)) }
        case "keys":
            pressModifier(.control)
            _ = releaseModifier(.control, cancelled: false)
            pressModifier(.alt)
            _ = releaseModifier(.alt, cancelled: false)
            pressModifier(.alt)
            _ = releaseModifier(.alt, cancelled: false)
        case "menu":
            showMenu(at: CGPoint(x: caretFrame.midX, y: caretFrame.midY))
        default:
            break
        }
    }
    #endif

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: String(localized: "Bigger Text"), action: #selector(biggerText), input: "+", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Bigger Text"), action: #selector(biggerText), input: "=", modifierFlags: .command,
                         attributes: .hidden),
            UIKeyCommand(title: String(localized: "Smaller Text"), action: #selector(smallerText), input: "-", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Default Text Size"), action: #selector(defaultText), input: "0", modifierFlags: .command),
            UIKeyCommand(title: String(localized: "Clear Scrollback"), action: #selector(clearHistory), input: "k", modifierFlags: .command),
        ]
    }

    @objc private func biggerText() { changeFontSize(by: 1) }
    @objc private func smallerText() { changeFontSize(by: -1) }
    @objc private func defaultText() { changeFontSize(to: TerminalFontSize.standard) }

    private func changeFontSize(by step: CGFloat) { changeFontSize(to: font.pointSize + step) }

    private func changeFontSize(to size: CGFloat) {
        setFontSize(size)
        interaction?.terminalFontSizeChanged(font.pointSize, done: true)
    }

    /// Command-K as in Terminal.app: the scrollback goes, the shell draws its prompt again at the top.
    @objc private func clearHistory() {
        clearTextSelection()
        clearScrollback()
        commandRows.removeAll()
        send([0x0c])
    }
}

// MARK: - Edit menu

extension AOSTerminalView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if selected != nil {
            items.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
            if let url = selectedLink {
                items.append(UIAction(title: String(localized: "Open Link"), image: UIImage(systemName: "safari")) { [weak self] _ in
                    guard let self else { return }
                    self.clearTextSelection()
                    self.terminalDelegate?.requestOpenLink(source: self, link: url.absoluteString, params: [:])
                })
            }
        }
        // The system's own Paste command reads the clipboard without asking; a custom action would ask every time.
        if let paste = Self.command(#selector(UIResponderStandardEditActions.paste(_:)), in: suggestedActions) {
            items.append(paste)
        } else if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(nil)
            })
        }
        if selected == nil {
            items.append(UIAction(title: String(localized: "Select All")) { [weak self] _ in self?.selectAll(nil) })
            items.append(UIAction(title: String(localized: "Copy Screen")) { [weak self] _ in
                guard let self else { return }
                Clipboard.copyPlain(self.screenText())
                self.interaction?.terminalNotice(String(localized: "Screen copied"))
            })
            if let output = lastOutputText() {
                items.append(UIAction(title: String(localized: "Copy Last Output")) { [weak self] _ in
                    Clipboard.copyPlain(output)
                    self?.interaction?.terminalNotice(String(localized: "Output copied"))
                })
            }
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        // The visible part of the selection (Select All reaches far above the screen).
        if let selected, case let visible = rect(for: selected).intersection(bounds), !visible.isNull { return visible }
        let size = cellSize
        return CGRect(x: configuration.sourcePoint.x - size.width / 2, y: configuration.sourcePoint.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = false
    }

    private static func command(_ action: Selector, in elements: [UIMenuElement]) -> UIMenuElement? {
        for element in elements {
            if let command = element as? UICommand, command.action == action { return command }
            if let menu = element as? UIMenu, let found = command(action, in: menu.children) { return found }
        }
        return nil
    }
}

// MARK: - Helpers

extension Position: @retroactive Comparable {
    /// Reading order: row first, then column.
    public static func < (a: Position, b: Position) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }
}

extension TerminalRowText {
    /// A row of a SwiftTerm snapshot, with its cells as they are (not trimmed, so wrapped lines join right).
    init(_ row: TerminalContentRowSnapshot) {
        self.init(row: row.absoluteRow, text: TerminalText.layout(row.cells.map { TextCell($0.text, width: $0.width) }).string,
                  isWrapped: row.isWrapped)
    }
}

/// A snapshot of the active buffer, by buffer row (the first row of the snapshot is buffer row 0).
private struct BufferRows {
    let snapshot: TerminalContentSnapshot

    init(_ snapshot: TerminalContentSnapshot) { self.snapshot = snapshot }

    func cells(_ row: Int) -> [TextCell] {
        guard row >= 0, row < snapshot.rows.count else { return [] }
        return snapshot.rows[row].cells.map { TextCell($0.text, width: $0.width) }
    }

    func isWrapped(_ row: Int) -> Bool { row >= 0 && row < snapshot.rows.count && snapshot.rows[row].isWrapped }

    var lastRowWithText: Int? {
        snapshot.rows.lastIndex { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// A selection handle: a bar the height of a line with a knob above (start) or below (end), in a 44 pt wide view
/// that takes the touches.
private final class SelectionHandle: UIView {
    enum Kind { case start, end }
    let kind: Kind
    private let bar = UIView()
    private let knob = UIView()
    private static let knobSize: CGFloat = 12
    private static let reach: CGFloat = 18
    private var lineHeight: CGFloat = 16

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        for part in [bar, knob] {
            part.backgroundColor = KeyColors.accent
            part.isUserInteractionEnabled = false
            addSubview(part)
        }
        bar.layer.cornerRadius = 1
        knob.layer.cornerRadius = Self.knobSize / 2
        isAccessibilityElement = true
        accessibilityLabel = kind == .start ? String(localized: "Start of selection") : String(localized: "End of selection")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The point on the line between the cells where the handle sits (its middle), in the terminal's coordinates.
    var caretPoint: CGPoint { CGPoint(x: frame.midX, y: kind == .start ? frame.maxY - lineHeight / 2 : frame.minY + lineHeight / 2) }

    func place(x: CGFloat, top: CGFloat, lineHeight: CGFloat) {
        self.lineHeight = lineHeight
        let width: CGFloat = 44
        let height = lineHeight + Self.reach
        frame = CGRect(x: x - width / 2, y: kind == .start ? top - Self.reach : top, width: width, height: height)
        let barTop: CGFloat = kind == .start ? Self.reach - Self.knobSize / 2 : 0
        bar.frame = CGRect(x: width / 2 - 1, y: barTop, width: 2, height: lineHeight + Self.knobSize / 2)
        knob.frame = CGRect(x: (width - Self.knobSize) / 2, y: kind == .start ? barTop - Self.knobSize + 2 : height - Self.knobSize - 2,
                            width: Self.knobSize, height: Self.knobSize)
    }
}
