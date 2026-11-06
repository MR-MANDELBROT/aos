import AOSRFB
import SwiftUI
import UIKit

/// How the viewer treats touches and shows the picture (from the settings).
struct ViewerOptions: Equatable {
    var inputMode: AppSettings.InputMode = .trackpad
    var scaling: ScreenGeometry.Scaling = .fit
    var naturalScrolling = true
    var pointerSpeed: CGFloat = 1
    var haptics = true
    /// The phone draws the pointer (the server leaves it out of the picture).
    var localCursor = true
}

/// Shows the remote screen (Metal, see `ScreenRenderer`) and turns touches into pointer input.
///
/// Trackpad mode: one finger moves the pointer (with acceleration), a tap clicks where the pointer is, a second tap
/// soon after double clicks, touch and hold then move drags. Direct mode: a tap clicks where the finger is, one finger
/// drags, touch and hold right clicks. Always: two-finger tap right clicks, two fingers scroll (with momentum), pinch
/// zooms (moving the fingers pans), three fingers move the zoomed picture. A mouse or trackpad on the iPhone points
/// directly. When zoomed in, the picture follows the pointer.
final class RemoteScreenView: UIView, UIGestureRecognizerDelegate {
    var session: ScreenSession? {
        didSet {
            guard session !== oldValue else { return }
            oldValue?.onFrame = nil
            session?.onFrame = { [weak self] in self?.frameArrived() }
            frameArrived()
        }
    }

    var options = ViewerOptions() {
        didSet {
            guard options != oldValue else { return }
            if options.scaling != oldValue.scaling { geometry.scaling = options.scaling; geometry.reset() }
            scroll.natural = options.naturalScrolling
            setNeedsLayout()
            updatePointer()
        }
    }

    /// Any touch on the screen (the toolbar hides).
    var onTouch: (() -> Void)?

    private(set) var geometry = ScreenGeometry()
    private let renderer = ScreenRenderer()
    private let canvas = ScreenCanvas()
    /// Without Metal (should not happen): the picture as a layer's contents.
    private let fallbackLayer = CALayer()
    private let cursorLayer = CALayer()
    private var renderScheduled = false
    private var shownCursor: RFBCursor?

    private enum TwoFinger { case undecided, zoom, scroll }
    private var twoFinger = TwoFinger.undecided
    private var pinchStart: (geometry: ScreenGeometry, centroid: CGPoint)?
    private var scroll = ScrollAccumulator()
    private var momentum: ScrollMomentum?
    private var momentumLink: CADisplayLink?
    private var momentumPoint: CGPoint?
    private var lastMomentumTime: CFTimeInterval = 0
    private var holdLocation: CGPoint = .zero
    private var lastTap: (time: Date, view: CGPoint, remote: CGPoint)?

    /// Points at the bottom the keyboard (and the key bar above it) cover.
    private var keyboardOverlap: CGFloat = 0
    /// Height of what the viewer shows above the keyboard (the key bar).
    var keyboardAccessoryHeight: CGFloat = 0

    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let pressFeedback = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        if renderer != nil {
            addSubview(canvas)
        } else {
            fallbackLayer.contentsGravity = .resize
            fallbackLayer.minificationFilter = .trilinear
            layer.addSublayer(fallbackLayer)
        }
        cursorLayer.contentsGravity = .resize
        cursorLayer.isHidden = true
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.35
        cursorLayer.shadowRadius = 1.5
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(cursorLayer)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Remote screen")
        accessibilityTraits = .allowsDirectInteraction
        installGestures()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The keyboard covers the bottom: the picture keeps its size and the covered part is a pan away (in trackpad
    /// mode the picture follows the pointer up).
    @objc private func keyboardChanged(_ note: Notification) {
        var overlap: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let local = convert(frame, from: nil)
            overlap = max(0, bounds.maxY - local.minY)
            if overlap > 0 { overlap += keyboardAccessoryHeight }
        }
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        setNeedsLayout()
        if overlap > 0 { follow() }
    }

    // MARK: Picture

