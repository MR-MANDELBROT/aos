import AnnexRFB
import SwiftUI
import UIKit

/// Shows the remote screen and turns touches into pointer input.
///
/// - Tap: left click (at the pointer in trackpad mode, at the finger in direct mode).
/// - Two-finger tap or long press: right click.
/// - One finger: moves the pointer like a trackpad, or (direct mode) drags.
/// - Two fingers: scroll. Pinch: zoom. Three fingers: move the zoomed picture.
/// When zoomed in, the picture follows the pointer.
final class RemoteScreenView: UIView, UIGestureRecognizerDelegate {
    var session: ScreenSession?
    var mode: AppSettings.InputMode = .trackpad { didSet { updatePointerVisibility() } }

    private let imageLayer = CALayer()
    private let pointerView = UIImageView(image: UIImage(systemName: "cursorarrow",
                                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)))
    private var imageSize: CGSize = .zero
    /// Zoom on top of "fit the screen": 1 shows everything.
    private var zoom: CGFloat = 1
    /// Translation of the picture's center from the view's center, in view points.
    private var pan: CGPoint = .zero

    private enum TwoFinger { case undecided, zoom, scroll }
    private var twoFinger = TwoFinger.undecided
    private var pinchStart: (zoom: CGFloat, pan: CGPoint, centroid: CGPoint)?
    private var scrollRemainder: CGPoint = .zero
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)
        pointerView.tintColor = .white
        pointerView.layer.shadowColor = UIColor.black.cgColor
        pointerView.layer.shadowOpacity = 0.8
        pointerView.layer.shadowRadius = 2
        pointerView.layer.shadowOffset = .zero
        addSubview(pointerView)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Remote screen")
        accessibilityTraits = .allowsDirectInteraction
        installGestures()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Picture

    func show(_ image: CGImage?) {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        let size = CGSize(width: image.width, height: image.height)
        if size != imageSize {
            imageSize = size
            setNeedsLayout()
        }
        CATransaction.commit()
    }

    private var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return 1 }
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private var scale: CGFloat { fitScale * zoom }

    override func layoutSubviews() {
        super.layoutSubviews()
        clampPan()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageLayer.frame = CGRect(x: bounds.midX + pan.x - size.width / 2, y: bounds.midY + pan.y - size.height / 2,
                                  width: size.width, height: size.height)
        CATransaction.commit()
        updatePointer()
    }

    /// Screen pixels for a point in the view.
    func remotePoint(_ viewPoint: CGPoint) -> CGPoint {
        let origin = imageLayer.frame.origin
        return CGPoint(x: (viewPoint.x - origin.x) / scale, y: (viewPoint.y - origin.y) / scale)
    }

    func viewPoint(_ remote: CGPoint) -> CGPoint {
        let origin = imageLayer.frame.origin
        return CGPoint(x: origin.x + remote.x * scale, y: origin.y + remote.y * scale)
    }

    private func clampPan() {
        // The picture may not leave a gap at an edge when it's bigger than the view.
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let maxX = max(0, (size.width - bounds.width) / 2), maxY = max(0, (size.height - bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    func zoomToFit() {
        zoom = 1
        pan = .zero
        animateLayout()
    }

    /// Zooms so that a region of the screen (pixels) fills the view, with some room around it.
    func focus(on region: CGRect) {
        guard imageSize.width > 0, region.width > 0, region.height > 0 else { return }
        let padded = region.insetBy(dx: -region.width * 0.25 - 20, dy: -region.height * 0.25 - 20)
        let wanted = min(bounds.width / padded.width, bounds.height / padded.height)
        zoom = min(max(1, wanted / fitScale), 6)
        let center = CGPoint(x: region.midX, y: region.midY)
        pan = CGPoint(x: (imageSize.width / 2 - center.x) * scale, y: (imageSize.height / 2 - center.y) * scale)
        animateLayout()
    }

    private func animateLayout() {
        UIView.animate(withDuration: 0.3) { self.layoutSubviews() }
    }

    // MARK: Pointer

    func updatePointer() {
        guard let session else { return }
        let p = viewPoint(session.pointer)
        pointerView.frame.origin = CGPoint(x: p.x - 5, y: p.y - 3)
        updatePointerVisibility()
    }

    private func updatePointerVisibility() {
        pointerView.isHidden = mode != .trackpad || imageSize == .zero
    }

    /// Keeps the pointer inside the visible part when zoomed in.
    private func follow(_ remote: CGPoint) {
        guard zoom > 1.01 else { return }
        let p = viewPoint(remote)
        let margin: CGFloat = 60
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x < margin { dx = margin - p.x } else if p.x > bounds.width - margin { dx = bounds.width - margin - p.x }
        if p.y < margin { dy = margin - p.y } else if p.y > bounds.height - margin { dy = bounds.height - margin - p.y }
        if dx != 0 || dy != 0 {
            pan.x += dx
            pan.y += dy
            setNeedsLayout()
        }
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 8
        let onePan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        onePan.maximumNumberOfTouches = 1
        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        let threePan = UIPanGestureRecognizer(target: self, action: #selector(movedPicture(_:)))
        threePan.minimumNumberOfTouches = 3
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for recognizer in [tap, twoFingerTap, longPress, onePan, twoPan, threePan, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        tap.require(toFail: twoFingerTap)
        twoFingerTap.require(toFail: twoPan)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger scroll run together; the first clear movement decides which one acts.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let session else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if mode == .trackpad {
            session.clickAtPointer()
        } else {
            session.click(at: remotePoint(g.location(in: self)))
        }
        updatePointer()
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        rightClick(at: g.location(in: self))
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !dragging else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        rightClick(at: g.location(in: self))
    }

    private func rightClick(at viewPoint: CGPoint) {
        guard let session else { return }
        if mode == .trackpad {
            session.clickAtPointer(button: .right)
        } else {
            session.click(at: remotePoint(viewPoint), button: .right)
        }
        updatePointer()
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        switch mode {
        case .trackpad:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            // Finger distance in view points; a little acceleration for fast moves.
            let speed = hypot(g.velocity(in: self).x, g.velocity(in: self).y)
            let gain = (speed > 900 ? 2.2 : speed > 350 ? 1.5 : 1.0) / scale
            session.movePointer(by: CGSize(width: t.x * gain, height: t.y * gain))
            follow(session.pointer)
        case .direct:
            let p = remotePoint(g.location(in: self))
            switch g.state {
            case .began:
                dragging = true
                session.dragBegan(at: p)
            case .changed:
                session.dragMoved(to: p)
                follow(session.pointer)
            default:
                session.dragEnded(at: p)
                dragging = false
            }
        }
        updatePointer()
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        switch g.state {
        case .began:
            scrollRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if twoFinger == .undecided, hypot(t.x, t.y) > 14 { twoFinger = .scroll }
            guard twoFinger == .scroll else { return }
            g.setTranslation(.zero, in: self)
            scrollRemainder.x += t.x
            scrollRemainder.y += t.y
            let step: CGFloat = 18
            let vertical = Int(scrollRemainder.y / step), horizontal = Int(scrollRemainder.x / step)
            scrollRemainder.y -= CGFloat(vertical) * step
            scrollRemainder.x -= CGFloat(horizontal) * step
            // Fingers moving up show what's further down (natural scrolling, like on the Mac).
            let at = mode == .direct ? remotePoint(g.location(in: self)) : nil
            session.scroll(vertical: -vertical, horizontal: -horizontal, at: at)
        default:
            if twoFinger == .scroll { twoFinger = .undecided }
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = (zoom, pan, g.location(in: self))
        case .changed:
            guard let start = pinchStart else { return }
            if twoFinger == .undecided, abs(g.scale - 1) > 0.08 { twoFinger = .zoom }
            guard twoFinger == .zoom else { return }
            let newZoom = min(max(start.zoom * g.scale, 1), 8)
            let centroid = g.location(in: self)
            // Keep the point under the fingers under the fingers.
            let factor = newZoom / start.zoom
            let startOffset = CGPoint(x: start.centroid.x - bounds.midX - start.pan.x, y: start.centroid.y - bounds.midY - start.pan.y)
            pan = CGPoint(x: centroid.x - bounds.midX - startOffset.x * factor, y: centroid.y - bounds.midY - startOffset.y * factor)
            zoom = newZoom
            setNeedsLayout()
        default:
            pinchStart = nil
            if twoFinger == .zoom { twoFinger = .undecided }
            if zoom < 1.03 { zoomToFit() }
        }
    }

    @objc private func movedPicture(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        pan.x += t.x
        pan.y += t.y
        setNeedsLayout()
    }
}

/// The remote screen in SwiftUI.
struct RemoteScreen: UIViewRepresentable {
    let session: ScreenSession
    let mode: AppSettings.InputMode
    /// Changes when the view should zoom: to fit (nil) or onto a region.
    let focus: FocusRequest

    struct FocusRequest: Equatable {
        var id = UUID()
        var region: CGRect?
    }

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView()
        view.session = session
        view.mode = mode
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.session = session
        view.mode = mode
        view.show(session.frame)
        view.updatePointer()
        if context.coordinator.lastFocus != focus {
            context.coordinator.lastFocus = focus
            DispatchQueue.main.async {
                if let region = focus.region { view.focus(on: region) } else { view.zoomToFit() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocus: FocusRequest?
    }
}

/// An invisible view that brings up the keyboard and sends what is typed to the screen.
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((UInt32, [UInt32]) -> Void)?
    /// The keyboard went away (also when the person closed it).
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
    var hasText: Bool { true }
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    // Plain keys: no autocorrection, no smart punctuation, no capitalization.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    /// The normal keyboard: umlauts and the like go through the Mac's clipboard (see `ScreenSession.type`).
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    var inlinePredictionType: UITextInlinePredictionType = .no

    /// A hardware keyboard: special keys and shortcuts go straight through.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: [UInt32] = []
            if key.modifierFlags.contains(.command) { modifiers.append(Keysyms.command) }
            if key.modifierFlags.contains(.alternate) { modifiers.append(Keysyms.option) }
            if key.modifierFlags.contains(.control) { modifiers.append(Keysyms.control) }
            if let special = Self.special[key.keyCode] {
                onKey?(special, modifiers)
                handled = true
            } else if !modifiers.isEmpty, let c = key.charactersIgnoringModifiers.lowercased().first,
                      let keysym = Keysyms.forCharacter(c) {
                onKey?(keysym, modifiers)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private static let special: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardEscape: 0xff1b, .keyboardTab: 0xff09, .keyboardReturnOrEnter: 0xff0d,
        .keyboardUpArrow: 0xff52, .keyboardDownArrow: 0xff54, .keyboardLeftArrow: 0xff51, .keyboardRightArrow: 0xff53,
        .keyboardDeleteForward: 0xffff, .keyboardHome: 0xff50, .keyboardEnd: 0xff57,
        .keyboardPageUp: 0xff55, .keyboardPageDown: 0xff56,
    ]
}

struct KeyCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    let session: ScreenSession

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.onText = { [session] text in session.type(text) }
        view.onBackspace = { [session] in session.backspace() }
        view.onKey = { [session] keysym, modifiers in session.press(keysym, modifiers: modifiers) }
        view.onResign = { [isActive = $isActive] in if isActive.wrappedValue { isActive.wrappedValue = false } }
        DispatchQueue.main.async {
            if isActive, !view.isFirstResponder { view.becomeFirstResponder() }
            if !isActive, view.isFirstResponder { _ = view.resignFirstResponder() }
        }
    }
}
