import CoreGraphics
import XCTest
import zlib
@testable import AOSKit
@testable import AOSRFB

/// A zlib stream like a server's: one per encoding, each rectangle flushed (Z_SYNC_FLUSH).
private final class Deflater {
    private var stream = z_stream()

    init() {
        _ = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit { deflateEnd(&stream) }

    func compress(_ bytes: [UInt8]) -> Data {
        var input = bytes
        var out = [UInt8](repeating: 0, count: bytes.count + 1024)
        input.withUnsafeMutableBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                stream.next_in = i.baseAddress
                stream.avail_in = uInt(i.count)
                stream.next_out = o.baseAddress
                stream.avail_out = uInt(o.count)
                _ = deflate(&stream, Z_SYNC_FLUSH)
            }
        }
        return Data(out.prefix(out.count - Int(stream.avail_out)))
    }
}

/// Framebuffer pixels: R | G << 8 | B << 16 | 0xFF << 24.
private func px(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 { r | g << 8 | b << 16 | 0xFF00_0000 }

final class RFBDecoderTests: XCTestCase {
    private func framebuffer(_ w: Int, _ h: Int) -> RFBFramebuffer {
        let fb = RFBFramebuffer()
        fb.resize(width: w, height: h)
        fb.commit()
        fb.takeChanges { _ in }
        return fb
    }

    // MARK: ZRLE

    func testZRLETilesOfEveryKind() throws {
        // 70x66: tiles 64x64, 6x64, 64x2, 6x2 (left to right, top to bottom)
        let rect = RFBRect(x: 0, y: 0, width: 70, height: 66)
        let red: [UInt8] = [255, 0, 0], green: [UInt8] = [0, 255, 0], blue: [UInt8] = [0, 0, 255]
        var tiles: [UInt8] = []
        // 1: solid red
        tiles += [1] + red
        // 2: packed palette of two (1 bit per pixel, rows of 6 pixels padded to a byte): stripes per column
        tiles += [2] + green + blue
        for _ in 0..<64 { tiles += [0b0101_0100] }  // columns 0..5: green blue green blue green blue
        // 3: plain RLE: 100 pixels blue, the rest (28) red, run lengths as sums
        tiles += [128] + blue + [99] + red + [27]
        // 4: palette RLE: green run of 5, then one blue alone, then 6 green
        tiles += [130] + green + blue + [0x80, 4, 1, 0x80, 5]
        let fb = framebuffer(70, 66)
        let decoder = RFBDecoder(format: .rgb888)
        try decoder.zrle(Deflater().compress(tiles), rect: rect, into: fb)

        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 63, y: 63), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 64, y: 10), px(0, 255, 0))
        XCTAssertEqual(fb.pixel(x: 65, y: 10), px(0, 0, 255))
        XCTAssertEqual(fb.pixel(x: 69, y: 63), px(0, 0, 255))
        // tile 3 is 64 wide: pixel 99 is (35, 64 + 1), pixel 100 (36, 65)
        XCTAssertEqual(fb.pixel(x: 35, y: 65), px(0, 0, 255))
        XCTAssertEqual(fb.pixel(x: 36, y: 65), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 63, y: 65), px(255, 0, 0))
        // tile 4 is 6 wide: pixels 0-4 green, 5 blue, 6-11 green
        XCTAssertEqual(fb.pixel(x: 68, y: 64), px(0, 255, 0))
        XCTAssertEqual(fb.pixel(x: 69, y: 64), px(0, 0, 255))
        XCTAssertEqual(fb.pixel(x: 64, y: 65), px(0, 255, 0))
        XCTAssertEqual(fb.pixel(x: 69, y: 65), px(0, 255, 0))
    }

    func testZRLERawTileAndTheStreamGoesOn() throws {
        let fb = framebuffer(4, 2)
        let decoder = RFBDecoder(format: .rgb888)
        let deflater = Deflater()
        var raw: [UInt8] = [0]
        for i in 0..<8 { raw += [UInt8(i * 10), UInt8(i * 20), UInt8(i * 30)] }
        try decoder.zrle(deflater.compress(raw), rect: RFBRect(x: 0, y: 0, width: 4, height: 2), into: fb)
        XCTAssertEqual(fb.pixel(x: 3, y: 1), px(70, 140, 210))
        // The second rectangle continues the same zlib stream (its data alone isn't a complete stream).
        try decoder.zrle(deflater.compress([1, 9, 8, 7]), rect: RFBRect(x: 1, y: 0, width: 2, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 2, y: 0), px(9, 8, 7))
        XCTAssertEqual(fb.pixel(x: 3, y: 0), px(30, 60, 90))
    }

    func testZRLEWithSixteenBitPixels() throws {
        // 5-6-5, little endian: pure red is 0xF800 -> bytes 00 F8
        let fb = framebuffer(2, 1)
        let decoder = RFBDecoder(format: .rgb565)
        try decoder.zrle(Deflater().compress([0, 0x00, 0xF8, 0x1F, 0x00]), rect: RFBRect(x: 0, y: 0, width: 2, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 1, y: 0), px(0, 0, 255))
    }

    func testTwelveBitColoursScaleToFullRange() throws {
        // 4-4-4 in 16 bits: 0x0F00 is full red, 0x0888 middle gray
        let fb = framebuffer(2, 1)
        let decoder = RFBDecoder(format: .rgb444)
        try decoder.zrle(Deflater().compress([0, 0x00, 0x0F, 0x88, 0x08]), rect: RFBRect(x: 0, y: 0, width: 2, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 1, y: 0), px(136, 136, 136))
    }

    func testBrokenZRLEThrowsInsteadOfCrashing() {
        let decoder = RFBDecoder(format: .rgb888)
        let rect = RFBRect(x: 0, y: 0, width: 8, height: 8)
        // a raw tile that ends early, a palette index past the palette, an unknown subencoding, a run past the tile
        for tiles: [UInt8] in [[0, 1, 2, 3], [2, 1, 1, 1, 2, 2, 2, 0xFF], [129], [128, 1, 2, 3, 255, 255, 10]] {
            XCTAssertThrowsError(try decoder.zrle(Deflater().compress(tiles), rect: rect, into: framebuffer(8, 8)))
        }
        // and a rectangle outside the screen
        XCTAssertThrowsError(try RFBDecoder(format: .rgb888).zrle(Deflater().compress([1, 0, 0, 0]),
                                                                  rect: RFBRect(x: 4, y: 4, width: 8, height: 8),
                                                                  into: framebuffer(8, 8)))
    }

    // MARK: Other encodings

    func testZlibRectangles() throws {
        let fb = framebuffer(2, 2)
        let decoder = RFBDecoder(format: .rgb888)
        let pixels: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0]
        try decoder.zlib(Deflater().compress(pixels), rect: RFBRect(x: 0, y: 0, width: 2, height: 2), into: fb)
        XCTAssertEqual(fb.pixel(x: 1, y: 1), px(10, 11, 12))
        XCTAssertThrowsError(try decoder.zlib(Deflater().compress([1, 2, 3]), rect: RFBRect(x: 0, y: 0, width: 2, height: 2), into: fb))
    }

    func testCopyRectOverlapping() {
        let fb = framebuffer(4, 1)
        let decoder = RFBDecoder(format: .rgb888)
        decoder.raw(Data([1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0]), rect: RFBRect(x: 0, y: 0, width: 4, height: 1), into: fb)
        fb.copy(from: 0, 0, to: RFBRect(x: 1, y: 0, width: 3, height: 1))
        XCTAssertEqual((0..<4).map { fb.pixel(x: $0, y: 0)! & 0xFF }, [1, 1, 2, 3])
    }

    func testApplesGrayHalftoneAndThousands() {
        let fb = framebuffer(3, 1)
        RFBDecoder.decodeApple(RFBEncoding.appleGray, [0xF0, 0x80], rect: RFBRect(x: 0, y: 0, width: 3, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 255, 255))
        XCTAssertEqual(fb.pixel(x: 1, y: 0), px(0, 0, 0))
        XCTAssertEqual(fb.pixel(x: 2, y: 0), px(128, 128, 128))
        RFBDecoder.decodeApple(RFBEncoding.appleHalftone, [0b1010_0000], rect: RFBRect(x: 0, y: 0, width: 3, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 255, 255))
        XCTAssertEqual(fb.pixel(x: 1, y: 0), px(0, 0, 0))
        // x-5-5-5 big endian: red 0x7C00, green 0x03E0
        RFBDecoder.decodeApple(RFBEncoding.appleThousands, [0x7C, 0x00, 0x03, 0xE0, 0, 0x1F], rect: RFBRect(x: 0, y: 0, width: 3, height: 1), into: fb)
        XCTAssertEqual(fb.pixel(x: 0, y: 0), px(255, 0, 0))
        XCTAssertEqual(fb.pixel(x: 1, y: 0), px(0, 255, 0))
        XCTAssertEqual(fb.pixel(x: 2, y: 0), px(0, 0, 255))
    }

    func testRichCursorUsesItsMask() {
        let decoder = RFBDecoder(format: .rgb888)
        // 2x2: white, black / black, white; mask shows only the top left and bottom right
        let data = Data([255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 0, 0b1000_0000, 0b0100_0000])
        let cursor = decoder.cursor(data, rect: RFBRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(cursor.hotX, 1)
        XCTAssertEqual(Array(cursor.rgba[0..<4]), [255, 255, 255, 255])
        XCTAssertEqual(Array(cursor.rgba[4..<8]), [0, 0, 0, 0])
        XCTAssertEqual(Array(cursor.rgba[12..<16]), [255, 255, 255, 255])
        XCTAssertNotNil(cursor.makeImage())
    }

    // MARK: Framebuffer

    func testChangesComeOnlyAfterTheUpdateIsComplete() {
        let fb = framebuffer(100, 100)
        XCTAssertFalse(fb.hasChanges)
        RFBDecoder(format: .rgb888).raw(Data(repeating: 9, count: 4 * 4), rect: RFBRect(x: 10, y: 10, width: 2, height: 2), into: fb)
        XCTAssertFalse(fb.hasChanges, "a reader sees nothing of a half decoded update")
        XCTAssertTrue(fb.commit())
        XCTAssertFalse(fb.commit(), "the reader has something to take already")
        var rects: [RFBRect] = []
        fb.takeChanges { rects = $0.rects }
        XCTAssertEqual(rects, [RFBRect(x: 10, y: 10, width: 2, height: 2)])
        XCTAssertFalse(fb.hasChanges)
    }

    func testRegionMergesNeighboursAndStaysSmall() {
        var region = RFBRegion()
        region.add(RFBRect(x: 0, y: 0, width: 64, height: 64))
        region.add(RFBRect(x: 64, y: 0, width: 64, height: 64))
        XCTAssertEqual(region.rects, [RFBRect(x: 0, y: 0, width: 128, height: 64)])
        region.add(RFBRect(x: 500, y: 500, width: 10, height: 10))
        XCTAssertEqual(region.rects.count, 2)
        for i in 0..<40 { region.add(RFBRect(x: i * 50, y: 1000 + (i % 2) * 300, width: 5, height: 5)) }
        XCTAssertLessThanOrEqual(region.rects.count, RFBRegion.limit)
        XCTAssertEqual(region.bounds.maxY, 1305)
    }

    // MARK: Display requests

    func testDisplayRequestsHaveThePhonesShapeAndRoomForMacOS() throws {
        // iPhone 17 Pro portrait, without the safe area: 402x778 points
        let portrait = try XCTUnwrap(DisplayRequest.fitting(points: CGSize(width: 402, height: 778), retina: true))
        XCTAssertEqual(portrait.scale, 2)
        XCTAssertEqual(portrait.width, 1200)
        XCTAssertEqual(Double(portrait.height) / Double(portrait.width), 778.0 / 402, accuracy: 0.01)
        let landscape = try XCTUnwrap(DisplayRequest.fitting(points: CGSize(width: 750, height: 381), retina: false))
        XCTAssertEqual(landscape.scale, 1)
        XCTAssertEqual(landscape.height, 600)
        XCTAssertEqual(landscape.pixelsPerInch, 110)
        XCTAssertEqual(portrait.pixelsPerInch, 160)
        // An iPad already has room: its own shape and size in points
        let pad = try XCTUnwrap(DisplayRequest.fitting(points: CGSize(width: 1180, height: 820), retina: true))
        XCTAssertEqual(pad, DisplayRequest(width: 2360, height: 1640, scale: 2))
    }

    func testDisplayRequestTextAndLimits() {
        XCTAssertEqual(DisplayRequest("1200x2322@2"), DisplayRequest(width: 1200, height: 2322, scale: 2))
        XCTAssertEqual(DisplayRequest(width: 1200, height: 2322, scale: 2).description, "1200x2322@2")
        XCTAssertNil(DisplayRequest("1200x2322@3"))
        XCTAssertNil(DisplayRequest("1200x@2"))
        XCTAssertNil(DisplayRequest("reset"))
        let huge = DisplayRequest(width: 10000, height: 5000, scale: 2).clamped()
        XCTAssertEqual(huge.width, 4096)
        XCTAssertEqual(huge.height, 2048)
        let odd = DisplayRequest(width: 1201, height: 101, scale: 2).clamped()
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height, 640)
    }

    @MainActor
    func testTheAgentsPicturesStaySmall() {
        XCTAssertEqual(WorkspaceController.agentScale(width: 1280, height: 800), 1)
        XCTAssertEqual(WorkspaceController.agentScale(width: 1200, height: 2560), 0.5)
        XCTAssertEqual(WorkspaceController.agentScale(width: 600, height: 1160), 1)
    }

    /// The phone's display request: signed (target and size), refused while the workspace is off.
    @MainActor
    func testTheDisplayRequestIsSignedAndNeedsARunningWorkspace() async throws {
        let phone = TestPhone()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aos-display-\(UUID().uuidString)")
        let paths = Paths(root: root)
        try paths.prepare()
        let c = WorkspaceController(paths: paths, bitwarden: BitwardenVault(paths: paths, store: MemorySessionStore()),
                                    phoneKeys: MemoryPhoneKeys([phone.trusted]))
        var request = AgentRequest(id: 1, op: "companion.display")
        request.target = "workspace"
        request.text = "1200x2322@2"
        let unsigned = await c.handle(request)
        XCTAssertEqual(unsigned.code, "pair-again")
        let off = await c.handle(phone.sign(request))
        XCTAssertFalse(off.ok)
        XCTAssertEqual(off.text, "The workspace is not running.")
        // A size changed on its way breaks the signature
        let signed = phone.sign(request)
        var changed = signed
        changed.text = "4000x4000@2"
        let refused = await c.handle(changed)
        XCTAssertEqual(refused.code, "invalid")
        var mac = request
        mac.target = "mac"
        let notTheMac = await c.handle(phone.sign(mac))
        XCTAssertEqual(notTheMac.text, "Only the workspace's display can change.")
        XCTAssertNil(c.host.displayOverride)
        XCTAssertEqual(c.host.displaySize, CGSize(width: 1280, height: 800))
    }
}
