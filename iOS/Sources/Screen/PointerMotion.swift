import CoreGraphics
import Foundation

/// Trackpad mode: how far the pointer goes for a finger movement. Slow movements are precise (the pointer moves as
/// far on the phone's screen as the finger), fast ones carry it across the screen, with a smooth curve between.
struct PointerAcceleration: Equatable {
    /// The person's speed choice: 0.5 slow ... 2 fast.
    var speed: CGFloat = 1

    /// Finger speed (points per second) from which the gain grows, and the largest gain.
    static let threshold: CGFloat = 120
    static let maximumGain: CGFloat = 4

    /// How much the pointer moves on the phone's screen per point of finger movement.
    func gain(velocity: CGFloat) -> CGFloat {
        let v = max(0, velocity - Self.threshold)
        // Grows like a soft power curve: about 1.8 at 600 pt/s, 3.6 at 1500 pt/s, at most 4.
        let accelerated = 1 + pow(v / 900, 1.15) * 1.6
        return min(accelerated, Self.maximumGain) * speed
    }

    /// The pointer's move in remote pixels for a finger move of `delta` points at `velocity`, with the picture shown
    /// at `scale` points per remote pixel.
    func remoteDelta(_ delta: CGPoint, velocity: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return .zero }
        let g = gain(velocity: hypot(velocity.x, velocity.y)) / scale
        return CGPoint(x: delta.x * g, y: delta.y * g)
    }
}

/// Two-finger scrolling: finger movement (points) into scroll wheel steps, keeping the remainder so slow movements
/// scroll too. With natural scrolling the content follows the fingers (fingers up shows what's further down).
struct ScrollAccumulator: Equatable {
    var natural = true
    /// Finger points per wheel step.
    var stepLength: CGFloat = 9
    private var remainder: CGPoint = .zero

    init(natural: Bool = true, stepLength: CGFloat = 9) {
        self.natural = natural
        self.stepLength = stepLength
    }

    /// Wheel steps for a finger movement: positive `dy` scrolls the content up (wheel down), positive `dx` to the
    /// left (wheel right), the way `RFBClient.wheel` takes them.
    mutating func steps(for fingerDelta: CGPoint) -> (dx: Int, dy: Int) {
        let sign: CGFloat = natural ? -1 : 1
        remainder.x += fingerDelta.x * sign
        remainder.y += fingerDelta.y * sign
        let dx = Int(remainder.x / stepLength), dy = Int(remainder.y / stepLength)
        remainder.x -= CGFloat(dx) * stepLength
        remainder.y -= CGFloat(dy) * stepLength
        return (dx, dy)
    }

    mutating func reset() { remainder = .zero }
}

/// The glide after the fingers leave the glass: the speed decays like iOS scrolling.
struct ScrollMomentum: Equatable {
    /// Points per second.
    private(set) var velocity: CGPoint
    /// Speed kept per second (iOS uses about 0.998 per millisecond, 0.13 per second).
    static let decayPerSecond: CGFloat = 0.135
    static let stopSpeed: CGFloat = 25

    init(velocity: CGPoint) {
        // Short flicks glide, slow lifts don't.
        let speed = hypot(velocity.x, velocity.y)
        self.velocity = speed < 200 ? .zero : velocity
    }

    var isDone: Bool { hypot(velocity.x, velocity.y) < Self.stopSpeed }

    /// The movement during `dt` seconds (points); the speed decays.
    mutating func advance(_ dt: TimeInterval) -> CGPoint {
        guard !isDone, dt > 0 else { return .zero }
        let k = pow(Self.decayPerSecond, CGFloat(dt))
        // Distance covered while the speed goes from v to v*k: v * (k - 1) / ln(decay)
        let factor = (k - 1) / log(Self.decayPerSecond)
        let delta = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        velocity = CGPoint(x: velocity.x * k, y: velocity.y * k)
        return delta
    }
}
