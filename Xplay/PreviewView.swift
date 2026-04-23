import SwiftUI
import AppKit
import Metal
import MetalKit
import CoreVideo
import CoreMedia
import QuartzCore
import simd

struct PreviewView: NSViewRepresentable {
    let controller: CaptureController

    func makeNSView(context: Context) -> MetalPreviewNSView {
        let v = MetalPreviewNSView()
        v.attach(queue: controller.frameQueue)
        return v
    }

    func updateNSView(_ nsView: MetalPreviewNSView, context: Context) {}
}

final class MetalPreviewNSView: NSView {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var bgraPipeline: MTLRenderPipelineState?
    private var yuvPipeline: MTLRenderPipelineState?

    private var displayLink: CVDisplayLink?
    private var currentDisplayID: CGDirectDisplayID = 0
    private var halfFrameHostUnits: UInt64 = 0

    private weak var frameQueue: FrameQueue?
    private var lastStatsLog: CFAbsoluteTime = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureMetal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        configureMetal()
    }

    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.backgroundColor = CGColor.black
        l.maximumDrawableCount = 3
        return l
    }

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override var isOpaque: Bool { true }

    // MARK: - Setup

    private func configureMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            NSLog("StreamView: no Metal device")
            return
        }
        device = dev
        commandQueue = dev.makeCommandQueue()

        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        textureCache = cache

        buildPipelines()
        createDisplayLink()
    }

    private func buildPipelines() {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            NSLog("StreamView: shader compile failed: %@", error.localizedDescription)
            return
        }

        let bgraDesc = MTLRenderPipelineDescriptor()
        bgraDesc.vertexFunction = library.makeFunction(name: "vtx_fullscreen")
        bgraDesc.fragmentFunction = library.makeFunction(name: "frag_bgra")
        bgraDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let yuvDesc = MTLRenderPipelineDescriptor()
        yuvDesc.vertexFunction = library.makeFunction(name: "vtx_fullscreen")
        yuvDesc.fragmentFunction = library.makeFunction(name: "frag_yuv_biplanar")
        yuvDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            bgraPipeline = try device.makeRenderPipelineState(descriptor: bgraDesc)
            yuvPipeline = try device.makeRenderPipelineState(descriptor: yuvDesc)
        } catch {
            NSLog("StreamView: pipeline creation failed: %@", error.localizedDescription)
        }
    }

    func attach(queue: FrameQueue) {
        self.frameQueue = queue
    }

    // MARK: - CVDisplayLink

    private static let displayLinkCallback: CVDisplayLinkOutputCallback = {
        _, _, outputTime, _, _, userInfo in
        guard let userInfo else { return kCVReturnSuccess }
        let view = Unmanaged<MetalPreviewNSView>.fromOpaque(userInfo).takeUnretainedValue()
        view.render(hostTime: outputTime.pointee.hostTime,
                    refreshPeriod: outputTime.pointee.videoRefreshPeriod,
                    timeScale: outputTime.pointee.videoTimeScale)
        return kCVReturnSuccess
    }

    private func createDisplayLink() {
        var link: CVDisplayLink?
        let r = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard r == kCVReturnSuccess, let link else {
            NSLog("StreamView: failed to create CVDisplayLink (%d)", r)
            return
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, Self.displayLinkCallback, userInfo)
        displayLink = link
    }

    private func bind(to screen: NSScreen) {
        guard let link = displayLink else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = screen.deviceDescription[key] as? CGDirectDisplayID else { return }
        if id == currentDisplayID, CVDisplayLinkIsRunning(link) {
            return
        }
        CVDisplayLinkSetCurrentCGDisplay(link, id)
        currentDisplayID = id
        NSLog("StreamView: display link bound to CGDirectDisplayID=%u", id)
        if !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChangedScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            if let screen = window.screen {
                bind(to: screen)
            }
        } else {
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
        }
    }

    @objc private func windowChangedScreen(_ note: Notification) {
        if let screen = window?.screen {
            bind(to: screen)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1.0
        metalLayer.contentsScale = scale
        let b = bounds.size
        let px = CGSize(width: max(1, b.width * scale), height: max(1, b.height * scale))
        if metalLayer.drawableSize != px {
            metalLayer.drawableSize = px
        }
    }

    // MARK: - Render

    private func render(hostTime: UInt64, refreshPeriod: Int64, timeScale: Int32) {
        guard let queue = frameQueue else { return }

        if halfFrameHostUnits == 0, refreshPeriod > 0, timeScale > 0 {
            // Half-period in seconds -> mach_absolute_time units via CMClock.
            let halfSeconds = Double(refreshPeriod) / Double(timeScale) * 0.5
            let cmHalf = CMTime(seconds: halfSeconds, preferredTimescale: 1_000_000_000)
            halfFrameHostUnits = CMClockConvertHostTimeToSystemUnits(cmHalf)
        }

        guard let frame = queue.pickForHostTime(hostTime, halfFrameUnits: halfFrameHostUnits) else {
            return
        }

        autoreleasepool {
            drawFrame(frame)
        }

        logStatsIfDue(queue: queue)
    }

    private func drawFrame(_ frame: QueuedFrame) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        let pb = frame.pixelBuffer
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let pf = CVPixelBufferGetPixelFormatType(pb)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let drawableSize = metalLayer.drawableSize
        var scale = SIMD2<Float>(1, 1)
        if drawableSize.width > 0, drawableSize.height > 0, w > 0, h > 0 {
            let srcAspect = Double(w) / Double(h)
            let dstAspect = drawableSize.width / drawableSize.height
            if srcAspect > dstAspect {
                scale.y = Float(dstAspect / srcAspect)
            } else {
                scale.x = Float(srcAspect / dstAspect)
            }
        }

        let isBiplanar = (pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                       || pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        if isBiplanar, let pipeline = yuvPipeline {
            var luma: CVMetalTexture?
            var chroma: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .r8Unorm, w, h, 0, &luma)
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .rg8Unorm, w / 2, h / 2, 1, &chroma)

            if let yT = luma.flatMap(CVMetalTextureGetTexture),
               let cT = chroma.flatMap(CVMetalTextureGetTexture) {
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.setFragmentTexture(yT, index: 0)
                enc.setFragmentTexture(cT, index: 1)
                var fullRange: Int32 = (pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? 1 : 0
                enc.setFragmentBytes(&fullRange, length: MemoryLayout<Int32>.size, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        } else if let pipeline = bgraPipeline {
            var bgra: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &bgra)
            if let t = bgra.flatMap(CVMetalTextureGetTexture) {
                enc.setRenderPipelineState(pipeline)
                enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.setFragmentTexture(t, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func logStatsIfDue(queue: FrameQueue) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastStatsLog < 30 { return }
        lastStatsLog = now
        let s = queue.snapshotStats()
        NSLog("StreamView: stats pushed=%llu picked=%llu doubled=%llu dropped=%llu",
              s.pushed, s.picked, s.doubled, s.droppedUnused)
        queue.resetStats()
    }

    // MARK: - Shader source

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VSOut vtx_fullscreen(uint vid [[vertex_id]],
                                constant float2 &scale [[buffer(0)]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VSOut out;
        out.position = float4(positions[vid] * scale, 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 frag_bgra(VSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(mag_filter::linear,
                            min_filter::linear,
                            address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }

    fragment float4 frag_yuv_biplanar(VSOut in [[stage_in]],
                                      texture2d<float> yTex [[texture(0)]],
                                      texture2d<float> cTex [[texture(1)]],
                                      constant int &fullRange [[buffer(0)]]) {
        constexpr sampler s(mag_filter::linear,
                            min_filter::linear,
                            address::clamp_to_edge);
        float Y = yTex.sample(s, in.uv).r;
        float2 CbCr = cTex.sample(s, in.uv).rg;
        float Cb = CbCr.x - 0.5;
        float Cr = CbCr.y - 0.5;

        if (fullRange == 0) {
            Y  = (Y - 16.0/255.0) * (255.0/219.0);
            Cb = Cb * (255.0/224.0);
            Cr = Cr * (255.0/224.0);
        }

        // BT.709 limited matrix
        float R = Y + 1.5748 * Cr;
        float G = Y - 0.1873 * Cb - 0.4681 * Cr;
        float B = Y + 1.8556 * Cb;

        return float4(saturate(R), saturate(G), saturate(B), 1.0);
    }
    """
}
