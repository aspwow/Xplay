import SwiftUI
import AppKit
import Metal
import MetalKit
import CoreVideo
import CoreMedia
import QuartzCore
import simd

/// 与 MSL 中 PictureUniforms 严格一一对应的 12 个 Float（48 字节，align 4）。
/// 全部用 Float 是为了避开 Swift / Metal 混合结构体的对齐差异。
struct PictureUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var kr: Float
    var kb: Float
    var rangeMode: Float        // 0 = auto, 1 = force full, 2 = force limited
    var sourceFullRange: Float  // 1 = 像素缓冲本身是 full range
    var flipX: Float
    var flipY: Float
    var useNearest: Float
    var padding0: Float
    var padding1: Float

    init(brightness: Float, contrast: Float, saturation: Float,
         kr: Float, kb: Float, rangeMode: Float, sourceFullRange: Float,
         flipX: Float, flipY: Float, useNearest: Float) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.kr = kr
        self.kb = kb
        self.rangeMode = rangeMode
        self.sourceFullRange = sourceFullRange
        self.flipX = flipX
        self.flipY = flipY
        self.useNearest = useNearest
        self.padding0 = 0
        self.padding1 = 0
    }
}

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

        // 每帧从加锁快照读一次参数，渲染线程不与 SwiftUI 主线程争用
        let params = XplaySettings.shared.pictureSnapshot()
        let drawableSize = metalLayer.drawableSize
        var scale = aspectScale(sourceWidth: w, sourceHeight: h,
                                drawableSize: drawableSize, mode: params.aspectMode)
        let sourceIsFullRange = (pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        var uniforms = PictureUniforms(
            brightness: Float(params.brightness),
            contrast: Float(params.contrast),
            saturation: Float(params.saturation),
            kr: Float(params.colorMatrix.kr),
            kb: Float(params.colorMatrix.kb),
            rangeMode: params.rangeMode.code,
            sourceFullRange: sourceIsFullRange ? 1 : 0,
            flipX: params.flipHorizontal ? 1 : 0,
            flipY: params.flipVertical ? 1 : 0,
            useNearest: params.filter == .nearest ? 1 : 0
        )

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
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<PictureUniforms>.size, index: 1)
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
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<PictureUniforms>.size, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// fit = 原版行为（等比 + 黑边）；fill = 等比铺满并裁切；stretch = 忽略比例。
    private func aspectScale(sourceWidth: Int, sourceHeight: Int,
                             drawableSize: CGSize, mode: AspectMode) -> SIMD2<Float> {
        var scale = SIMD2<Float>(1, 1)
        guard mode != .stretch,
              drawableSize.width > 0, drawableSize.height > 0,
              sourceWidth > 0, sourceHeight > 0 else { return scale }

        let srcAspect = Double(sourceWidth) / Double(sourceHeight)
        let dstAspect = drawableSize.width / drawableSize.height
        switch mode {
        case .fit:
            if srcAspect > dstAspect {
                scale.y = Float(dstAspect / srcAspect)
            } else {
                scale.x = Float(srcAspect / dstAspect)
            }
        case .fill:
            if srcAspect > dstAspect {
                scale.x = Float(srcAspect / dstAspect)
            } else {
                scale.y = Float(dstAspect / srcAspect)
            }
        case .stretch:
            break
        }
        return scale
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

    struct PictureUniforms {
        float brightness;
        float contrast;
        float saturation;
        float kr;
        float kb;
        float rangeMode;
        float sourceFullRange;
        float flipX;
        float flipY;
        float useNearest;
        float padding0;
        float padding1;
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

    float2 mappedUV(float2 uv, float flipX, float flipY) {
        float2 r = uv;
        if (flipX > 0.5) r.x = 1.0 - r.x;
        if (flipY > 0.5) r.y = 1.0 - r.y;
        return r;
    }

    // Brightness / contrast / saturation in RGB space, shared by BGRA and YUV paths.
    float3 grade(float3 rgb, float brightness, float contrast,
                        float saturation, float kr, float kb) {
        float3 c = (rgb - 0.5) * contrast + 0.5 + brightness;
        float kg = max(1.0 - kr - kb, 0.0001);
        float luma = c.r * kr + c.g * kg + c.b * kb;
        c = mix(float3(luma), c, float3(saturation));
        return saturate(c);
    }

    fragment float4 frag_bgra(VSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              constant PictureUniforms &u [[buffer(1)]]) {
        constexpr sampler sLinear(mag_filter::linear,
                                  min_filter::linear,
                                  address::clamp_to_edge);
        constexpr sampler sNearest(mag_filter::nearest,
                                   min_filter::nearest,
                                   address::clamp_to_edge);
        float2 uv = mappedUV(in.uv, u.flipX, u.flipY);
        float3 rgb = (u.useNearest > 0.5)
            ? tex.sample(sNearest, uv).rgb
            : tex.sample(sLinear, uv).rgb;
        return float4(grade(rgb, u.brightness, u.contrast,
                            u.saturation, u.kr, u.kb), 1.0);
    }

    fragment float4 frag_yuv_biplanar(VSOut in [[stage_in]],
                                      texture2d<float> yTex [[texture(0)]],
                                      texture2d<float> cTex [[texture(1)]],
                                      constant PictureUniforms &u [[buffer(1)]]) {
        constexpr sampler sLinear(mag_filter::linear,
                                  min_filter::linear,
                                  address::clamp_to_edge);
        constexpr sampler sNearest(mag_filter::nearest,
                                   min_filter::nearest,
                                   address::clamp_to_edge);
        float2 uv = mappedUV(in.uv, u.flipX, u.flipY);

        float Y;
        float Cb;
        float Cr;
        if (u.useNearest > 0.5) {
            Y = yTex.sample(sNearest, uv).r;
            float2 c = cTex.sample(sNearest, uv).rg;
            Cb = c.x - 0.5;
            Cr = c.y - 0.5;
        } else {
            Y = yTex.sample(sLinear, uv).r;
            float2 c = cTex.sample(sLinear, uv).rg;
            Cb = c.x - 0.5;
            Cr = c.y - 0.5;
        }

        // rangeMode: 0 = follow pixel format, 1 = force full, 2 = force limited
        bool limited = (u.rangeMode > 1.5)
                    || (u.rangeMode < 0.5 && u.sourceFullRange < 0.5);
        if (limited) {
            Y  = (Y - 16.0/255.0) * (255.0/219.0);
            Cb = Cb * (255.0/224.0);
            Cr = Cr * (255.0/224.0);
        }

        // Derive BT.709 / BT.601 / BT.2020 matrix from Kr / Kb.
        float kg = max(1.0 - u.kr - u.kb, 0.0001);
        float R = Y + 2.0 * (1.0 - u.kr) * Cr;
        float B = Y + 2.0 * (1.0 - u.kb) * Cb;
        float G = Y - (2.0 * u.kb * (1.0 - u.kb) / kg) * Cb
                    - (2.0 * u.kr * (1.0 - u.kr) / kg) * Cr;

        return float4(grade(float3(R, G, B), u.brightness, u.contrast,
                            u.saturation, u.kr, u.kb), 1.0);
    }
    """
}
