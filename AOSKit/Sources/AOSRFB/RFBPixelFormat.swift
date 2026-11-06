import Foundation

/// How pixels travel on the wire. Whatever the server sends, the framebuffer keeps 32-bit RGBX (see
/// `RFBFramebuffer`); fewer bits per pixel only save bandwidth.
public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: Int
    public var depth: Int
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: Int
    public var greenMax: Int
    public var blueMax: Int
    public var redShift: Int
    public var greenShift: Int
    public var blueShift: Int

    public init(bitsPerPixel: Int, depth: Int, bigEndian: Bool, trueColor: Bool, redMax: Int, greenMax: Int,
                blueMax: Int, redShift: Int, greenShift: Int, blueShift: Int) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// 32 bits, little endian, red in the lowest byte: R, G, B, X in memory, like the framebuffer.
    public static let rgb888 = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
                                              redMax: 255, greenMax: 255, blueMax: 255,
                                              redShift: 0, greenShift: 8, blueShift: 16)
    /// 16 bits, 5-6-5: a third less data than 24-bit colour, slight banding in gradients.
    public static let rgb565 = RFBPixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColor: true,
                                              redMax: 31, greenMax: 63, blueMax: 31,
                                              redShift: 11, greenShift: 5, blueShift: 0)
    /// 16 bits carrying 4-4-4 (4096 colours): zlib packs it much better than 5-6-5. screensharingd refuses depths
    /// below 12 (and 8 bits per pixel) by closing the connection (measured, macOS 27.2).
    public static let rgb444 = RFBPixelFormat(bitsPerPixel: 16, depth: 12, bigEndian: false, trueColor: true,
                                              redMax: 15, greenMax: 15, blueMax: 15,
                                              redShift: 8, greenShift: 4, blueShift: 0)
    /// 8 bits, 3-3-2 (servers other than macOS's).
    public static let bgr233 = RFBPixelFormat(bitsPerPixel: 8, depth: 8, bigEndian: false, trueColor: true,
                                              redMax: 7, greenMax: 7, blueMax: 3,
                                              redShift: 0, greenShift: 3, blueShift: 6)

    /// The 16 bytes of ServerInit or SetPixelFormat.
    init(wire d: Data) {
        let b = [UInt8](d.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - d.count))
        bitsPerPixel = Int(b[0])
        depth = Int(b[1])
        bigEndian = b[2] != 0
        trueColor = b[3] != 0
        redMax = Int(b[4]) << 8 | Int(b[5])
        greenMax = Int(b[6]) << 8 | Int(b[7])
        blueMax = Int(b[8]) << 8 | Int(b[9])
        redShift = Int(b[10])
        greenShift = Int(b[11])
        blueShift = Int(b[12])
    }

    var wire: Data {
        var d = Data([UInt8(bitsPerPixel), UInt8(depth), bigEndian ? 1 : 0, trueColor ? 1 : 0])
        d.appendBE(UInt16(redMax)); d.appendBE(UInt16(greenMax)); d.appendBE(UInt16(blueMax))
        d.append(contentsOf: [UInt8(redShift), UInt8(greenShift), UInt8(blueShift), 0, 0, 0])
        return d
    }

    /// The SetPixelFormat message.
    var message: Data { Data([0, 0, 0, 0]) + wire }

    public var bytesPerPixel: Int { max(1, bitsPerPixel / 8) }

    /// ZRLE's compressed pixel (CPIXEL): 3 bytes when 32-bit pixels carry their colour in the low (or high) 24 bits.
    var compactBytesPerPixel: Int {
        guard trueColor, bitsPerPixel == 32, depth <= 24 else { return bytesPerPixel }
        let used = (redMax << redShift) | (greenMax << greenShift) | (blueMax << blueShift)
        return used & ~0xFFFFFF == 0 || used & 0xFF == 0 ? 3 : 4
    }

    /// Whether a 3-byte CPIXEL holds the most significant bytes (the colour lives in bits 8 to 31).
    var compactUsesHighBytes: Bool {
        let used = (redMax << redShift) | (greenMax << greenShift) | (blueMax << blueShift)
        return used & ~0xFFFFFF != 0
    }

    var isValid: Bool {
        [8, 16, 32].contains(bitsPerPixel) && trueColor && redMax > 0 && greenMax > 0 && blueMax > 0
    }
}

