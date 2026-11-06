import CoreGraphics
import UIKit

/// Where the remote screen sits in the viewer: the scaling choice, zoom and pan. Pure math, in view points and
/// remote pixels, so it can be tested without a view.
struct ScreenGeometry: Equatable {
    enum Scaling: String, CaseIterable, Identifiable, Sendable {
        /// All of the screen, with bars where the shapes differ.
        case fit
        /// The viewer filled, the rest of the screen a pan away.
        case fill
        /// One remote pixel on one pixel of the phone: sharpest, the screen is a pan away.
        case actual
        var id: String { rawValue }
    }

    /// The whole viewer.
    var bounds: CGRect = .zero
    /// The part of the viewer the picture fits into (without the rounded corners, the island and the home bar).
    var area: CGRect = .zero
    /// The remote screen in pixels.
    var imageSize: CGSize = .zero
    var scaling: Scaling = .fit
    /// Pixels of the phone per point.
    var displayScale: CGFloat = 3
    /// Zoom on top of the scaling choice: 1 is the choice itself.
    var zoom: CGFloat = 1
    /// The picture's center relative to the area's center, in points.
    var pan: CGPoint = .zero

    static let maximumZoom: CGFloat = 8

    var isEmpty: Bool { imageSize.width < 1 || imageSize.height < 1 || area.width < 1 || area.height < 1 }

    /// Points per remote pixel for the scaling choice, before zooming.
    var baseScale: CGFloat {
        guard !isEmpty else { return 1 }
        let fit = min(area.width / imageSize.width, area.height / imageSize.height)
        switch scaling {
        case .fit: return fit
        case .fill: return max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        case .actual: return 1 / max(displayScale, 1)
        }
    }

    /// Points per remote pixel.
    var scale: CGFloat { baseScale * zoom }

    /// The picture in view points.
    var frame: CGRect {
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let center = CGPoint(x: area.midX + pan.x, y: area.midY + pan.y)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Remote pixels for a point in the view.
    func remote(_ p: CGPoint) -> CGPoint {
        let f = frame, s = scale
        return CGPoint(x: (p.x - f.minX) / s, y: (p.y - f.minY) / s)
    }

    /// The view point of a remote pixel.
    func view(_ r: CGPoint) -> CGPoint {
        let f = frame, s = scale
        return CGPoint(x: f.minX + r.x * s, y: f.minY + r.y * s)
    }

    /// A picture bigger than the viewer may not show a gap at an edge; a smaller one stays centered.
    mutating func clampPan() {
        guard !isEmpty else { pan = .zero; return }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // Bigger than the area: it may use the whole viewer (under the island and the home bar) but no more.
        func limit(_ picture: CGFloat, _ area: CGFloat, _ areaMin: CGFloat, _ areaMax: CGFloat, _ boundsMin: CGFloat,
                   _ boundsMax: CGFloat, _ value: CGFloat) -> CGFloat {
            if picture <= area + 0.5 { return 0 }
            let center = (areaMin + areaMax) / 2
            // picture edges: center + value - picture/2 <= boundsMin, center + value + picture/2 >= boundsMax
            let lower = boundsMax - picture / 2 - center
            let upper = boundsMin + picture / 2 - center
            return lower <= upper ? min(max(value, lower), upper) : (lower + upper) / 2
        }
        pan.x = limit(size.width, area.width, area.minX, area.maxX, bounds.minX, bounds.maxX, pan.x)
        pan.y = limit(size.height, area.height, area.minY, area.maxY, bounds.minY, bounds.maxY, pan.y)
    }

    /// Zooms to `newZoom` keeping the remote pixel under `anchor` (view point) where it is.
    mutating func zoom(to newZoom: CGFloat, anchor: CGPoint) {
        let remoteAnchor = remote(anchor)
        zoom = min(max(newZoom, minimumZoom), Self.maximumZoom)
        let moved = view(remoteAnchor)
        pan.x += anchor.x - moved.x
        pan.y += anchor.y - moved.y
        clampPan()
    }

    /// Fill and actual size may zoom out to fit, no further.
    var minimumZoom: CGFloat {
        guard !isEmpty, baseScale > 0 else { return 1 }
        let fit = min(area.width / imageSize.width, area.height / imageSize.height)
        return min(1, fit / baseScale)
    }

    mutating func reset() {
        zoom = 1
        pan = .zero
        clampPan()
    }

    /// Zooms so that `region` (remote pixels) fills the viewer with some room around it.
    mutating func focus(on region: CGRect) {
        guard !isEmpty, region.width > 0, region.height > 0 else { return }
        let padded = region.insetBy(dx: -region.width * 0.25 - 20, dy: -region.height * 0.25 - 20)
        let wanted = min(area.width / padded.width, area.height / padded.height)
        zoom = min(max(minimumZoom, wanted / baseScale), 6)
        let center = CGPoint(x: region.midX, y: region.midY)
        pan = CGPoint(x: (imageSize.width / 2 - center.x) * scale, y: (imageSize.height / 2 - center.y) * scale)
        clampPan()
    }

    /// Pans just enough that a remote point (the pointer) stays `margin` points inside the viewer. Returns whether
    /// the picture moved.
    @discardableResult
    mutating func follow(_ r: CGPoint, margin: CGFloat = 60) -> Bool {
        let p = view(r)
        let inner = bounds.insetBy(dx: min(margin, bounds.width / 3), dy: min(margin, bounds.height / 3))
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x < inner.minX { dx = inner.minX - p.x } else if p.x > inner.maxX { dx = inner.maxX - p.x }
        if p.y < inner.minY { dy = inner.minY - p.y } else if p.y > inner.maxY { dy = inner.maxY - p.y }
        guard dx != 0 || dy != 0 else { return false }
        let before = pan
        pan.x += dx
        pan.y += dy
        clampPan()
        return pan != before
    }

    /// Phone pixels per remote pixel: below 1 the picture is shrunk (filtered), above 1 enlarged.
    var pixelRatio: CGFloat { scale * displayScale }
}
