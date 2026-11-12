import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Combine

/// 一条设备实际支持的采集格式。id 用「宽x高@fps*100」表示，可跨设备持久化；
/// format 直接持有 AVCaptureDevice.Format，选中后无需再次遍历。
struct CaptureFormatOption: Identifiable {
    let id: String
    let width: Int
    let height: Int
    let fps: Double
    let subtype: String
    let format: AVCaptureDevice.Format

    /// 按未压缩 8-bit NV12 估算的裸带宽，仅用于判断 USB 是否吃得下。
    /// 压缩格式（MJPEG / H.264 / DSC）实际占用会小得多。
    var estimatedMBps: Double {
        Double(width) * Double(height) * 1.5 * fps / 1_000_000
    }

    var bandwidthNote: String {
        let m = estimatedMBps
        if m > 1000 { return "需 Gen2×2 / 压缩" }
        if m > 450  { return "需 Gen2 / 压缩" }
        if m > 250  { return "需 USB 3.2" }
        return "带宽充裕"
    }

    var title: String {
        String(format: "%d × %d · %.2f fps · %@ · ≈%d MB/s (%@)",
               width, height, fps, subtype,
               Int(estimatedMBps.rounded()), bandwidthNote)
    }
}

final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var currentDeviceID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    // 供设置面板读取的采集能力 / 状态
    @Published private(set) var availableFormats: [CaptureFormatOption] = []
    /// 设备 activeFormat 的真实读数（startRunning 之后校验），不是「请求值」
    @Published private(set) var activeFormatSummary: String = "等待设备…"
    /// AVCaptureVideoDataOutput 实际交付的 CVPixelBuffer（尺寸变化时实时刷新）
    @Published private(set) var currentPixelFormatSummary: String = "—"
    @Published private(set) var activeWidth: Int = 0
    @Published private(set) var activeHeight: Int = 0
    @Published private(set) var scalingWarning: String?
    /// AVCaptureVideoDataOutput 运行时实际支持的像素格式（与设备 UVC 线格式是两层）
    @Published private(set) var availableOutputFormats: [OutputPixelFormatOption] = []
    @Published private(set) var outputFormatWarning: String?
    /// 设备 activeFormat 的 mediaSubType，即 UVC 线格式（yuvs / 420v / …）
    @Published private(set) var deviceNativeFormatSummary: String = "—"

    let session = AVCaptureSession()
    let frameQueue = FrameQueue()

    private let settings = XplaySettings.shared
    private let videoQueue = DispatchQueue(label: "streamview.video", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "streamview.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var formatLookup: [String: AVCaptureDevice.Format] = [:]
    /// 只在 sessionQueue 上访问的镜像，避免渲染/配置线程去读主线程的 @Published
    private var outputFormatOptions: [OutputPixelFormatOption] = []
    private var bag = Set<AnyCancellable>()

    private var didLogFirstFrame = false
    private var lastFrameSignature: String?
    private var lastAppliedFormatKey: String?
    private var lastPixelWidth = 0
    private var lastPixelHeight = 0

    override init() {
        super.init()
        // 不要在这里设 .high：macOS 上 session preset 会在 addInput / startRunning 时
        // 反过来重配设备的 activeFormat，把用户选的高分辨率压回 preset 对应尺寸。
        // 格式控制权统一在 select(device:) 里显式交给 .inputPriority。
        let c = settings.captureSnapshot()
        audioPreview.volume = c.audioMuted ? 0 : Float(c.audioVolume)
        bindSettings()
    }

    private func bindSettings() {
        // @Published 只在 willSet 发值、没有初始回放，故无需 dropFirst
        settings.$capture
            .map { $0.formatKey }
            .removeDuplicates()
            .sink { [weak self] key in self?.applyPreferredFormat(key: key) }
            .store(in: &bag)

        settings.$capture
            .map { $0.outputPixelFormat }
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyOutputPixelFormat() }
            .store(in: &bag)

        settings.$capture
            .map { $0.audioMuted ? 0.0 : $0.audioVolume }
            .removeDuplicates()
            .sink { [weak self] volume in self?.setAudioVolume(Float(volume)) }
            .store(in: &bag)
    }

    // MARK: - Lifecycle

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            requestMicThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.requestMicThenConfigure() }
                    else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func requestMicThenConfigure() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.configure() }
            }
        default:
            configure()
        }
    }

    private func configure() {
        refreshDevices()
        if let preferred = pickPreferredDevice() {
            select(device: preferred)
        }
    }

    // MARK: - Device discovery

    func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    private func isExternal(_ device: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *) {
            return device.deviceType == .external
        } else {
            return device.deviceType == .externalUnknown
        }
    }

    private func pickPreferredDevice() -> AVCaptureDevice? {
        let named = availableDevices.first { d in
            let n = d.localizedName
            return n.localizedCaseInsensitiveContains("UGREEN")
                || n.localizedCaseInsensitiveContains("capture")
                || n.localizedCaseInsensitiveContains("hdmi")
                || n.localizedCaseInsensitiveContains("ms2109")
                || n.localizedCaseInsensitiveContains("ms2130")
        }
        if let named { return named }
        return availableDevices.first(where: isExternal)
    }

    private func audioDevices() -> [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
        } else {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.externalUnknown],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
    }

    // MARK: - Selection

    func select(device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameQueue.flush()
            self.didLogFirstFrame = false
            self.lastFrameSignature = nil
            self.lastAppliedFormatKey = nil

            // ── 第 1 步：在一个原子配置块里接好输入/输出，并显式交出格式控制权 ──
            self.session.beginConfiguration()

            // .high / .hd1280x720 这类 preset 会让 session 接管 activeFormat。
            // 不显式设 inputPriority，4K/1440p 就会被压回 1280×720。
            if self.session.canSetSessionPreset(.inputPriority) {
                self.session.sessionPreset = .inputPriority
            } else {
                NSLog("StreamView: WARNING cannot set sessionPreset = inputPriority")
            }

            if let existing = self.currentVideoInput {
                self.session.removeInput(existing)
                self.currentVideoInput = nil
            }
            if let existing = self.currentAudioInput {
                self.session.removeInput(existing)
                self.currentAudioInput = nil
            }

            // 只请求像素格式、绝不指定宽高：让 VideoDataOutput 输出设备原生尺寸，
            // 避免任何隐式的缩放/重采样。此时输出格式列表尚未枚举，会回退到 420f，
            // 第 2 步枚举完再用用户选择覆盖。
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: self.resolveOutputFormat()
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            if !self.session.outputs.contains(self.videoOutput) {
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
            }
            if !self.session.outputs.contains(self.audioPreview),
               self.session.canAddOutput(self.audioPreview) {
                self.session.addOutput(self.audioPreview)
            }

            do {
                let vInput = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(vInput) {
                    self.session.addInput(vInput)
                    self.currentVideoInput = vInput
                }
            } catch {
                NSLog("StreamView: video input error %@", error.localizedDescription)
                self.session.commitConfiguration()
                return
            }

            let audioMatch = self.audioDevices().first(where: {
                $0.localizedName == device.localizedName
                    || $0.localizedName.localizedCaseInsensitiveContains(device.localizedName)
            }) ?? AVCaptureDevice.default(for: .audio)

            if let audio = audioMatch,
               let aInput = try? AVCaptureDeviceInput(device: audio),
               self.session.canAddInput(aInput) {
                self.session.addInput(aInput)
                self.currentAudioInput = aInput
            }

            self.session.commitConfiguration()

            // ── 第 2 步：枚举能力、锁定 activeFormat（必须在 startRunning 之前）──
            self.currentDevice = device
            self.rebuildOutputFormatList()          // output 已加入 session，此时列表才完整
            let resolvedKey = self.rebuildFormatList(for: device)
            self.applyActiveFormat(on: device, key: resolvedKey)   // 内部按用户选择重设 videoSettings
            self.applyAudioVolume(self.settings.captureSnapshot())

            // ── 第 3 步：启动，然后回读设备真实 activeFormat 做校验 ──
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.verifyActiveFormat(on: device)

            DispatchQueue.main.async {
                self.isRunning = true
                self.currentDeviceID = device.uniqueID
            }
        }
    }

    // MARK: - 输出像素格式（AVCaptureVideoDataOutput 层）

    /// 运行时枚举 `availableVideoPixelFormatTypes`。这一层由 App 的 videoSettings 决定，
    /// 与设备 UVC 线格式（yuvs / 420v / RGB24）不是同一回事：
    /// Windows 的 RGB24 是厂商驱动/DirectShow 额外开的 pin，macOS 的 AVFoundation 不会凭空暴露。
    private func rebuildOutputFormatList() {
        let codes = self.videoOutput.availableVideoPixelFormatTypes
        let options = codes.map { code in
            OutputPixelFormatOption.make(code: code, fourCC: Self.fourCCName(code))
        }
        self.outputFormatOptions = options

        let saved = settings.captureSnapshot().outputPixelFormat
        let resolved = (saved.isEmpty || options.contains { $0.id == saved }) ? saved : ""
        let summary = "共 \(options.count) 种：" + options.map { $0.id }.joined(separator: " / ")
        NSLog("StreamView: availableVideoPixelFormatTypes %@", summary)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableOutputFormats = options
            if self.settings.capture.outputPixelFormat != resolved {
                self.settings.capture.outputPixelFormat = resolved
            }
            self.publishOutputFormatWarning()
        }
    }

    /// 纯函数：给定候选列表与用户选择，解析出真正能零拷贝渲染的 OSType。
    /// 传进来的 options 必须是调用方线程上持有的那份（sessionQueue 用内部镜像，主线程用 @Published）。
    private static func resolvedCode(options: [OutputPixelFormatOption], key: String) -> OSType {
        let supported = options.filter { $0.supported }
        let preferred = supported.first {
            $0.code == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } ?? supported.first

        if !key.isEmpty,
           let chosen = options.first(where: { $0.id == key }),
           chosen.supported {
            return chosen.code
        }
        return preferred?.code ?? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// 只在 sessionQueue 上调用。
    private func resolveOutputFormat() -> OSType {
        Self.resolvedCode(options: outputFormatOptions,
                          key: settings.captureSnapshot().outputPixelFormat)
    }

    /// 只在主线程调用：生成「选了但不支持」的提示，说明为什么自动回退。
    private func publishOutputFormatWarning() {
        let key = settings.capture.outputPixelFormat
        guard !key.isEmpty,
              let chosen = availableOutputFormats.first(where: { $0.id == key }),
              !chosen.supported else {
            outputFormatWarning = nil
            return
        }
        let actual = Self.resolvedCode(options: availableOutputFormats, key: key)
        outputFormatWarning = "已选 \(chosen.id)（\(chosen.label)），但 " + chosen.detail
            + " 实际请求已回退为 \(Self.fourCCName(actual))，画面链路保持零拷贝。"
    }

    /// 供 UI「重新枚举输出格式」按钮与参数订阅调用。
    func refreshOutputFormats() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.rebuildOutputFormatList()
            self.applyOutputPixelFormatOnSessionQueue()
        }
    }

    func applyOutputPixelFormat() {
        sessionQueue.async { [weak self] in
            self?.applyOutputPixelFormatOnSessionQueue()
        }
    }

    private func applyOutputPixelFormatOnSessionQueue() {
        let code = resolveOutputFormat()
        self.session.beginConfiguration()
        self.videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: code
        ]
        self.session.commitConfiguration()

        self.frameQueue.flush()
        self.lastFrameSignature = nil
        self.didLogFirstFrame = false
        DispatchQueue.main.async { [weak self] in
            self?.publishOutputFormatWarning()
        }
        NSLog("StreamView: requested output pixel format %@", Self.fourCCName(code))
    }

    // MARK: - 格式枚举与切换

    /// 从设备真实支持的 AVCaptureDevice.Format 构建候选列表，同一「分辨率+帧率」只保留一条。
    /// 返回实际可用的 formatKey（保存值在当前设备不存在时回退为 ""）。
    @discardableResult
    private func rebuildFormatList(for device: AVCaptureDevice) -> String {
        var lookup: [String: AVCaptureDevice.Format] = [:]
        var options: [CaptureFormatOption] = []

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width > 0, dims.height > 0 else { continue }
            let fps = Self.maxFPS(of: format)
            guard fps > 0 else { continue }

            let key = Self.formatKey(width: Int(dims.width), height: Int(dims.height), fps: fps)
            if lookup[key] != nil { continue }
            lookup[key] = format

            let subtype = Self.fourCCName(
                CMFormatDescriptionGetMediaSubType(format.formatDescription)
            )
            options.append(CaptureFormatOption(
                id: key,
                width: Int(dims.width),
                height: Int(dims.height),
                fps: fps,
                subtype: subtype,
                format: format
            ))
        }

        options.sort {
            let a = $0.width * $0.height
            let b = $1.width * $1.height
            return a == b ? $0.fps > $1.fps : a > b
        }

        self.formatLookup = lookup

        let saved = settings.captureSnapshot().formatKey
        let resolved = (saved.isEmpty || lookup[saved] != nil) ? saved : ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableFormats = options
            if self.settings.capture.formatKey != resolved {
                self.settings.capture.formatKey = resolved
            }
        }
        return resolved
    }

    /// 供 UI「重新应用 / 重新校验」按钮与参数变更订阅调用。
    /// force = true 时忽略去重，强制重设一次 activeFormat 并回读校验。
    func applyPreferredFormat(key: String? = nil, force: Bool = false) {
        let resolved = key ?? settings.captureSnapshot().formatKey
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            if !force, self.lastAppliedFormatKey == resolved {
                // 仅回读校验，不重复配置设备
                self.verifyActiveFormat(on: device)
                return
            }
            self.applyActiveFormat(on: device, key: resolved)
            self.verifyActiveFormat(on: device)
        }
    }

    /// activeFormat + 帧时长必须包在 session 的 begin/commitConfiguration 之间
    /// （Apple 官方要求），否则运行中的 session 随时可能把它重配掉。
    private func applyActiveFormat(on device: AVCaptureDevice, key: String) {
        self.lastAppliedFormatKey = key
        let chosen = key.isEmpty ? nil : formatLookup[key]

        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }

        // 每次都重置，确保 videoSettings 里不残留任何宽高/缩放设置
        self.videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: self.resolveOutputFormat()
        ]

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let best: AVCaptureDevice.Format?
            let targetFPS: Double
            if let chosen {
                best = chosen
                targetFPS = Self.maxFPS(of: chosen)
            } else if let auto = Self.autoFormat(for: device) {
                best = auto.format
                targetFPS = auto.fps
            } else {
                best = nil
                targetFPS = 60.0
            }
            guard let best else { return }

            device.activeFormat = best

            let ranges = best.videoSupportedFrameRateRanges
            let range = ranges.first {
                $0.maxFrameRate >= targetFPS - 0.1 && $0.minFrameRate <= targetFPS + 0.1
            } ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })

            if let range {
                // 用设备自己的 CMTime，不要手搓 CMTime(1,60) —— MS2109 内部时钟是 60.00024 Hz
                device.activeVideoMinFrameDuration = range.minFrameDuration
                device.activeVideoMaxFrameDuration = range.minFrameDuration
            }

            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let actualFPS = range?.maxFrameRate ?? 0
            let subtype = Self.fourCCName(
                CMFormatDescriptionGetMediaSubType(best.formatDescription)
            )
            let requested = String(format: "请求 %dx%d @ %.2f fps · %@ (mode=%@)",
                                   dims.width, dims.height, actualFPS, subtype,
                                   key.isEmpty ? "auto" : key)
            DispatchQueue.main.async { [weak self] in
                self?.activeFormatSummary = requested
            }
            NSLog("StreamView: %@", requested)
        } catch {
            NSLog("StreamView: device lock error %@", error.localizedDescription)
        }

        // 分辨率变了，旧帧尺寸不再有效
        self.frameQueue.flush()
        self.lastFrameSignature = nil
    }

    /// startRunning 之后回读设备真实 activeFormat，把「请求」改写成「实际生效」。
    private func verifyActiveFormat(on device: AVCaptureDevice) {
        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let subtype = Self.fourCCName(CMFormatDescriptionGetMediaSubType(fmt.formatDescription))
        let duration = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let fps = duration > 0 ? 1.0 / duration : 0
        let summary = String(format: "%dx%d @ %.2f fps · %@",
                             dims.width, dims.height, fps, subtype)
        let w = Int(dims.width)
        let h = Int(dims.height)
        NSLog("StreamView: VERIFIED activeFormat %@", summary)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeWidth = w
            self.activeHeight = h
            self.activeFormatSummary = summary
            self.deviceNativeFormatSummary = subtype + "（UVC 线格式）"
            self.refreshScalingWarning()
        }
    }

    private func refreshScalingWarning() {
        guard activeWidth > 0, activeHeight > 0,
              lastPixelWidth > 0, lastPixelHeight > 0 else {
            scalingWarning = nil
            return
        }
        if lastPixelWidth != activeWidth || lastPixelHeight != activeHeight {
            scalingWarning = "输出被缩放：设备 \(activeWidth)×\(activeHeight)，实际缓冲 \(lastPixelWidth)×\(lastPixelHeight)。通常是采集卡/驱动降档，或该档位在当前 USB 带宽下无法维持。"
        } else {
            scalingWarning = nil
        }
    }

    /// 原版的「自动」策略：优先精确 1920×1080@60，否则在支持 60fps 的格式里取最大分辨率。
    private static func autoFormat(for device: AVCaptureDevice)
        -> (format: AVCaptureDevice.Format, fps: Double)? {
        let targetWidth: Int32 = 1920
        let targetHeight: Int32 = 1080
        let targetFPS: Double = 60.0

        func supports(_ f: AVCaptureDevice.Format, fps: Double) -> Bool {
            f.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= fps - 0.1 && $0.minFrameRate <= fps + 0.1
            }
        }

        let exact = device.formats.first { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == targetWidth && d.height == targetHeight && supports(f, fps: targetFPS)
        }

        let fallback: AVCaptureDevice.Format? = {
            let sixty = device.formats.filter { supports($0, fps: targetFPS) }
            let pool = sixty.isEmpty ? device.formats : sixty
            return pool.max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return (Int(da.width) * Int(da.height)) < (Int(db.width) * Int(db.height))
            }
        }()

        guard let best = exact ?? fallback else { return nil }
        return (best, targetFPS)
    }

    private static func maxFPS(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges
            .max(by: { $0.maxFrameRate < $1.maxFrameRate })?.maxFrameRate ?? 60.0
    }

    /// 不依赖区域设置的稳定 key（避免 String(format:) 的小数点受 locale 影响）
    private static func formatKey(width: Int, height: Int, fps: Double) -> String {
        "\(width)x\(height)@\(Int((fps * 100).rounded()))"
    }

    // MARK: - 音频

    private func setAudioVolume(_ volume: Float) {
        sessionQueue.async { [weak self] in
            self?.audioPreview.volume = volume
        }
    }

    private func applyAudioVolume(_ params: CaptureParams) {
        audioPreview.volume = params.audioMuted ? 0 : Float(params.audioVolume)
    }

    // MARK: - 工具

    fileprivate static func fourCCName(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        // CoreVideo 里 24RGB 之类的 OSType 是小整数（不是四字符码），
        // 直接按 ASCII 解会得到控制字符，UI 里当 tag 会有隐患，统一回退成 0x... 形式。
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return s
        }
        return String(format: "0x%08x", code)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsHostUnits = CMClockConvertHostTimeToSystemUnits(pts)

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let pf = CVPixelBufferGetPixelFormatType(pb)
        let fmtName = Self.fourCCName(pf)
        let signature = "\(w)x\(h)-\(fmtName)"

        // 尺寸或像素格式一变就刷新状态页（不再只记首帧，切分辨率后能立刻看到真实值）
        if signature != lastFrameSignature {
            lastFrameSignature = signature
            let text = "\(w)×\(h) · \(fmtName)"
            if !didLogFirstFrame {
                didLogFirstFrame = true
                NSLog("StreamView: first frame %dx%d fmt=%@", w, h, fmtName)
            }
            NSLog("StreamView: output buffer changed -> %@", text)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastPixelWidth = w
                self.lastPixelHeight = h
                self.currentPixelFormatSummary = text
                self.refreshScalingWarning()
            }
        }

        frameQueue.push(QueuedFrame(pixelBuffer: pb, ptsHostTime: ptsHostUnits))
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        NSLog("StreamView: captureOutput dropped a frame")
    }
}
