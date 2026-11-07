// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

#if os(iOS)
import UIKit

enum PointerShape {
    // _UIBeamPointerSettings defaults to width 3 and length 24 to 100, UIPointerStyle draws the system and path styles
    // at PSPointerSettings materialAlphaDot 0.85 and beams at materialAlphaIBeam 1, and pointeruid draws accessories at
    // intensity 1 (UIKitCore 9127.1.13.1.106, iPadOS 27.2 24B5110a, UUID 56EB6C8F-D489-378F-AABA-81975A6D213E,
    // -[_UIBeamPointerSettings setDefaultValues] 0x185887838..0x18588786c,
    // -[UIPointerStyle _pointerIntensityForMaterialLuminance:] 0x185835d8c..0x185835dec; PointerUIServices 172,
    // UUID D63E9940-478E-322E-A6A3-66E96D5B679C, -[PSPointerSettings setDefaultValues] 0x22780e834..0x22780e84c;
    // pointeruid 172, UUID DC5440B7-2A3E-3CB1-BFC8-F86EEB565E5C, sub_10001b088 0x10001b0a0..0x10001b0a8).
    private static let beamThickness: CGFloat = 3
    private static let beamLengths: ClosedRange<CGFloat> = 24...100
    private static let shapeIntensity: CGFloat = 0.85
    private static let beamIntensity: CGFloat = 1
    private static let accessoryIntensity: CGFloat = 1

    private enum Shape {
        case system
        case verticalBeam(CGFloat)
        case horizontalBeam(CGFloat)
        case path(UIBezierPath)
    }

    private enum Accessory {
        case arrow
        case path(UIBezierPath)
    }

    static func style(for cursor: StandardCursor, beamLength: CGFloat) -> UIPointerStyle {
        let (shape, accessories) = parts(for: cursor, beamLength: beamLength)
        let style =
            switch shape {
            case .system: UIPointerStyle.system()
            case .verticalBeam(let length): UIPointerStyle(shape: .verticalBeam(length: length), constrainedAxes: [])
            case .horizontalBeam(let length): UIPointerStyle(shape: .horizontalBeam(length: length), constrainedAxes: [])
            case .path(let path): UIPointerStyle(shape: .path(path), constrainedAxes: [])
            }
        style.accessories = accessories.map { position, accessory in
            switch accessory {
            case .arrow: .arrow(position)
            case .path(let path): UIPointerAccessory(.path(path), position: position)
            }
        }
        return style
    }

