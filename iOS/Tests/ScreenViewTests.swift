import CoreGraphics
import Testing
import UIKit
@testable import aOS

/// Where a touch lands on the remote screen, at fit size and zoomed.
@MainActor
struct ScreenViewTests {
    private func picture(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    private func view() -> RemoteScreenView {
        let view = RemoteScreenView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.show(picture(width: 800, height: 500))
        view.layoutIfNeeded()
        return view
    }

    @Test func fitsTheScreenAndMapsTouches() {
        let view = view()
        // 800x500 in 400x300: scale 0.5, picture 400x250, 25 points above and below
        #expect(view.remotePoint(CGPoint(x: 200, y: 150)) == CGPoint(x: 400, y: 250))
        #expect(view.remotePoint(CGPoint(x: 0, y: 25)) == CGPoint(x: 0, y: 0))
        #expect(view.viewPoint(CGPoint(x: 800, y: 500)) == CGPoint(x: 400, y: 275))
    }

    @Test func zoomsOntoARegion() {
        let view = view()
        let region = CGRect(x: 600, y: 50, width: 100, height: 60)
        view.focus(on: region)
        view.layoutIfNeeded()
        // The region's center is in the middle of the view, and the region is bigger than at fit size
        let center = view.viewPoint(CGPoint(x: region.midX, y: region.midY))
        #expect(abs(center.x - 200) < 1 || view.viewPoint(CGPoint(x: 800, y: 0)).x <= 400.5)  // at the right edge it stops
        let size = view.viewPoint(CGPoint(x: region.maxX, y: region.maxY)).x - view.viewPoint(CGPoint(x: region.minX, y: region.minY)).x
        #expect(size > 50)
        // Touches still land on the right pixels
        let p = view.viewPoint(CGPoint(x: 620, y: 70))
        let back = view.remotePoint(p)
        #expect(abs(back.x - 620) < 0.01 && abs(back.y - 70) < 0.01)

        view.zoomToFit()
        view.layoutIfNeeded()
        #expect(view.remotePoint(CGPoint(x: 200, y: 150)) == CGPoint(x: 400, y: 250))
    }

    @Test func thePictureNeverLeavesAGapAtTheEdges() {
        let view = view()
        view.focus(on: CGRect(x: 0, y: 0, width: 40, height: 40))  // the top left corner
        view.layoutIfNeeded()
        let topLeft = view.viewPoint(.zero)
        #expect(topLeft.x <= 0.5 && topLeft.y <= 0.5)
    }
}