    /// A new picture is in the session's framebuffer.
    func frameArrived() {
        guard let session else { return }
        if let image = session.stillImage {
            show(image)
            return
        }
        guard let framebuffer = session.framebuffer else { return }
        if let renderer {
            guard renderer.update(from: framebuffer) else { return }
            imageChanged(renderer.imageSize)
        } else if framebuffer.takeChanges({ _ in }) {
            fallbackLayer.contents = framebuffer.makeImage()
            imageChanged(framebuffer.size)
        }
        setNeedsRender()
    }

    /// A still picture (the demo, tests).
    func show(_ image: CGImage) {
        if let renderer {
            renderer.show(image)
        } else {
            fallbackLayer.contents = image
        }
        imageChanged(CGSize(width: image.width, height: image.height))
        setNeedsRender()
    }

    private func imageChanged(_ size: CGSize) {
        guard size != geometry.imageSize else { return }
        let first = geometry.imageSize == .zero
        geometry.imageSize = size
        if first || geometry.zoom == 1 { geometry.reset() } else { geometry.clampPan() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        geometry.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - keyboardOverlap))
        // The view ignores the safe area (it draws under the island too); the window's insets say what to avoid.
        geometry.area = bounds.inset(by: window?.safeAreaInsets ?? safeAreaInsets)
        geometry.displayScale = window?.screen.scale ?? traitCollection.displayScale
        geometry.scaling = options.scaling
        geometry.clampPan()
        canvas.frame = bounds
        render()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render() {
        let frame = geometry.isEmpty ? .zero : geometry.frame
        if let renderer {
            canvas.layoutIfNeeded()
            renderer.draw(in: canvas.metalLayer, picture: frame, size: bounds.size)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fallbackLayer.frame = frame
            CATransaction.commit()
        }
        updatePointer()
    }

    /// Screen pixels for a point in the view.
    func remotePoint(_ viewPoint: CGPoint) -> CGPoint { geometry.remote(viewPoint) }

    func viewPoint(_ remote: CGPoint) -> CGPoint { geometry.view(remote) }

    func zoomToFit() {
        geometry.reset()
        render()
    }

    /// Zooms so that a region of the screen (pixels) fills the view, with some room around it.
    func focus(on region: CGRect) {
        geometry.focus(on: region)
        render()
    }

    // MARK: Pointer

    private static let fallbackCursor: CGImage? = {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        guard let symbol = UIImage(systemName: "cursorarrow", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: symbol.size)
        return renderer.image { _ in symbol.draw(at: .zero) }.cgImage
    }()

    func updatePointer() {
        guard let session else { return }
        let visible = options.localCursor && options.inputMode == .trackpad && !geometry.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible
        if visible {
            let p = geometry.view(session.pointer)
            if let cursor = session.cursor {
                if cursor != shownCursor {
                    shownCursor = cursor
                    cursorLayer.contents = cursor.makeImage()
                }
                // As big as on the remote screen, but never tiny on the phone.
                let s = max(geometry.scale, 20 / CGFloat(max(cursor.height, 1)))
                cursorLayer.frame = CGRect(x: p.x - CGFloat(cursor.hotX) * s, y: p.y - CGFloat(cursor.hotY) * s,
                                           width: CGFloat(cursor.width) * s, height: CGFloat(cursor.height) * s)
            } else {
                if shownCursor != nil || cursorLayer.contents == nil {
                    shownCursor = nil
                    cursorLayer.contents = Self.fallbackCursor
                }
                cursorLayer.frame = CGRect(x: p.x - 5, y: p.y - 3, width: 17, height: 24)
            }
        }
        CATransaction.commit()
    }

    /// Keeps the pointer inside the visible part when zoomed in.
    private func follow() {
        guard let session, geometry.scale * geometry.imageSize.width > bounds.width + 1
                || geometry.scale * geometry.imageSize.height > bounds.height + 1 else { return }
        if geometry.follow(session.pointer) { setNeedsRender() }
    }

