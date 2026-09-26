import Metal
import MetalKit
import SwiftUI

/// Draws the guest's framebuffer with Metal instead of a CGImage per frame.
///
/// The display pump uploads each new frame into one of three textures on its
/// own thread; the view draws the newest complete one, aspect-fit exactly as
/// `CoordinateMapper` assumes, so touches land where the picture is. No image
/// object is created per frame and SwiftUI does not diff pixels.
final class MetalFrameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var textures: [MTLTexture] = []
    private var newest = -1
    private var writing = 0
    /// Command buffers still sampling each texture (MTKView keeps up to three in flight).
    private var inFlight = [0, 0, 0]
    private var drewFrame = false
    private(set) var size = (width: 0, height: 0)
    weak var view: MTKView?

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V vp_vertex(uint vid [[vertex_id]]) {
        const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 t[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        V o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
    }
    fragment float4 vp_fragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(tex.sample(s, in.uv).rgb, 1.0); // the frame's alpha byte is padding
    }
    """

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vp_vertex")
            d.fragmentFunction = library.makeFunction(name: "vp_fragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            AppLogger.shared.log(.display, "Metal pipeline failed: \(error)", level: .warning)
            return nil
        }
        self.device = device
        self.queue = queue
        super.init()
    }

    /// Pump thread: copies a whole a8r8g8b8 frame (B,G,R,A bytes) into the next texture.
    func upload(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int) {
        lock.lock()
        if size != (width, height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
            size = (width, height)
            newest = -1
            inFlight = [0, 0, 0]
        }
        guard textures.count == 3 else { lock.unlock(); return }
        // Neither the newest (about to be shown) nor one the GPU still reads.
        // With all three busy the frame is dropped rather than torn.
        guard let free = (0..<3).first(where: { $0 != newest && inFlight[$0] == 0 }) else { lock.unlock(); return }
        writing = free
        let texture = textures[writing]
        lock.unlock()

        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)

        lock.lock()
        newest = writing
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.view?.setNeedsDisplay() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        lock.lock()
        let index = newest
        let texture = index >= 0 ? textures[index] : nil
        let frame = size
        let generation = textures.first.map { ObjectIdentifier($0) }
        if index >= 0 { inFlight[index] += 1 }
        let first = index >= 0 && !drewFrame
        if first { drewFrame = true }
        lock.unlock()
        if first { AppLogger.shared.log(.display, "Metal drew its first frame (\(frame.width)x\(frame.height))") }
        if let texture, frame.width > 0 {
            let drawableSize = view.drawableSize
            let mapper = CoordinateMapper(view: Size2D(width: Double(drawableSize.width), height: Double(drawableSize.height)),
                                          guestWidth: frame.width, guestHeight: frame.height)
            let rect = mapper.contentRect
            encoder.setViewport(MTLViewport(originX: rect.origin.x, originY: rect.origin.y,
                                            width: rect.size.width, height: rect.size.height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        if index >= 0 {
            buffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                // Only for the same set of textures (a resize replaces them).
                if self.textures.first.map({ ObjectIdentifier($0) }) == generation, self.inFlight[index] > 0 {
                    self.inFlight[index] -= 1
                }
                self.lock.unlock()
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// SwiftUI host for the renderer. Redraws only when a frame arrives.
struct MetalFrameView: UIViewRepresentable {
    let renderer: MetalFrameRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.framebufferOnly = true
        view.isUserInteractionEnabled = false // touches are handled by the SwiftUI gesture above
        view.delegate = renderer
        renderer.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}

enum RendererKind: String {
    case coreGraphics, metal

    /// `-VPRenderer metal` or the setting; Core Graphics until measured on devices.
    static var preferred: RendererKind {
        RendererKind(rawValue: UserDefaults.standard.string(forKey: "VPRenderer") ?? "") ?? .coreGraphics
    }
}
