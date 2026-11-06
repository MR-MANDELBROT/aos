import CoreGraphics
import Foundation
import zlib

/// RFB encoding numbers (RFC 6143 and the registry; the negative ones are pseudo-encodings).
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let hextile: Int32 = 5
    public static let zlib: Int32 = 6
    public static let zrle: Int32 = 16
    /// The pointer's shape travels as a picture and the client draws it (the server leaves it out of the screen).
    public static let richCursor: Int32 = -239
    /// The server reports where the pointer moved (the agent or the Mac's own user moved it).
    public static let pointerPosition: Int32 = -232
    public static let lastRect: Int32 = -224
    public static let desktopSize: Int32 = -223
    public static let extendedDesktopSize: Int32 = -308
    public static let continuousUpdates: Int32 = -313
    /// macOS screen sharing's own picture encodings (zlib data, each with a stream of its own): 1 bit black and
    /// white, 4 bit gray, 15 bit colour. They work with the standard protocol too (measured, macOS 27.2).
    public static let appleHalftone: Int32 = 1000
    public static let appleGray: Int32 = 1001
    public static let appleThousands: Int32 = 1002

    public static func name(_ e: Int32) -> String {
        switch e {
        case raw: "raw"
        case copyRect: "copyrect"
        case hextile: "hextile"
        case zlib: "zlib"
        case zrle: "zrle"
        case richCursor: "cursor"
        case pointerPosition: "pointer-position"
        case lastRect: "last-rect"
        case desktopSize: "desktop-size"
        case extendedDesktopSize: "extended-desktop-size"
        case continuousUpdates: "continuous-updates"
        case appleHalftone: "apple-halftone"
        case appleGray: "apple-gray"
        case appleThousands: "apple-thousands"
        default: "encoding \(e)"
        }
    }
}

/// The pointer's picture as the server sends it (premultiplied RGBA) and the point in it that clicks.
public struct RFBCursor: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hotX: Int
    public var hotY: Int
    /// R, G, B, A per pixel, premultiplied.
    public var rgba: [UInt8]

    public var isEmpty: Bool { width == 0 || height == 0 }

    public func makeImage() -> CGImage? {
        guard !isEmpty, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A zlib stream that lasts as long as the connection (zlib and ZRLE rectangles continue one stream each).
final class Inflater {
    private var stream = z_stream()
    private var ready = false

    init() throws {
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.protocolError("zlib")
        }
        ready = true
    }

    deinit {
        if ready { inflateEnd(&stream) }
    }

    /// Inflates all of `input` (one rectangle's data, which ends at a flush point) and returns what comes out.
    /// `exactly`: the size the output must have.
    func inflate(_ input: Data, sizeHint: Int, exactly: Int? = nil) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(exactly ?? sizeHint, 256))
        var produced = 0
        var status: Int32 = Z_OK
        input.withUnsafeBytes { (inp: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: inp.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                if produced == out.count {
                    if exactly != nil { break }
                    out.append(contentsOf: repeatElement(0, count: out.count))
                }
                status = out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) -> Int32 in
                    stream.next_out = o.bindMemory(to: Bytef.self).baseAddress! + produced
                    stream.avail_out = uInt(o.count - produced)
                    let s = zlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = o.count - Int(stream.avail_out)
                    return s
                }
                if status == Z_BUF_ERROR { status = Z_OK; break }   // nothing more to do
                if status != Z_OK { break }
                if stream.avail_in == 0 && stream.avail_out > 0 { break }
            }
            stream.next_in = nil
            stream.next_out = nil
        }
        guard status == Z_OK || status == Z_STREAM_END else { throw RFBError.protocolError("zlib \(status)") }
        if let exactly, produced != exactly { throw RFBError.protocolError("zlib rectangle of \(produced) bytes, expected \(exactly)") }
        out.removeSubrange(produced...)
        return out
    }
}

/// Reads bytes of a decoded rectangle; every read checks the length (a broken stream throws, never crashes).
struct ByteReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var offset = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        count = buffer.count
    }

    var remaining: Int { count - offset }

    @inline(__always)
    mutating func need(_ n: Int) throws -> UnsafePointer<UInt8> {
        guard n >= 0, offset + n <= count else { throw RFBError.protocolError("rectangle data ends early") }
        let p = base + offset
        offset += n
        return p
    }

    @inline(__always)
    mutating func u8() throws -> UInt8 { try need(1).pointee }

    /// A run length: 1 plus the sum of bytes, continued while a byte is 255.
    @inline(__always)
    mutating func runLength() throws -> Int {
        var length = 1
        while true {
            let b = try u8()
            length += Int(b)
            if b != 255 { return length }
        }
    }
}

/// Decodes rectangle data into the framebuffer. One per connection: it owns the zlib streams.
final class RFBDecoder {
    private(set) var converter: PixelConverter
    private var zlibStream: Inflater?
    private var zrleStream: Inflater?
    private var appleStreams: [Int32: Inflater] = [:]

