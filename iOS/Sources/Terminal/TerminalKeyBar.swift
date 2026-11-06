import UIKit

/// The keys above the keyboard: Esc, Control, Option and Tab always in reach, a scrolling row with paste, arrows,
/// the symbols a shell needs, navigation and function keys, and a swipe pad for the arrows. Modifiers stick for the
/// next key (tap), lock (double tap) or work while held. A glass panel like the rest of the app, 44 pt keys.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    static let height: CGFloat = 58
    /// From this width on (landscape, iPad) the arrows and Option get fixed places too.
    static let wideWidth: CGFloat = 520

    weak var terminal: AOSTerminalView?

    private let panel = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let leading = UIStackView()
    private let trailing = UIStackView()
    private let scroll = KeyScrollView()
    private let scrollRow = UIStackView()
    private let fade = CAGradientLayer()
    private var modifierKeys: [Int: KeyButton] = [:]
    private var isWide: Bool?
    private var repeatTask: Task<Void, Never>?
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let modifierFeedback = UISelectionFeedbackGenerator()
    private let lockFeedback = UIImpactFeedbackGenerator(style: .medium)

    var enableInputClicksWhenVisible: Bool { true }

    init(terminal: AOSTerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        autoresizingMask = .flexibleHeight

        panel.cornerConfiguration = .corners(radius: .fixed(16))
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        for stack in [leading, trailing, scrollRow] {
            stack.axis = .horizontal
            stack.alignment = .fill
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(scrollRow)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.layer.mask = fade
        scroll.delegate = self
        scroll.onLayout = { [weak self] in self?.updateFade() }

        let content = panel.contentView
        content.addSubview(leading)
        content.addSubview(scroll)
        content.addSubview(trailing)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            leading.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leading.topAnchor.constraint(equalTo: content.topAnchor),
            leading.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            trailing.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            trailing.topAnchor.constraint(equalTo: content.topAnchor),
            trailing.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leading.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollRow.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scrollRow.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scrollRow.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scrollRow.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scrollRow.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        accessibilityLabel = String(localized: "Terminal keys")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    override func layoutSubviews() {
        let wide = bounds.width >= Self.wideWidth
        if wide != isWide {
            isWide = wide
            rebuild(wide: wide)
        }
        super.layoutSubviews()
        updateFade()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeat() } else { tapFeedback.prepare() }
    }

    // MARK: Keys

    private enum Item {
        case key(TerminalKey, Label, extra: TerminalModifiers = [], repeats: Bool = false, width: CGFloat = 44)
        case modifier(TerminalModifiers)
        case paste
        case pad
    }

    enum Label {
        case text(String)
        case symbol(String)
    }

    private static let symbols = ["~", "/", "|", "-", "_", "\\", "`", "*", "$", "&", ">", "<", "=", ":", ";", "'", "\"",
                                  "!", "?", "#", "%", "^", "@", "{", "}", "[", "]", "(", ")"]

    private static func arrow(_ key: TerminalKey, _ symbol: String) -> Item {
        .key(key, .symbol(symbol), repeats: true)
    }

    private static let arrows: [Item] = [arrow(.left, "arrow.left"), arrow(.down, "arrow.down"),
                                         arrow(.up, "arrow.up"), arrow(.right, "arrow.right")]

    /// Everything after the symbols: navigation and the function keys.
    private static let navigation: [Item] = [
        .key(.home, .text("home"), width: 54), .key(.end, .text("end"), width: 50),
        .key(.pageUp, .text("pg↑"), repeats: true, width: 50), .key(.pageDown, .text("pg↓"), repeats: true, width: 50),
        .key(.forwardDelete, .text("del"), repeats: true, width: 50),
    ] + (1...12).map { .key(.function($0), .text("F\($0)"), width: $0 >= 10 ? 48 : 44) }

    private func items(wide: Bool) -> (leading: [Item], scrolling: [Item], trailing: [Item]) {
        let escape = Item.key(.escape, .text("esc"), width: 52)
        let tab = Item.key(.tab, .text("tab"), width: 52)
        let shiftTab = Item.key(.tab, .text("⇧tab"), extra: .shift, width: 60)
        let symbols = Self.symbols.map { Item.key(.text($0), .text($0), width: 40) }
        if wide {
            return ([escape, .modifier(.control), .modifier(.alt), tab],
                    [.paste, shiftTab] + symbols + Self.navigation,
                    Self.arrows + [.pad])
        }
        return ([escape, .modifier(.control), tab],
                [.modifier(.alt), .paste, shiftTab] + Self.arrows + symbols + Self.navigation,
                [.pad])
    }

    private func rebuild(wide: Bool) {
        stopRepeat()
        for stack in [leading, scrollRow, trailing] {
            for view in stack.arrangedSubviews { view.removeFromSuperview() }
        }
        modifierKeys = [:]
        let (first, middle, last) = items(wide: wide)
        for item in first { leading.addArrangedSubview(view(for: item)) }
        for item in middle { scrollRow.addArrangedSubview(view(for: item)) }
        for item in last { trailing.addArrangedSubview(view(for: item)) }
        if let modifiers = terminal?.modifiers { show(modifiers) }
    }

    private func view(for item: Item) -> UIView {
        switch item {
        case .key(let key, let label, let extra, let repeats, let width):
            let button = KeyButton(label: label, width: width)
            if let name = Self.accessibilityName(key, extra: extra) { button.accessibilityLabel = name }
            button.accessibilityIdentifier = extra.isEmpty ? "\(key)" : "\(key)+\(extra.rawValue)"
            if repeats {
                button.addAction(UIAction { [weak self] _ in self?.keyDown() }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in self?.startRepeat { self?.send(key, extra) } }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if !self.stopRepeat() { self.send(key, extra) }
                }, for: .touchUpInside)
                button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: [.touchUpOutside, .touchCancel])
            } else {
                button.addAction(UIAction { [weak self] _ in self?.keyDown() }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in self?.send(key, extra) }, for: .touchUpInside)
            }
            return button
        case .modifier(let modifier):
            let button = KeyButton(label: .text(Self.modifierTitle(modifier)), width: 54)
            button.accessibilityLabel = Self.modifierName(modifier)
            button.accessibilityIdentifier = Self.modifierTitle(modifier)
            button.accessibilityHint = String(localized: "Double tap to keep it on")
            button.addAction(UIAction { [weak self] _ in self?.terminal?.pressModifier(modifier) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.releaseModifier(modifier, cancelled: false) },
                             for: [.touchUpInside, .touchUpOutside])
            button.addAction(UIAction { [weak self] _ in self?.releaseModifier(modifier, cancelled: true) }, for: .touchCancel)
            modifierKeys[modifier.rawValue] = button
            return button
        case .paste:
            return PasteKey(target: terminal)
        case .pad:
            let pad = ArrowPadControl()
            pad.accessibilityIdentifier = "arrowPad"
            pad.onArrow = { [weak self] key in
                self?.modifierFeedback.selectionChanged()
                self?.send(key, [])
            }
            return pad
        }
    }

    private func keyDown() {
        tapFeedback.impactOccurred(intensity: 0.7)
        tapFeedback.prepare()
    }

    private func send(_ key: TerminalKey, _ extra: TerminalModifiers) {
        UIDevice.current.playInputClick()
        terminal?.sendKey(key, extra: extra)
    }

    private func releaseModifier(_ modifier: TerminalModifiers, cancelled: Bool) {
        guard let state = terminal?.releaseModifier(modifier, cancelled: cancelled), !cancelled else { return }
        UIDevice.current.playInputClick()
        if state == .locked {
            lockFeedback.impactOccurred()
        } else {
            modifierFeedback.selectionChanged()
        }
    }

    /// Shows which modifiers are on.
    func show(_ modifiers: StickyModifiers) {
        for (raw, button) in modifierKeys {
            let modifier = TerminalModifiers(rawValue: raw)
            button.modifierState = modifiers.state(of: modifier)
            button.accessibilityValue = switch modifiers.state(of: modifier) {
            case .off: String(localized: "Off")
            case .once: String(localized: "On for the next key")
            case .locked: String(localized: "Locked")
            }
        }
    }

    // MARK: Repeat

    /// Repeats `action` while a key is held: the first time after 0.4 s, then 14 times a second.
    private func startRepeat(_ action: @escaping @MainActor () -> Void) {
        repeatTask?.cancel()
        repeatFired = false
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                self?.repeatFired = true
                action()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private var repeatFired = false

    /// Stops repeating. True if the key repeated at least once (so lifting it sends nothing more).
    @discardableResult
    private func stopRepeat() -> Bool {
        let fired = repeatFired
        repeatTask?.cancel()
        repeatTask = nil
        repeatFired = false
        return fired
    }

    // MARK: Fading edges

    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        fade.frame = scroll.bounds
        let width = max(scroll.bounds.width, 1)
        let edge = min(18 / width, 0.2)
        let canLeft = scroll.contentOffset.x > 1
        let canRight = scroll.contentOffset.x < scroll.contentSize.width - scroll.bounds.width - 1
        let clear = UIColor.clear.cgColor, solid = UIColor.black.cgColor
        fade.colors = [canLeft ? clear : solid, solid, solid, canRight ? clear : solid]
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
    }

    // MARK: Names

    private static func modifierTitle(_ modifier: TerminalModifiers) -> String {
        switch modifier {
        case .control: "ctrl"
        case .alt: "alt"
        default: "shift"
        }
    }

    private static func modifierName(_ modifier: TerminalModifiers) -> String {
        switch modifier {
        case .control: String(localized: "Control")
        case .alt: String(localized: "Option")
        default: String(localized: "Shift")
        }
    }

    private static func accessibilityName(_ key: TerminalKey, extra: TerminalModifiers) -> String? {
        switch key {
        case .escape: String(localized: "Escape")
        case .tab: extra.contains(.shift) ? String(localized: "Shift Tab") : String(localized: "Tab")
        case .up: String(localized: "Up Arrow")
        case .down: String(localized: "Down Arrow")
        case .left: String(localized: "Left Arrow")
        case .right: String(localized: "Right Arrow")
        case .home: String(localized: "Home")
        case .end: String(localized: "End")
        case .pageUp: String(localized: "Page Up")
        case .pageDown: String(localized: "Page Down")
        case .forwardDelete: String(localized: "Delete Forward")
        case .function(let n): "F\(n)"
        case .enter, .backspace, .insert, .text: nil
        }
    }
}

