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
        // 不设置任何 sessionPreset：.inputPriority 在 macOS 是 API_UNAVAILABLE(macos)，
        // 而主动设 .high / .hd1280x720 会让 session 更积极地在 commitConfiguration /
        // startRunning 时按 preset 重配设备格式。格式控制权由 select(device:) 里的
        // lockForConfiguration() 设备锁保证（macOS 官方做法）。
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
            self.currentDevice = device

            // ── macOS 专用顺序（Apple 官方）──────────────────────────────
            // .inputPriority 在 macOS 是 API_UNAVAILABLE(macos)，不能用。
            // macOS 上 session 在 commitConfiguration() 与 startRunning() 两个时刻
            // 都会按 sessionPreset 自动重配设备的 activeFormat。唯一可靠的做法是：
            // 让 lockForConfiguration() 的设备锁**同时跨过拓扑变更和 startRunning**。
            // 参考：Apple Developer Forums thread/85173（Media Engineer 回复）、
            // AVCaptureDevice.lockForConfiguration() 文档、AVFoundation "Formats" 文档。
            var inputError: Error?
            let locked = self.withDeviceLock(device) {
                // 1) 拓扑变更：begin/commit 必须在锁内，否则 commit 就会重配格式
                self.session.beginConfiguration()

                // 不设置任何 sessionPreset：macOS 没有 inputPriority，主动设 .high 之类
                // 只会让 session 更积极地去重配设备格式。保持默认即可。
                if let existing = self.currentVideoInput {
                    self.session.removeInput(existing)
                    self.currentVideoInput = nil
                }
                if let existing = self.currentAudioInput {
                    self.session.removeInput(existing)
                    self.currentAudioInput = nil
                }

                // 只请求像素格式、绝不指定宽高：让 VideoDataOutput 输出设备原生尺寸。
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
                    inputError = error
                }

                if inputError == nil {
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
                }

                self.session.commitConfiguration()

                guard inputError == nil else { return }

                // 2) output 已加入 session，此时枚举列表才完整
                self.rebuildOutputFormatList()
                let resolvedKey = self.rebuildFormatList(for: device)

                // 3) 锁内设定我们选的 activeFormat + 帧时长（含按用户选择重设 videoSettings）
                self.setActiveFormatLocked(on: device, key: resolvedKey)
                self.applyAudioVolume(self.settings.captureSnapshot())

                // 4) 锁内启动 —— 关键：不能先解锁再 startRunning
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }   // ← 此处才 unlockForConfiguration()

            guard locked else { return }
            if let inputError {
                NSLog("StreamView: video input error %@", inputError.localizedDescription)
                return
            }

            // 5) 解锁后回读真实 activeFormat，并做一次延迟兜底校验
            self.verifyActiveFormat(on: device)
            self.scheduleDelayedReverify(for: device)

            DispatchQueue.main.async {
                self.isRunning = true
                self.currentDeviceID = device.uniqueID
            }
        }
    }

    /// macOS 专用：把「会触发 session 自动重配 activeFormat」的操作整体放在设备锁内。
    /// inputPriority 在 macOS 不可用（API_UNAVAILABLE(macos)），这是唯一可靠替代。
    @discardableResult
    private func withDeviceLock(_ device: AVCaptureDevice, _ body: () -> Void) -> Bool {
        do {
            try device.lockForConfiguration()
        } catch {
            NSLog("StreamView: lockForConfiguration failed: %@", error.localizedDescription)
            return false
        }
        defer { device.unlockForConfiguration() }
        body()
        return true
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
        guard let device = currentDevice else { return }
        let code = resolveOutputFormat()

        // 改 output 的 videoSettings 也可能让 session 重配设备格式，
        // 因此同样放在设备锁内，并重设一次 activeFormat 作为兜底。
        self.withDeviceLock(device) {
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: code
            ]
            self.setActiveFormatLocked(on: device,
                                       key: self.settings.captureSnapshot().formatKey)
        }

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

    /// 运行中切换分辨率：只需设备锁，不要用 session.begin/commitConfiguration 包裹。
    /// macOS 上 commitConfiguration() 恰恰是 session 按 preset 重配设备格式的触发点之一，
    /// 包起来等于主动把刚设好的 activeFormat 又冲掉（这正是 1440p 掉回 720p 的原因）。
    private func applyActiveFormat(on device: AVCaptureDevice, key: String) {
        self.withDeviceLock(device) {
            self.setActiveFormatLocked(on: device, key: key)
        }
    }

    /// 假定调用方已持有 device 锁：设定格式、帧时长与输出像素格式。
    private func setActiveFormatLocked(on device: AVCaptureDevice, key: String) {
        self.lastAppliedFormatKey = key

        // 每次都重置，确保 videoSettings 里不残留任何宽高/缩放设置
        let outCode = self.resolveOutputFormat()
        self.videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: outCode
        ]

        let chosen = key.isEmpty ? nil : formatLookup[key]
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
        let requested = String(format: "请求 %dx%d @ %.2f fps · %@ · out=%@ (mode=%@)",
                               dims.width, dims.height, actualFPS, subtype,
                               Self.fourCCName(outCode),
                               key.isEmpty ? "auto" : key)
        DispatchQueue.main.async { [weak self] in
            self?.activeFormatSummary = requested
        }
        NSLog("StreamView: %@", requested)

        // 分辨率变了，旧帧尺寸不再有效
        self.frameQueue.flush()
        self.lastFrameSignature = nil
    }

    /// 解锁后仍可能被异步重配（部分 UVC 驱动会晚一拍）。延迟 0.6 s 再回读，
    /// 若尺寸已被改掉，按用户当前选择重新锁一次。
    private func scheduleDelayedReverify(for device: AVCaptureDevice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.sessionQueue.async {
                guard let self, self.currentDevice === device else { return }
                self.verifyAndReapplyIfNeeded(on: device)
            }
        }
    }

    private func verifyAndReapplyIfNeeded(on device: AVCaptureDevice) {
        let key = settings.captureSnapshot().formatKey
        let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if let expected = self.expectedDimensions(for: key, on: device),
           expected.width != actual.width || expected.height != actual.height {
            NSLog("StreamView: activeFormat was overridden to %dx%d, re-locking",
                  actual.width, actual.height)
            self.applyActiveFormat(on: device, key: key)
        }
        self.verifyActiveFormat(on: device)
    }

    private func expectedDimensions(for key: String, on device: AVCaptureDevice) -> CMVideoDimensions? {
        let fmt: AVCaptureDevice.Format?
        if key.isEmpty {
            fmt = Self.autoFormat(for: device)?.format
        } else {
            fmt = formatLookup[key]
        }
        guard let fmt else { return nil }
        return CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
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