    private func haptic(_ generator: UIImpactFeedbackGenerator) {
        guard options.haptics else { return }
        generator.impactOccurred()
    }

    // MARK: Gestures

    private var holdPress: UILongPressGestureRecognizer!

    private func installGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct
        holdPress = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        holdPress.minimumPressDuration = 0.35
        holdPress.allowableMovement = 10
        holdPress.allowedTouchTypes = direct
        let onePan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        onePan.maximumNumberOfTouches = 1
        onePan.allowedTouchTypes = direct
        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.allowedTouchTypes = direct
        let threePan = UIPanGestureRecognizer(target: self, action: #selector(movedPicture(_:)))
        threePan.minimumNumberOfTouches = 3
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))

        // A mouse or trackpad connected to the phone: it points where it is, clicks and scrolls.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let pointerClick = UITapGestureRecognizer(target: self, action: #selector(pointerClicked(_:)))
        pointerClick.allowedTouchTypes = pointer
        pointerClick.buttonMaskRequired = .primary
        let pointerRightClick = UITapGestureRecognizer(target: self, action: #selector(pointerRightClicked(_:)))
        pointerRightClick.allowedTouchTypes = pointer
        pointerRightClick.buttonMaskRequired = .secondary
        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerDrag.allowedTouchTypes = pointer
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []

        for recognizer in [tap, twoFingerTap, holdPress, onePan, twoPan, threePan, pinch, hover, pointerClick,
                           pointerRightClick, pointerDrag, wheel] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        twoFingerTap.require(toFail: twoPan)
        twoFingerTap.require(toFail: pinch)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger scroll run together; the first clear movement decides which one acts.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || g is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        onTouch?()
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let session, !geometry.isEmpty else { return }
        haptic(tapFeedback)
        let now = Date()
        let location = g.location(in: self)
        // A second tap soon after (and close by, in direct mode) is a double click at the first tap's pixel.
        let second = lastTap.map { now.timeIntervalSince($0.time) < 0.45 && hypot($0.view.x - location.x, $0.view.y - location.y) < 28 } ?? false
        switch options.inputMode {
        case .trackpad:
            session.clickAtPointer()
        case .direct:
            let remote = second ? lastTap!.remote : remotePoint(location)
            session.click(at: remote)
        }
        lastTap = second ? nil : (now, location, options.inputMode == .direct ? remotePoint(location) : session.pointer)
        updatePointer()
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        rightClick(at: g.location(in: self))
    }

    private func rightClick(at viewPoint: CGPoint) {
        guard let session, !geometry.isEmpty else { return }
        haptic(pressFeedback)
        if options.inputMode == .trackpad {
            session.clickAtPointer(button: .right)
        } else {
            session.click(at: remotePoint(viewPoint), button: .right)
        }
        updatePointer()
    }

    /// Touch and hold: in trackpad mode the button goes down and moving drags; in direct mode a right click.
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard let session, !geometry.isEmpty else { return }
        let location = g.location(in: self)
        switch options.inputMode {
        case .direct:
            if g.state == .began { rightClick(at: location) }
        case .trackpad:
            switch g.state {
            case .began:
                haptic(pressFeedback)
                holdLocation = location
                session.beginDrag()
            case .changed:
                let delta = CGPoint(x: location.x - holdLocation.x, y: location.y - holdLocation.y)
                holdLocation = location
                let motion = PointerAcceleration(speed: options.pointerSpeed)
                session.movePointer(by: motion.remoteDelta(delta, velocity: .zero, scale: geometry.scale))
                follow()
            default:
                session.endDrag()
                haptic(tapFeedback)
            }
            updatePointer()
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let session, !geometry.isEmpty else { return }
        switch options.inputMode {
        case .trackpad:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            let motion = PointerAcceleration(speed: options.pointerSpeed)
            session.movePointer(by: motion.remoteDelta(t, velocity: g.velocity(in: self), scale: geometry.scale))
            follow()
        case .direct:
            let location = g.location(in: self)
            switch g.state {
            case .began:
                // From where the finger came down, not where the pan was recognized.
                let t = g.translation(in: self)
                session.beginDrag(at: remotePoint(CGPoint(x: location.x - t.x, y: location.y - t.y)))
                session.movePointer(to: remotePoint(location))
            case .changed:
                session.movePointer(to: remotePoint(location))
                follow()
            default:
                session.endDrag(at: remotePoint(location))
            }
        }
        updatePointer()
    }

    /// Finger points per wheel step: about as far as the content moves for one step on the phone.
    private var stepLength: CGFloat { min(max(40 * geometry.scale, 6), 30) }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        switch g.state {
        case .began:
            scroll.reset()
        case .changed:
            let t = g.translation(in: self)
            if twoFinger == .undecided, hypot(t.x, t.y) > 12 { twoFinger = .scroll }
            guard twoFinger == .scroll else { return }
            g.setTranslation(.zero, in: self)
            scroll.stepLength = stepLength
            let steps = scroll.steps(for: t)
            let at = options.inputMode == .direct ? remotePoint(g.location(in: self)) : nil
            session.scroll(dx: steps.dx, dy: steps.dy, at: at)
        default:
            if twoFinger == .scroll {
                twoFinger = .undecided
                if g.state == .ended {
                    startMomentum(g.velocity(in: self), at: options.inputMode == .direct ? remotePoint(g.location(in: self)) : nil)
                }
            }
        }
    }

    private func startMomentum(_ velocity: CGPoint, at point: CGPoint?) {
        let m = ScrollMomentum(velocity: velocity)
        guard !m.isDone else { return }
        momentum = m
        momentumPoint = point
        lastMomentumTime = CACurrentMediaTime()
        momentumLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(glide(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentum = nil
    }

    @objc private func glide(_ link: CADisplayLink) {
        guard var m = momentum, let session else { stopMomentum(); return }
        let now = CACurrentMediaTime()
        let delta = m.advance(now - lastMomentumTime)
        lastMomentumTime = now
        momentum = m
        let steps = scroll.steps(for: delta)
        session.scroll(dx: steps.dx, dy: steps.dy, at: momentumPoint)
        if m.isDone { stopMomentum() }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = (geometry, g.location(in: self))
        case .changed:
            guard let start = pinchStart else { return }
            if twoFinger == .undecided, abs(g.scale - 1) > 0.08 { twoFinger = .zoom }
            guard twoFinger == .zoom else { return }
            let centroid = g.location(in: self)
            var next = start.geometry
            next.bounds = geometry.bounds
            next.area = geometry.area
            next.zoom(to: start.geometry.zoom * g.scale, anchor: start.centroid)
            // Moving the fingers moves the picture.
            next.pan.x += centroid.x - start.centroid.x
            next.pan.y += centroid.y - start.centroid.y
            next.clampPan()
            geometry = next
            render()
        default:
            pinchStart = nil
            if twoFinger == .zoom { twoFinger = .undecided }
            if abs(geometry.zoom - 1) < 0.04 { zoomToFit() }
        }
    }

    @objc private func movedPicture(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        geometry.pan.x += t.x
        geometry.pan.y += t.y
        geometry.clampPan()
        render()
    }

    // MARK: A mouse or trackpad on the phone

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard let session, !geometry.isEmpty, g.state == .changed || g.state == .began else { return }
        session.movePointer(to: remotePoint(g.location(in: self)))
        updatePointer()
    }

    @objc private func pointerClicked(_ g: UITapGestureRecognizer) {
        session?.click(at: remotePoint(g.location(in: self)))
    }

    @objc private func pointerRightClicked(_ g: UITapGestureRecognizer) {
        session?.click(at: remotePoint(g.location(in: self)), button: .right)
    }

    @objc private func pointerDragged(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        let p = remotePoint(g.location(in: self))
        switch g.state {
        case .began: session.beginDrag(at: p)
        case .changed: session.movePointer(to: p)
        default: session.endDrag(at: p)
        }
    }

    @objc private func wheeled(_ g: UIPanGestureRecognizer) {
        guard let session else { return }
        if g.state == .began { scroll.reset() }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        scroll.stepLength = stepLength
        let steps = scroll.steps(for: t)
        session.scroll(dx: steps.dx, dy: steps.dy, at: remotePoint(g.location(in: self)))
    }
}