extension TerminalKeyBar: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopRepeat()
    }
}

/// The scrolling row: a drag that starts on a key scrolls (and cancels the key).
private final class KeyScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The colors of the keys on the glass panel, light and dark.
enum KeyColors {
    static let plate = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07) }
    static let pressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.32) : UIColor(white: 0, alpha: 0.18) }
    static let accent = UIColor(named: "AccentColor") ?? .systemIndigo
    /// The system paste control takes opaque colors only (it stops working with translucent ones): about what a
    /// plate looks like on the panel.
    static let solidPlate = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.9, alpha: 1) }
}

/// A key: a rounded plate with a label or symbol. The control fills its share of the bar, so the touch area has no
/// gaps; the plate is inset by 3 pt.
final class KeyButton: UIControl {
    private let plate = UIView()
    private let title = UILabel()
    private let symbol = UIImageView()
    private let lockMark = UIView()
    private let width: CGFloat

    /// For modifier keys: once and locked fill the key with the accent color; locked adds a bar under the title.
    var modifierState: StickyModifiers.State = .off { didSet { refresh() } }

    init(label: TerminalKeyBar.Label, width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = 12
        plate.layer.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        switch label {
        case .text(let text):
            title.text = text
            accessibilityLabel = text
            title.font = text.count == 1 ? .monospacedSystemFont(ofSize: 19, weight: .regular)
                                         : .systemFont(ofSize: 15, weight: .medium)
            title.adjustsFontSizeToFitWidth = true
            title.minimumScaleFactor = 0.7
            title.textAlignment = .center
            title.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(title)
            NSLayoutConstraint.activate([
                title.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
                title.centerYAnchor.constraint(equalTo: plate.centerYAnchor, constant: -1),
                title.widthAnchor.constraint(lessThanOrEqualTo: plate.widthAnchor, constant: -6),
            ])
        case .symbol(let name):
            symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            symbol.contentMode = .center
            symbol.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(symbol)
            NSLayoutConstraint.activate([
                symbol.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
                symbol.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            ])
        }
        lockMark.backgroundColor = .white
        lockMark.layer.cornerRadius = 1.5
        lockMark.isHidden = true
        lockMark.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(lockMark)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            plate.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            plate.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            lockMark.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            lockMark.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -5),
            lockMark.widthAnchor.constraint(equalToConstant: 16),
            lockMark.heightAnchor.constraint(equalToConstant: 3),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: width + 6, height: 50) }

    override var isHighlighted: Bool { didSet { refresh() } }

    private func refresh() {
        let on = modifierState != .off
        let fill: UIColor = on ? KeyColors.accent : (isHighlighted ? KeyColors.pressed : KeyColors.plate)
        UIView.performWithoutAnimation {
            plate.backgroundColor = isHighlighted && on ? KeyColors.accent.withAlphaComponent(0.8) : fill
        }
        let ink: UIColor = on ? .white : .label
        title.textColor = ink
        symbol.tintColor = ink
        lockMark.isHidden = modifierState != .locked
        if on { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
    }
}

