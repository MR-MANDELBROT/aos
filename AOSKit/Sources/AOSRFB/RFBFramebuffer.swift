import CoreGraphics
import Foundation

/// A rectangle in screen pixels.
public struct RFBRect: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var description: String { "\(x),\(y) \(width)x\(height)" }

    public func union(_ o: RFBRect) -> RFBRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return RFBRect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    public func intersection(_ o: RFBRect) -> RFBRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? RFBRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                                  : RFBRect(x: x0, y: y0, width: 0, height: 0)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Changed parts of the screen, kept as a few rectangles: neighbours merge when that adds little area.
struct RFBRegion: Equatable {
    private(set) var rects: [RFBRect] = []
    static let limit = 16

    var isEmpty: Bool { rects.isEmpty }

    mutating func add(_ rect: RFBRect) {
        guard !rect.isEmpty else { return }
        var r = rect
        var merged = true
        while merged {
            merged = false
            for (i, o) in rects.enumerated() {
                let u = r.union(o)
                // Merge when the union wastes at most a quarter (overlapping and touching rects always merge).
                if u.area * 4 <= (r.area + o.area) * 5 || o.intersection(r).area > 0 && u.area <= r.area + o.area {
                    r = u
                    rects.remove(at: i)
                    merged = true
                    break
                }
            }
        }
        rects.append(r)
        if rects.count > Self.limit {
            rects = [rects.dropFirst().reduce(rects[0]) { $0.union($1) }]
        }
    }

    mutating func removeAll() { rects.removeAll() }

    var bounds: RFBRect { rects.dropFirst().reduce(rects.first ?? RFBRect(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) } }
}

/// The screen as the client knows it: 32-bit pixels (R | G << 8 | B << 16 | X << 24, so R, G, B, X in memory), safe
/// to read from any thread while the connection writes into it. Remembers what changed since a reader last looked.
public final class RFBFramebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt32] = []
    private var w = 0
    private var h = 0
    /// Changes readers may take (complete updates) and changes of the update being decoded.
    private var dirty = RFBRegion()
    private var pending = RFBRegion()
    private var generation = 0

    public init() {}

    public var width: Int { lock.withLock { w } }
    public var height: Int { lock.withLock { h } }
    public var size: CGSize { lock.withLock { CGSize(width: w, height: h) } }
    /// Changes whenever the size changes (a reader recreates its texture).
    public var sizeGeneration: Int { lock.withLock { generation } }
    public var hasChanges: Bool { lock.withLock { !dirty.isEmpty } }

    // MARK: Writing (the connection)

    /// A new size; the picture is black until the server sends it.
    func resize(width: Int, height: Int) {
        lock.withLock {
            w = max(0, width)
            h = max(0, height)
            storage = [UInt32](repeating: PixelConverter.opaque, count: w * h)
            generation += 1
            dirty.removeAll()
            pending.removeAll()
            pending.add(RFBRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Lets `body` write the pixels of `rect` (clipped to the screen): it gets the rect's top left pixel and the
    /// row stride in pixels. Returns false (and writes nothing) for a rect outside the screen.
    @discardableResult
    func write(_ rect: RFBRect, _ body: (UnsafeMutablePointer<UInt32>, Int) throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard !rect.isEmpty, rect.x >= 0, rect.y >= 0, rect.maxX <= w, rect.maxY <= h else { return false }
            try storage.withUnsafeMutableBufferPointer { buffer in
                try body(buffer.baseAddress! + rect.y * w + rect.x, w)
            }
            pending.add(rect)
            return true
        }
    }

    /// CopyRect: the pixels at `from` move to `rect`.
    func copy(from x: Int, _ y: Int, to rect: RFBRect) {
        lock.withLock {
            let source = RFBRect(x: x, y: y, width: rect.width, height: rect.height)
            guard !rect.isEmpty, rect.x >= 0, rect.y >= 0, rect.maxX <= w, rect.maxY <= h,
                  source.x >= 0, source.y >= 0, source.maxX <= w, source.maxY <= h else { return }
            storage.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                // Rows in the order that never overwrites a source row before it was copied.
                let rows: [Int] = y < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
                for row in rows {
                    memmove(base + (rect.y + row) * w + rect.x, base + (y + row) * w + x, rect.width * 4)
                }
            }
            pending.add(rect)
        }
    }

    /// The update is complete: readers see its changes. Returns true if readers had nothing to take before.
    @discardableResult
    func commit() -> Bool {
        lock.withLock {
            let wasClean = dirty.isEmpty
            for r in pending.rects { dirty.add(r) }
            pending.removeAll()
            return wasClean && !dirty.isEmpty
        }
    }

    // MARK: Reading

    /// What changed since the last call, with the pixels, under the lock (keep `body` short: copy or upload).
    public struct Changes {
        public let width: Int
        public let height: Int
        public let generation: Int
        public let rects: [RFBRect]
        /// The top left pixel of the screen.
        public let pixels: UnsafePointer<UInt32>
        /// Pixels per row.
        public let stride: Int
    }

    /// Calls `body` with the changes since the last call (if there are any) and forgets them.
    @discardableResult
    public func takeChanges(_ body: (Changes) -> Void) -> Bool {
        lock.withLock {
            guard !dirty.isEmpty, w > 0, h > 0 else { return false }
            let rects = dirty.rects
            dirty.removeAll()
            storage.withUnsafeBufferPointer { buffer in
                body(Changes(width: w, height: h, generation: generation, rects: rects, pixels: buffer.baseAddress!, stride: w))
            }
            return true
        }
    }

    /// Reads the whole screen under the lock (for a reader that starts fresh). Doesn't touch the changes.
    public func withPixels<T>(_ body: (_ pixels: UnsafePointer<UInt32>, _ width: Int, _ height: Int) -> T) -> T? {
        lock.withLock {
            guard w > 0, h > 0 else { return nil }
            return storage.withUnsafeBufferPointer { body($0.baseAddress!, w, h) }
        }
    }

    /// A copy of the screen as an image.
    public func makeImage() -> CGImage? {
        let copy: (Data, Int, Int)? = lock.withLock {
            guard w > 0, h > 0 else { return nil }
            return (storage.withUnsafeBytes { Data($0) }, w, h)
        }
        guard let (data, width, height) = copy, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// One pixel (tests and diagnostics).
    public func pixel(x: Int, y: Int) -> UInt32? {
        lock.withLock { x >= 0 && y >= 0 && x < w && y < h ? storage[y * w + x] : nil }
    }
}