    static func mask(for cursor: StandardCursor, beamLength: CGFloat, scale: CGFloat) -> (image: CGImage, hotspot: CGPoint)? {
        let (shape, accessories) = parts(for: cursor, beamLength: beamLength)
        let body: CGPath
        let intensity: CGFloat
        switch shape {
        case .system:
            body = arrow
            intensity = shapeIntensity
        case .verticalBeam(let length):
            let length = min(max(length, beamLengths.lowerBound), beamLengths.upperBound)
            body = CGPath(
                roundedRect: CGRect(x: -beamThickness / 2, y: -length / 2, width: beamThickness, height: length),
                cornerWidth: beamThickness / 2, cornerHeight: beamThickness / 2, transform: nil)
            intensity = beamIntensity
        case .horizontalBeam(let length):
            let length = min(max(length, beamLengths.lowerBound), beamLengths.upperBound)
            body = CGPath(
                roundedRect: CGRect(x: -length / 2, y: -beamThickness / 2, width: length, height: beamThickness),
                cornerWidth: beamThickness / 2, cornerHeight: beamThickness / 2, transform: nil)
            intensity = beamIntensity
        case .path(let path):
            body = path.cgPath
            intensity = shapeIntensity
        }
        // pointeruid centres an accessory offset + height / 2 from the pointer along its angle, turned by that angle
        // only when orientationMatchesAngle is set, which UIKit sets only on the arrow accessory (pointeruid 172,
        // iPadOS 27.2 24B5110a, UUID DC5440B7-2A3E-3CB1-BFC8-F86EEB565E5C, sub_10001a034 0x10001a05c..0x10001a11c;
        // UIKitCore 9127.1.13.1.106, UUID 56EB6C8F-D489-378F-AABA-81975A6D213E,
        // +[UIPointerAccessory arrowAccessoryWithPosition:] 0x18506f8f8..0x18506f8fc).
        let accessoryPaths = accessories.map { position, accessory -> CGPath in
            let path: CGPath
            let rotation: CGFloat
            switch accessory {
            case .arrow:
                path = arrowAccessory
                rotation = position.angle
            case .path(let shape):
                path = shape.cgPath
                rotation = 0
            }
            let bounds = path.boundingBoxOfPath
            let distance = position.offset + bounds.height / 2
            var transform = CGAffineTransform(translationX: sin(position.angle) * distance, y: -cos(position.angle) * distance)
                .rotated(by: rotation)
                .translatedBy(x: -bounds.midX, y: -bounds.midY)
            return path.copy(using: &transform) ?? path
        }
        let bounds = accessoryPaths.reduce(body.boundingBoxOfPath) { $0.union($1.boundingBoxOfPath) }.insetBy(dx: -1, dy: -1).integral
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setBlendMode(.plusLighter)
        context.setFillColor(red: 0, green: accessoryIntensity, blue: 0, alpha: 1)
        for path in accessoryPaths {
            context.addPath(path)
            context.fillPath()
        }
        context.setFillColor(red: intensity, green: 0, blue: 0, alpha: 1)
        context.addPath(body)
        if case .path(let path) = shape, path.usesEvenOddFillRule {
            context.fillPath(using: .evenOdd)
        } else {
            context.fillPath()
        }
        guard let image = context.makeImage() else { return nil }
        return (image, CGPoint(x: -bounds.minX, y: -bounds.minY))
    }