/// Paste without the "allow paste" question: the system's paste control, shaped like the other keys.
private final class PasteKey: UIView {
    init(target: UIResponder?) {
        super.init(frame: .zero)
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 12
        configuration.baseBackgroundColor = KeyColors.solidPlate
        configuration.baseForegroundColor = .label
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            control.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: 50, height: 50) }
}

/// The swipe pad: drag from it towards a direction to send arrows; the farther the drag, the faster they repeat.
/// A short flick sends one arrow.
private final class ArrowPadControl: UIControl {
    var onArrow: ((TerminalKey) -> Void)?

    private let plate = UIView()
    private let glyph = UIImageView()
    private var start: CGPoint = .zero
    private var current: TerminalKey?
    private var distance: CGFloat = 0
    private var repeatTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.isUserInteractionEnabled = false
        plate.backgroundColor = KeyColors.plate
        plate.layer.cornerRadius = 12
        plate.layer.cornerCurve = .continuous
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)
        glyph.contentMode = .center
        glyph.tintColor = .label
        glyph.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(glyph)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            plate.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            glyph.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        setGlyph(nil)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Arrow pad")
        accessibilityHint = String(localized: "Swipe up, down, left or right to send arrow keys")
        accessibilityCustomActions = [(TerminalKey.up, String(localized: "Up Arrow")), (.down, String(localized: "Down Arrow")),
                                      (.left, String(localized: "Left Arrow")), (.right, String(localized: "Right Arrow"))]
            .map { key, name in UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.onArrow?(key); return true } }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: 58, height: 50) }

    private func setGlyph(_ key: TerminalKey?) {
        let name = switch key {
        case .up: "dpad.up.filled"
        case .down: "dpad.down.filled"
        case .left: "dpad.left.filled"
        case .right: "dpad.right.filled"
        default: "dpad"
        }
        glyph.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            ?? UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        plate.backgroundColor = key == nil ? (isTracking ? KeyColors.pressed : KeyColors.plate) : KeyColors.pressed
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        start = touch.location(in: self)
        current = nil
        setGlyph(nil)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        distance = hypot(translation.width, translation.height)
        let key = ArrowPad.key(for: translation)
        if key != current {
            current = key
            setGlyph(key)
            repeatTask?.cancel()
            if let key {
                onArrow?(key)
                repeatTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    while !Task.isCancelled, let self {
                        self.onArrow?(key)
                        try? await Task.sleep(for: .seconds(ArrowPad.repeatInterval(distance: self.distance)))
                    }
                }
            }
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { finish() }
    override func cancelTracking(with event: UIEvent?) { finish() }

    private func finish() {
        repeatTask?.cancel()
        repeatTask = nil
        current = nil
        setGlyph(nil)
    }
}