/// Turns wire pixels into framebuffer pixels (UInt32: R | G << 8 | B << 16 | 0xFF << 24).
struct PixelConverter {
    let format: RFBPixelFormat
    /// For 8 and 16 bits: every possible value, converted once.
    private let table: [UInt32]
    /// 32-bit pixels already in the framebuffer's layout (only the X byte needs setting).
    private let identity: Bool
    let bytesPerPixel: Int
    let compactBytes: Int

    init(_ format: RFBPixelFormat) {
        self.format = format
        bytesPerPixel = format.bytesPerPixel
        compactBytes = format.compactBytesPerPixel
        identity = format.bitsPerPixel == 32 && !format.bigEndian && format.redShift == 0 && format.greenShift == 8
            && format.blueShift == 16 && format.redMax == 255 && format.greenMax == 255 && format.blueMax == 255
        if format.bitsPerPixel <= 16 {
            let count = 1 << format.bitsPerPixel
            var t = [UInt32](repeating: 0, count: count)
            for v in 0..<count { t[v] = Self.map(UInt32(v), format) }
            table = t
        } else {
            table = []
        }
    }

    static let opaque: UInt32 = 0xFF00_0000

    private static func scale(_ value: UInt32, _ max: Int) -> UInt32 {
        max == 255 ? value & 0xFF : (value * 255 + UInt32(max / 2)) / UInt32(max)
    }

    static func map(_ v: UInt32, _ f: RFBPixelFormat) -> UInt32 {
        let r = scale((v >> UInt32(f.redShift)) & UInt32(f.redMax), f.redMax)
        let g = scale((v >> UInt32(f.greenShift)) & UInt32(f.greenMax), f.greenMax)
        let b = scale((v >> UInt32(f.blueShift)) & UInt32(f.blueMax), f.blueMax)
        return r | g << 8 | b << 16 | opaque
    }

    /// The pixel value of `count` bytes at `p` in the wire byte order.
    @inline(__always)
    private func value(_ p: UnsafePointer<UInt8>, _ count: Int) -> UInt32 {
        switch count {
        case 1: return UInt32(p[0])
        case 2: return format.bigEndian ? UInt32(p[0]) << 8 | UInt32(p[1]) : UInt32(p[0]) | UInt32(p[1]) << 8
        case 3:
            // A CPIXEL keeps the byte order of the full pixel; with the colour in the high bytes it is shifted up.
            let v = format.bigEndian ? UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
                                     : UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
            return format.compactUsesHighBytes ? v << 8 : v
        default:
            return format.bigEndian ? UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
                                    : UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        }
    }

    /// One pixel of `count` bytes (`bytesPerPixel`, or `compactBytes` in ZRLE).
    @inline(__always)
    func pixel(_ p: UnsafePointer<UInt8>, _ count: Int) -> UInt32 {
        if identity && count >= 3 { return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | Self.opaque }
        let v = value(p, count)
        if !table.isEmpty { return table[Int(v) & (table.count - 1)] }
        return Self.map(v, format)
    }

    /// Converts `count` pixels of `size` bytes each from `src` into `dst`.
    func convert(_ src: UnsafePointer<UInt8>, size: Int, count: Int, into dst: UnsafeMutablePointer<UInt32>) {
        if identity && size == 4 {
            let raw = UnsafeRawPointer(src)
            for i in 0..<count { dst[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) | Self.opaque }
            return
        }
        var p = src
        for i in 0..<count {
            dst[i] = pixel(p, size)
            p += size
        }
    }
}