    static func preview(for cursor: StandardCursor, backdrop: SIMD3<Float>, material: CursorMaterial, scale: CGFloat) -> CGImage? {
        guard let mask = mask(for: cursor, beamLength: beamLengths.lowerBound, scale: scale)?.image else { return nil }
        let width = mask.width
        let height = mask.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let matrix = material.matrix(lightPointer: material.isDarkInterface)
        let tinted = (matrix[0] * backdrop.x + matrix[1] * backdrop.y + matrix[2] * backdrop.z + matrix[3])
            .clamped(lowerBound: SIMD4(repeating: 0), upperBound: SIMD4(repeating: 1))
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            for offset in stride(from: 0, to: raw.count, by: 4) {
                let body = tinted.w * Float(raw[offset]) / 255
                let accessory = tinted.w * Float(raw[offset + 1]) / 255
                let alpha = 1 - (1 - body) * (1 - accessory)
                raw[offset] = UInt8((tinted.x * alpha * 255).rounded())
                raw[offset + 1] = UInt8((tinted.y * alpha * 255).rounded())
                raw[offset + 2] = UInt8((tinted.z * alpha * 255).rounded())
                raw[offset + 3] = UInt8((alpha * 255).rounded())
            }
            return context.makeImage()
        }
    }

    private static func parts(
        for cursor: StandardCursor, beamLength: CGFloat
    ) -> (shape: Shape, accessories: [(UIPointerAccessory.Position, Accessory)]) {
        switch cursor {
        case .iBeam:
            return (.verticalBeam(beamLength), [])
        case .verticalIBeam:
            return (.horizontalBeam(beamLength), [])
        case .crosshair:
            return (.path(cross(length: 20, thickness: 2)), [])
        case .arrow, .contextualMenu, .pointingHand, .openHand, .closedHand, .dragLink:
            return (.system, [])
        case .dragCopy, .zoomIn:
            return (.system, [(.bottomRight, .path(cross(length: 8, thickness: 2)))])
        case .zoomOut:
            return (.system, [(.bottomRight, .path(UIBezierPath(rect: CGRect(x: -4, y: -1, width: 8, height: 2))))])
        case .operationNotAllowed:
            let path = UIBezierPath(ovalIn: CGRect(x: -4.5, y: -4.5, width: 9, height: 9))
            path.append(UIBezierPath(ovalIn: CGRect(x: -3, y: -3, width: 6, height: 6)).reversing())
            let slash = UIBezierPath(rect: CGRect(x: -2.8, y: -0.75, width: 5.6, height: 1.5))
            slash.apply(CGAffineTransform(rotationAngle: .pi / 4))
            path.append(slash)
            return (.system, [(.bottomRight, .path(path))])
        case .resize(let directions):
            let axes: [(directions: StandardCursor.ResizeDirections, angle: CGFloat)] = [
                ([.left, .right], 0), ([.up, .down], .pi / 2), ([.upLeft, .downRight], .pi / 4), ([.upRight, .downLeft], -.pi / 4),
            ]
            let angles = axes.filter { !directions.isDisjoint(with: $0.directions) }.map(\.angle)
            guard angles.count == 1 else {
                let positions: [(StandardCursor.ResizeDirections, UIPointerAccessory.Position)] = [
                    (.up, .top), (.down, .bottom), (.left, .left), (.right, .right),
                    (.upLeft, .topLeft), (.upRight, .topRight), (.downLeft, .bottomLeft), (.downRight, .bottomRight),
                ]
                return (.system, positions.filter { directions.contains($0.0) }.map { ($0.1, .arrow) })
            }
            return (.path(resizeArrows(angle: angles[0])), [])
        }
    }

    // SpringBoard draws the window resize pointer as its whole shape, without accessories, with constrainedAxes 0: two
    // triangles with corners rounded by 2 at (∓3, ±8) and (∓19.894736842105264, 0), always both, turned to 0 or ±π / 2
    // for an edge and to ±π / 4 or ±3π / 4 for a corner. It then moves the shape off the pointer along that turn by
    // (inner 5 − outer 12.5) / 2 for an edge or (1 − √2) × the window corner radius for a corner, from the hovered edge
    // and window it knows (SpringBoard 4637.1.14, iPadOS 27.2 24B5110a, UUID DC16B497-8B4A-323B-BA45-84E3A4DC5307,
    // -[SBAppSwitcherPageView styleForRegion:forView:] 0x226b8900c..0x226b89028,
    // +[SBEdgeResizeSystemPointerInteractionHelper fancyResizePointerShapeHoveringOverEdge:innerLengthOfInteractionRegion:outerLengthOfInteractionRegion:cornerRadii:]
    // 0x227128c30..0x227128e98, -[SBAppSwitcherSettings setDefaultValues] 0x22713a41c..0x22713a430).
    private static func resizeArrows(angle: CGFloat) -> UIBezierPath {
        let path = CGMutablePath()
        let transform = CGAffineTransform(rotationAngle: angle)
        for side: CGFloat in [-1, 1] {
            let base = 3 * side
            let tip = 19.894736842105264 * side
            path.move(to: CGPoint(x: base, y: 0), transform: transform)
            path.addArc(tangent1End: CGPoint(x: base, y: 8), tangent2End: CGPoint(x: tip, y: 0), radius: 2, transform: transform)
            path.addArc(tangent1End: CGPoint(x: tip, y: 0), tangent2End: CGPoint(x: base, y: -8), radius: 2, transform: transform)
            path.addArc(tangent1End: CGPoint(x: base, y: -8), tangent2End: CGPoint(x: base, y: 8), radius: 2, transform: transform)
            path.closeSubpath()
        }
        return UIBezierPath(cgPath: path)
    }

    // pointeruid's system arrow, moved so the hotspot is the origin (pointeruid 172, iPadOS 27.2 24B5110a,
    // UUID DC5440B7-2A3E-3CB1-BFC8-F86EEB565E5C, sub_100005d84 0x100005d9c..0x100005fc4,
    // -[PUIDPointerShapeView expectedShapeBoundsForPointerShape:] 0x1000021e4..0x1000022a8).
    private static let arrow: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1.5, y: 0))
        path.addCurve(to: CGPoint(x: 2.57848, y: 0.457467), control1: CGPoint(x: 1.90664, y: 0), control2: CGPoint(x: 2.29586, y: 0.165097))
        path.addLine(to: CGPoint(x: 12.0422, y: 10.2475))
        path.addCurve(to: CGPoint(x: 12.0063, y: 12.3686), control1: CGPoint(x: 12.618, y: 10.8432), control2: CGPoint(x: 12.6019, y: 11.7928))
        path.addCurve(to: CGPoint(x: 10.9637, y: 12.7901), control1: CGPoint(x: 11.7266, y: 12.6389), control2: CGPoint(x: 11.3528, y: 12.7901))
        path.addLine(to: CGPoint(x: 6.58348, y: 12.7901))
        path.addCurve(to: CGPoint(x: 5.56989, y: 13.1843), control1: CGPoint(x: 6.20819, y: 12.7901), control2: CGPoint(x: 5.84653, y: 12.9307))
        path.addLine(to: CGPoint(x: 2.51359, y: 15.9859))
        path.addCurve(to: CGPoint(x: 0.394269, y: 15.8938), control1: CGPoint(x: 1.90291, y: 16.5457), control2: CGPoint(x: 0.954057, y: 16.5045))
        path.addCurve(to: CGPoint(x: 0, y: 14.8802), control1: CGPoint(x: 0.140678, y: 15.6172), control2: CGPoint(x: 0, y: 15.2555))
        path.addLine(to: CGPoint(x: 0, y: 1.5))
        path.addCurve(to: CGPoint(x: 1.5, y: 0), control1: CGPoint(x: 0, y: 0.671573), control2: CGPoint(x: 0.671573, y: 0))
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: -1.5, y: -1.5)
        return path.copy(using: &transform)!
    }()

    // Outline of the arrowtriangle.up.fill symbol (11 pt, regular, medium), moved to the origin, that UIKit uses for
    // UIPointerAccessory.arrow (UIKitCore 9127.1.13.1.106, iPadOS 27.2 24B5110a,
    // UUID 56EB6C8F-D489-378F-AABA-81975A6D213E,
    // ___49+[UIPointerAccessory arrowAccessoryWithPosition:]_block_invoke 0x18506f954..0x18506f960,
    // +[UIPointerShape _shapeWithSymbol:pointSize:] 0x1858369b4..0x185836a40).
    private static let arrowAccessory: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8.53942, y: 8.11341))
        path.addCurve(to: CGPoint(x: 8.33447, y: 7.50042), control1: CGPoint(x: 8.53942, y: 7.89600), control2: CGPoint(x: 8.44785, y: 7.72407))
        path.addLine(to: CGPoint(x: 4.98736, y: 0.60803))
        path.addCurve(to: CGPoint(x: 4.27034, y: 0.00003), control1: CGPoint(x: 4.76248, y: 0.14457), control2: CGPoint(x: 4.55504, y: 0.00003))
        path.addCurve(to: CGPoint(x: 3.55207, y: 0.60803), control1: CGPoint(x: 3.98564, y: 0.00003), control2: CGPoint(x: 3.77820, y: 0.14457))
        path.addLine(to: CGPoint(x: 0.20620, y: 7.50042))
        path.addCurve(to: CGPoint(x: 0, y: 8.11902), control1: CGPoint(x: 0.09283, y: 7.72968), control2: CGPoint(x: 0, y: 7.90161))
        path.addCurve(to: CGPoint(x: 0.77185, y: 8.76627), control1: CGPoint(x: 0, y: 8.51895), control2: CGPoint(x: 0.30463, y: 8.76627))
        path.addLine(to: CGPoint(x: 7.76882, y: 8.76067))
        path.addCurve(to: CGPoint(x: 8.53942, y: 8.11341), control1: CGPoint(x: 8.24165, y: 8.76067), control2: CGPoint(x: 8.53942, y: 8.51335))
        path.closeSubpath()
        return path
    }()

    private static func cross(length: CGFloat, thickness: CGFloat) -> UIBezierPath {
        let path = UIBezierPath(rect: CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness))
        path.append(UIBezierPath(rect: CGRect(x: -thickness / 2, y: -length / 2, width: thickness, height: length)))
        return path
    }
}
#endif
