import CoreGraphics
import Foundation

/// A screen size the iPhone asks the workspace for, so the workspace's display has the phone's shape (companion op
/// `display`, Docs/COMPANION.md). Pixels and a scale: 2 makes macOS draw at Retina sharpness (half as many points).
public struct DisplayRequest: Equatable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    /// 1 or 2: pixels per point the workspace should draw with.
    public var scale: Int

    public init(width: Int, height: Int, scale: Int) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// Limits for the workspace's display, in points: macOS needs room for its windows, the GPU has a maximum.
    public static let minimumShortSide = 600.0
    public static let minimumLongSide = 900.0
    public static let maximumPixels = 4096

    /// "1200x2400@2", as the request carries it.
    public var description: String { "\(width)x\(height)@\(scale)" }

    public init?(_ text: String) {
        let parts = text.split(separator: "@")
        guard parts.count == 2, let scale = Int(parts[1]), scale == 1 || scale == 2 else { return nil }
        let size = parts[0].split(separator: "x")
        guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]), w > 0, h > 0 else { return nil }
        self.init(width: w, height: h, scale: scale)
    }

    /// The display for a viewer area of `points` (the phone's screen without its safe area insets): the same shape,
    /// grown until macOS has room (at least 600 by 900 points), in whole points; `retina` doubles the pixels.
    public static func fitting(points: CGSize, retina: Bool) -> DisplayRequest? {
        guard points.width >= 1, points.height >= 1 else { return nil }
        let short = min(points.width, points.height), long = max(points.width, points.height)
        let grow = max(1, minimumShortSide / short, minimumLongSide / long)
        let scale = retina ? 2 : 1
        return DisplayRequest(width: Int((points.width * grow).rounded()) * scale,
                              height: Int((points.height * grow).rounded()) * scale, scale: scale).clamped()
    }

    /// Within what the workspace takes: even pixel counts (whole points at scale 2), no side above 4096 pixels, the
    /// shape kept when it shrinks.
    public func clamped() -> DisplayRequest {
        var w = Double(max(width, 1)), h = Double(max(height, 1))
        let s = scale == 2 ? 2 : 1
        let largest = Double(Self.maximumPixels)
        if max(w, h) > largest {
            let f = largest / max(w, h)
            w *= f
            h *= f
        }
        let minimum = 320.0 * Double(s)
        w = max(w, minimum)
        h = max(h, minimum)
        func even(_ v: Double) -> Int { Int(v / 2) * 2 }
        return DisplayRequest(width: even(w), height: even(h), scale: s)
    }

    /// The display's density, which decides the mode macOS picks (measured, macOS 27.2 guest): at 160 it draws
    /// exactly 2 pixels per point in portrait and landscape; at 220 it took a "more space" mode for portrait
    /// shapes instead (1200x2320 became a 2048x3960 framebuffer, five times the data). At 110 a size of points draws
    /// 1:1 (the workspace's own 1280x800 uses 110 too).
    public var pixelsPerInch: Int { scale == 2 ? 160 : 110 }
}
