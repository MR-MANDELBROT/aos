import AOSRFB
import CoreGraphics
import Metal
import QuartzCore
import UIKit

/// Draws the remote screen with Metal: a texture that takes only the rectangles that changed, shown with mipmaps
/// when the picture is smaller than its pixels (a 2400 pixel wide screen on a 1200 pixel phone stays crisp instead of
/// shimmering) and plain linear filtering when it is larger.
@MainActor
final class ScreenRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture?
    private var generation = -1
    /// The mipmaps are older than the picture.
    private var mipmapsStale = true
    private var lastCommands: MTLCommandBuffer?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        self.sampler = sampler
    }

    /// The picture's size in pixels (zero before the first one).
    var imageSize: CGSize { texture.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                         mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// Takes what changed in the framebuffer. Returns true if the picture changed.
    @discardableResult
    func update(from framebuffer: RFBFramebuffer) -> Bool {
        // The GPU may still read the texture for the last frame: CPU writes wait for it (drawing takes well under a
        // millisecond).
        lastCommands?.waitUntilCompleted()
        var changed = false
        framebuffer.takeChanges { c in
            if texture == nil || c.generation != generation || texture!.width != c.width || texture!.height != c.height {
                texture = makeTexture(width: c.width, height: c.height)
                generation = c.generation
                guard let texture else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, c.width, c.height), mipmapLevel: 0,
                                withBytes: c.pixels, bytesPerRow: c.stride * 4)
            } else if let texture {
                for r in c.rects {
                    let rect = r.intersection(RFBRect(x: 0, y: 0, width: c.width, height: c.height))
                    guard !rect.isEmpty else { continue }
                    texture.replace(region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height), mipmapLevel: 0,
                                    withBytes: c.pixels + rect.y * c.stride + rect.x, bytesPerRow: c.stride * 4)
                }
            }
            changed = true
        }
        if changed { mipmapsStale = true }
        return changed
    }

    /// A still picture (the demo, tests).
    func show(_ image: CGImage) {
        lastCommands?.waitUntilCompleted()
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if texture?.width != w || texture?.height != h { texture = makeTexture(width: w, height: h) }
        generation = -1
        pixels.withUnsafeBytes { buffer in
            texture?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buffer.baseAddress!,
                             bytesPerRow: w * 4)
        }
        mipmapsStale = true
    }

    /// Draws the picture into `layer` at `picture` (view points) of a view of `size` points.
    func draw(in layer: CAMetalLayer, picture: CGRect, size: CGSize) {
        guard size.width > 0, size.height > 0, let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let ratio = layer.drawableSize.width / size.width
        if let texture, texture.mipmapLevelCount > 1, mipmapsStale,
           picture.width * ratio < CGFloat(texture.width) * 0.99, let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            mipmapsStale = false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            if let texture {
                // The picture's corners in normalized device coordinates (y up).
                var rect = SIMD4<Float>(Float(picture.minX / size.width * 2 - 1), Float(1 - picture.minY / size.height * 2),
                                        Float(picture.maxX / size.width * 2 - 1), Float(1 - picture.maxY / size.height * 2))
                // Mipmaps only once they match the picture.
                var maxLevel = Float(mipmapsStale ? 0 : texture.mipmapLevelCount - 1)
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setFragmentBytes(&maxLevel, length: MemoryLayout<Float>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
        lastCommands = commands
    }

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex Vertex screenVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corners[4] = { float2(rect.x, rect.y), float2(rect.z, rect.y), float2(rect.x, rect.w), float2(rect.z, rect.w) };
        float2 uvs[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        Vertex v;
        v.position = float4(corners[id], 0, 1);
        v.uv = uvs[id];
        return v;
    }

    fragment float4 screenFragment(Vertex in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                   sampler s [[sampler(0)]], constant float &maxLevel [[buffer(0)]]) {
        float lod = min(picture.calculate_clamped_lod(s, in.uv), maxLevel);
        return float4(picture.sample(s, in.uv, level(lod)).rgb, 1);
    }
    """
}

/// The view Metal draws into.
final class ScreenCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        contentScaleFactor = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }
}
