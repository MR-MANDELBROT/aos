// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import CoreGraphics
import ImageIO

nonisolated struct PictureTurns: Equatable, Sendable {
    static let none = PictureTurns(0)

    let count: Int

    init(_ count: Int) {
        self.count = count & 3
    }

    var isSideways: Bool { count % 2 == 1 }

    func shownSize(of size: CGSize) -> CGSize {
        isSideways ? CGSize(width: size.height, height: size.width) : size
    }

    func shownPoint(_ point: CGPoint, inPictureOf size: CGSize) -> CGPoint {
        let right = size.width - 1
        let bottom = size.height - 1
        return switch count {
        case 1: CGPoint(x: bottom - point.y, y: point.x)
        case 2: CGPoint(x: right - point.x, y: bottom - point.y)
        case 3: CGPoint(x: point.y, y: right - point.x)
        default: point
        }
    }

    func picturePoint(_ point: CGPoint, inPictureOf size: CGSize) -> CGPoint {
        let right = size.width - 1
        let bottom = size.height - 1
        return switch count {
        case 1: CGPoint(x: point.y, y: bottom - point.x)
        case 2: CGPoint(x: right - point.x, y: bottom - point.y)
        case 3: CGPoint(x: right - point.y, y: point.x)
        default: point
        }
    }

    func pictureVector(_ vector: CGPoint) -> CGPoint {
        switch count {
        case 1: CGPoint(x: vector.y, y: -vector.x)
        case 2: CGPoint(x: -vector.x, y: -vector.y)
        case 3: CGPoint(x: -vector.y, y: vector.x)
        default: vector
        }
    }

    func shownRect(ofUnit rect: CGRect) -> CGRect {
        switch count {
        case 1: CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2: CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 3: CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: rect
        }
    }

    var imageOrientation: CGImagePropertyOrientation {
        switch count {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }
}