    init(format: RFBPixelFormat) {
        converter = PixelConverter(format)
    }

    var format: RFBPixelFormat { converter.format }

    func setFormat(_ format: RFBPixelFormat) {
        if format != converter.format { converter = PixelConverter(format) }
    }

    /// Bytes of raw data for a rectangle.
    func rawSize(_ rect: RFBRect) -> Int { rect.width * rect.height * converter.bytesPerPixel }

    func raw(_ data: Data, rect: RFBRect, into fb: RFBFramebuffer) {
        let bpp = converter.bytesPerPixel
        guard data.count >= rect.area * bpp else { return }
        let converter = self.converter
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.bindMemory(to: UInt8.self).baseAddress!
            fb.write(rect) { dst, stride in
                for row in 0..<rect.height {
                    converter.convert(s + row * rect.width * bpp, size: bpp, count: rect.width, into: dst + row * stride)
                }
            }
        }
    }

    func zlib(_ data: Data, rect: RFBRect, into fb: RFBFramebuffer) throws {
        if zlibStream == nil { zlibStream = try Inflater() }
        let size = rawSize(rect)
        let out = try zlibStream!.inflate(data, sizeHint: size, exactly: size)
        raw(Data(out), rect: rect, into: fb)
    }

    /// Bytes per row of Apple's encodings.
    static func appleRowBytes(_ encoding: Int32, width: Int) -> Int {
        switch encoding {
        case RFBEncoding.appleHalftone: (width + 7) / 8
        case RFBEncoding.appleGray: (width + 1) / 2
        default: width * 2
        }
    }

    /// Apple's halftone (1 bit, set is white), gray (4 bits, high nibble first) and thousands (16 bits big endian,
    /// x-5-5-5) pictures; rows padded to whole bytes.
    func apple(_ encoding: Int32, _ data: Data, rect: RFBRect, into fb: RFBFramebuffer) throws {
        if appleStreams[encoding] == nil { appleStreams[encoding] = try Inflater() }
        let rowBytes = Self.appleRowBytes(encoding, width: rect.width)
        let out = try appleStreams[encoding]!.inflate(data, sizeHint: rowBytes * rect.height, exactly: rowBytes * rect.height)
        Self.decodeApple(encoding, out, rect: rect, into: fb)
    }

    static func decodeApple(_ encoding: Int32, _ bytes: [UInt8], rect: RFBRect, into fb: RFBFramebuffer) {
        let rowBytes = appleRowBytes(encoding, width: rect.width)
        guard bytes.count >= rowBytes * rect.height else { return }
        @inline(__always) func gray(_ v: UInt32) -> UInt32 { v | v << 8 | v << 16 | PixelConverter.opaque }
        bytes.withUnsafeBufferPointer { src in
            fb.write(rect) { dst, stride in
                for y in 0..<rect.height {
                    let row = src.baseAddress! + y * rowBytes
                    let out = dst + y * stride
                    switch encoding {
                    case RFBEncoding.appleHalftone:
                        for x in 0..<rect.width { out[x] = row[x >> 3] & (0x80 >> UInt8(x & 7)) != 0 ? gray(255) : gray(0) }
                    case RFBEncoding.appleGray:
                        for x in 0..<rect.width {
                            let nibble = UInt32(x & 1 == 0 ? row[x >> 1] >> 4 : row[x >> 1] & 0x0F)
                            out[x] = gray(nibble == 15 ? 255 : nibble * 16)
                        }
                    default:
                        for x in 0..<rect.width {
                            let v = UInt32(row[2 * x]) << 8 | UInt32(row[2 * x + 1])
                            @inline(__always) func five(_ c: UInt32) -> UInt32 { c << 3 | c >> 2 }
                            out[x] = five(v >> 10 & 0x1F) | five(v >> 5 & 0x1F) << 8 | five(v & 0x1F) << 16 | PixelConverter.opaque
                        }
                    }
                }
            }
        }
    }

    /// ZRLE (RFC 6143 7.7.6): zlib data of 64x64 tiles, each raw, solid, packed palette, RLE or palette RLE.
    func zrle(_ data: Data, rect: RFBRect, into fb: RFBFramebuffer) throws {
        if zrleStream == nil { zrleStream = try Inflater() }
        let tiles = try zrleStream!.inflate(data, sizeHint: max(4096, rect.area))
        try Self.decodeZRLETiles(tiles, rect: rect, converter: converter, into: fb)
    }

    /// The tiles of a ZRLE rectangle, already inflated.
    static func decodeZRLETiles(_ tiles: [UInt8], rect: RFBRect, converter: PixelConverter, into fb: RFBFramebuffer) throws {
        let cpixel = converter.compactBytes
        var failure: Error?
        tiles.withUnsafeBufferPointer { buffer in
            var reader = ByteReader(buffer)
            let written = fb.write(rect) { base, stride in
                do {
                    var palette = [UInt32](repeating: 0, count: 128)
                    var ty = 0
                    while ty < rect.height {
                        let th = min(64, rect.height - ty)
                        var tx = 0
                        while tx < rect.width {
                            let tw = min(64, rect.width - tx)
                            let tile = base + ty * stride + tx
                            try decodeTile(&reader, tile: tile, stride: stride, tw: tw, th: th, cpixel: cpixel,
                                           converter: converter, palette: &palette)
                            tx += 64
                        }
                        ty += 64
                    }
                } catch {
                    failure = error
                }
            }
            if !written && failure == nil { failure = RFBError.protocolError("ZRLE rectangle \(rect) outside the screen") }
        }
        if let failure { throw failure }
    }

    @inline(__always)
    private static func decodeTile(_ r: inout ByteReader, tile: UnsafeMutablePointer<UInt32>, stride: Int, tw: Int, th: Int,
                                   cpixel: Int, converter: PixelConverter, palette: inout [UInt32]) throws {
        let sub = Int(try r.u8())
        let total = tw * th
        switch sub {
        case 0:  // raw
            let p = try r.need(total * cpixel)
            for row in 0..<th {
                converter.convert(p + row * tw * cpixel, size: cpixel, count: tw, into: tile + row * stride)
            }
        case 1:  // solid
            let color = converter.pixel(try r.need(cpixel), cpixel)
            for row in 0..<th {
                (tile + row * stride).update(repeating: color, count: tw)
            }
        case 2...16:  // packed palette
            for i in 0..<sub { palette[i] = converter.pixel(try r.need(cpixel), cpixel) }
            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
            let rowBytes = (tw * bits + 7) / 8
            let mask = (1 << bits) - 1
            for row in 0..<th {
                let p = try r.need(rowBytes)
                let dst = tile + row * stride
                for x in 0..<tw {
                    let bit = x * bits
                    let index = (Int(p[bit >> 3]) >> (8 - bits - (bit & 7))) & mask
                    guard index < sub else { throw RFBError.protocolError("ZRLE palette index") }
                    dst[x] = palette[index]
                }
            }
        case 128:  // plain RLE
            var i = 0
            while i < total {
                let color = converter.pixel(try r.need(cpixel), cpixel)
                let run = try r.runLength()
                guard i + run <= total else { throw RFBError.protocolError("ZRLE run") }
                fill(tile, stride: stride, tw: tw, from: i, count: run, color: color)
                i += run
            }
        case 130...255:  // palette RLE
            let size = sub - 128
            for i in 0..<size { palette[i] = converter.pixel(try r.need(cpixel), cpixel) }
            var i = 0
            while i < total {
                let b = Int(try r.u8())
                let index = b & 0x7F
                guard index < size else { throw RFBError.protocolError("ZRLE palette index") }
                let run = b & 0x80 != 0 ? try r.runLength() : 1
                guard i + run <= total else { throw RFBError.protocolError("ZRLE run") }
                fill(tile, stride: stride, tw: tw, from: i, count: run, color: palette[index])
                i += run
            }
        default:
            throw RFBError.protocolError("ZRLE subencoding \(sub)")
        }
    }

    /// A run of `count` pixels from pixel `start` of a tile (in rows of `tw`).
    @inline(__always)
    private static func fill(_ tile: UnsafeMutablePointer<UInt32>, stride: Int, tw: Int, from start: Int, count: Int,
                             color: UInt32) {
        var i = start
        let end = start + count
        while i < end {
            let x = i % tw, y = i / tw
            let n = min(tw - x, end - i)
            (tile + y * stride + x).update(repeating: color, count: n)
            i += n
        }
    }

    /// Bytes of a rich cursor rectangle: the pixels and a bit mask, rows padded to bytes.
    func cursorSize(_ rect: RFBRect) -> Int {
        rect.area * converter.bytesPerPixel + (rect.width + 7) / 8 * rect.height
    }

    /// The pointer's shape (RichCursor): pixels in the pixel format, then the mask (1: the pixel is shown).
    func cursor(_ data: Data, rect: RFBRect) -> RFBCursor {
        let bpp = converter.bytesPerPixel
        let w = rect.width, h = rect.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let maskRow = (w + 7) / 8
        guard w > 0, h > 0, data.count >= cursorSize(rect) else {
            return RFBCursor(width: 0, height: 0, hotX: 0, hotY: 0, rgba: [])
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            let mask = p + w * h * bpp
            for y in 0..<h {
                for x in 0..<w {
                    guard mask[y * maskRow + x / 8] & (0x80 >> UInt8(x % 8)) != 0 else { continue }
                    let v = converter.pixel(p + (y * w + x) * bpp, bpp)
                    let o = (y * w + x) * 4
                    rgba[o] = UInt8(v & 0xFF)
                    rgba[o + 1] = UInt8(v >> 8 & 0xFF)
                    rgba[o + 2] = UInt8(v >> 16 & 0xFF)
                    rgba[o + 3] = 255
                }
            }
        }
        return RFBCursor(width: w, height: h, hotX: rect.x, hotY: rect.y, rgba: rgba)
    }
}
