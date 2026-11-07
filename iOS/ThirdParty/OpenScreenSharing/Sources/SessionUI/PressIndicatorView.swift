// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

#if os(iOS)
import UIKit

final class PressIndicatorView: UIView {
    private static let radius: CGFloat = 22
    private static let lineWidth: CGFloat = 3

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let pulse = CAShapeLayer()
    private var isShowing = false

    init() {
        let size = (Self.radius + Self.lineWidth) * 2
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        layer.opacity = 0
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: size / 2, y: size / 2), radius: Self.radius, startAngle: -.pi / 2, endAngle: .pi * 3 / 2, clockwise: true
        ).cgPath
        for shape in [track, progress, pulse] {
            shape.frame = bounds
            shape.path = circle
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = UIColor.black.withAlphaComponent(0.3).cgColor
        progress.strokeColor = UIColor.white.cgColor
        progress.shadowColor = UIColor.black.cgColor
        progress.shadowOpacity = 0.4
        progress.shadowRadius = 2
        progress.shadowOffset = .zero
        pulse.strokeColor = UIColor.white.cgColor
        pulse.lineWidth = 2
        pulse.opacity = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginHold(delay: TimeInterval, duration: TimeInterval) {
        isShowing = true
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, progress, pulse] {
            shape.removeAllAnimations()
        }
        progress.fillColor = nil
        CATransaction.commit()
        let start = CACurrentMediaTime() + delay
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.beginTime = start
        appear.duration = 0.1
        appear.fillMode = .backwards
        layer.opacity = 1
        layer.add(appear, forKey: "opacity")
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.beginTime = start
        fill.duration = duration
        fill.fillMode = .backwards
        progress.add(fill, forKey: "strokeEnd")
    }

    func press() {
        layer.removeAnimation(forKey: "opacity")
        layer.opacity = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.removeAnimation(forKey: "strokeEnd")
        progress.fillColor = UIColor.white.withAlphaComponent(0.2).cgColor
        CATransaction.commit()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(group, forKey: "pulse")
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.duration = 0.15
        layer.opacity = 0
        layer.add(fade, forKey: "opacity")
    }
}
#endif
