import CoreGraphics
import Testing
@testable import ScreenClient

/// The card's picture: every picture fills the card from the top (aspect fill), a portrait one too.
struct CardPictureTests {
    private let card = CGSize(width: 320, height: 200)  // 16:10

    @Test func aPortraitPictureFillsTheWidthFromTheTop() {
        let frame = ComputerCard.thumbnailFrame(picture: CGSize(width: 1050, height: 2120), in: card)
        #expect(frame.minX == 0)
        #expect(frame.minY == 0)
        #expect(frame.width == 320)
        #expect(abs(frame.height - 320 * 2120 / 1050) < 0.001)
    }

    @Test func landscapePicturesStayAsTheyWere() {
        // 16:10 exactly fills the card
        #expect(ComputerCard.thumbnailFrame(picture: CGSize(width: 2560, height: 1600), in: card)
                == CGRect(x: 0, y: 0, width: 320, height: 200))
        // Wider: the full height, centered across (the sides cut)
        let wide = ComputerCard.thumbnailFrame(picture: CGSize(width: 2000, height: 1000), in: card)
        #expect(wide == CGRect(x: -40, y: 0, width: 400, height: 200))
        // A little taller (4:3): the full width from the top
        let fourThree = ComputerCard.thumbnailFrame(picture: CGSize(width: 1600, height: 1200), in: card)
        #expect(fourThree == CGRect(x: 0, y: 0, width: 320, height: 240))
    }

    @Test func nothingToDrawIsTheCardItself() {
        #expect(ComputerCard.thumbnailFrame(picture: .zero, in: card) == CGRect(origin: .zero, size: card))
        #expect(ComputerCard.thumbnailFrame(picture: CGSize(width: 10, height: 10), in: .zero) == .zero)
    }
}