/// The remote screen in SwiftUI.
struct RemoteScreen: UIViewRepresentable {
    let session: ScreenSession
    let options: ViewerOptions
    /// Changes when the view should zoom: to fit (nil) or onto a region.
    let focus: FocusRequest
    /// The key bar above the keyboard covers this much more.
    var keyBarHeight: CGFloat = 0
    var onTouch: (() -> Void)?

    struct FocusRequest: Equatable {
        var id = UUID()
        var region: CGRect?
    }

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView()
        view.options = options
        view.session = session
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.session = session
        view.options = options
        view.onTouch = onTouch
        view.keyboardAccessoryHeight = keyBarHeight
        // Observed here so SwiftUI updates the pointer and the shape when they change.
        _ = (session.pointer, session.cursor, session.size)
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
    /// A hardware key goes down or up (special keys, shortcuts, held modifiers).
    var onKey: ((UInt32, Bool) -> Void)?
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

    /// Keys of a hardware keyboard that go down and up themselves: modifiers, special keys, and letters while a
    /// modifier other than Shift is held (shortcuts). Plain typing goes through `insertText`.
    private var down: [UIKeyboardHIDUsage: UInt32] = [:]

    private func keysym(for key: UIKey) -> UInt32? {
        if let k = Self.modifiers[key.keyCode] ?? Self.special[key.keyCode] { return k }
        let shortcut = !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
        guard shortcut, let c = key.charactersIgnoringModifiers.lowercased().first else { return nil }
        return Keysyms.forCharacter(c)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let k = keysym(for: key) else { rest.insert(press); continue }
            down[key.keyCode] = k
            onKey?(k, true)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let k = down.removeValue(forKey: key.keyCode) else { rest.insert(press); continue }
            onKey?(k, false)
        }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let k = down.removeValue(forKey: key.keyCode) { onKey?(k, false) }
        }
        super.pressesCancelled(presses, with: event)
    }

    private static let modifiers: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardLeftGUI: Keysyms.command, .keyboardRightGUI: Keysyms.command,
        .keyboardLeftAlt: Keysyms.option, .keyboardRightAlt: Keysyms.option,
        .keyboardLeftControl: Keysyms.control, .keyboardRightControl: Keysyms.control,
        .keyboardLeftShift: Keysyms.shift, .keyboardRightShift: Keysyms.shift,
    ]

    private static let special: [UIKeyboardHIDUsage: UInt32] = {
        var m: [UIKeyboardHIDUsage: UInt32] = [
            .keyboardEscape: 0xff1b, .keyboardTab: 0xff09, .keyboardReturnOrEnter: 0xff0d,
            .keyboardDeleteOrBackspace: 0xff08,
            .keyboardUpArrow: 0xff52, .keyboardDownArrow: 0xff54, .keyboardLeftArrow: 0xff51, .keyboardRightArrow: 0xff53,
            .keyboardDeleteForward: 0xffff, .keyboardHome: 0xff50, .keyboardEnd: 0xff57,
            .keyboardPageUp: 0xff55, .keyboardPageDown: 0xff56,
        ]
        let functionKeys: [UIKeyboardHIDUsage] = [.keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
                                                  .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12]
        for (i, key) in functionKeys.enumerated() { m[key] = 0xffbe + UInt32(i) }
        return m
    }()
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
        view.onKey = { [session] keysym, down in session.key(keysym, down: down) }
        view.onResign = { [isActive = $isActive] in if isActive.wrappedValue { isActive.wrappedValue = false } }
        DispatchQueue.main.async {
            if isActive, !view.isFirstResponder { view.becomeFirstResponder() }
            if !isActive, view.isFirstResponder { _ = view.resignFirstResponder() }
        }
    }
}
