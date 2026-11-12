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

    var title: String {
        String(format: "%d × %d  ·  %.2f fps  ·  %@", width, height, fps, subtype)
    }
}

final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var currentDeviceID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    // 新增：供设置面板读取的采集能力 / 状态
    @Published private(set) var availableFormats: [CaptureFormatOption] = []
    @Published private(set) var activeFormatSummary: String = "等待设备…"
    @Published private(set) var currentPixelFormatSummary: String = "—"

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
    private var bag = Set<AnyCancellable>()

    private var didLogFirstFrame = false

    override init() {
        super.init()
        // 保持与原版一致：先由 preset 建立会话，随后每次设置 activeFormat 时
        // AVFoundation 会自动把会话切到 inputPriority，让设备格式说了算。
        session.sessionPreset = .high
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

            self.session.beginConfiguration()

            if let existing = self.currentVideoInput {
                self.session.removeInput(existing)
                self.currentVideoInput = nil
            }
            if let existing = self.currentAudioInput {
                self.session.removeInput(existing)
                self.currentAudioInput = nil
            }

            if !self.session.outputs.contains(self.videoOutput) {
                // Prefer 420f (biplanar full-range) for zero-copy YUV on GPU.
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
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

            if !self.session.isRunning {
                self.session.startRunning()
            }

            // 新增：记录设备、枚举真实可用格式、按用户选择锁定格式
            self.currentDevice = device
            self.rebuildFormatList(for: device)
            self.applyActiveFormat(on: device, key: self.settings.captureSnapshot().formatKey)
            self.applyAudioVolume(self.settings.captureSnapshot())

            DispatchQueue.main.async {
                self.isRunning = true
                self.currentDeviceID = device.uniqueID
            }
        }
    }

    // MARK: - 格式枚举与切换（新增）

    /// 从设备真实支持的 AVCaptureDevice.Format 构建候选列表，同一「分辨率+帧率」只保留一条。
    private func rebuildFormatList(for device: AVCaptureDevice) {
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

        // 换设备后若保存的格式不存在，安全回退到「自动」
        let saved = settings.captureSnapshot().formatKey
        let resolved = (saved.isEmpty || lookup[saved] != nil) ? saved : ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableFormats = options
            if self.settings.capture.formatKey != resolved {
                self.settings.capture.formatKey = resolved
            }
        }
    }

    /// 供 UI「重新应用格式」按钮与参数变更订阅调用。
    /// 订阅回调直接把新 key 带过来，不依赖 Combine 订阅顺序或加锁快照的更新时机。
    func applyPreferredFormat(key: String? = nil) {
        let resolved = key ?? settings.captureSnapshot().formatKey
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            self.applyActiveFormat(on: device, key: resolved)
        }
    }

    private func applyActiveFormat(on device: AVCaptureDevice, key: String) {
        let chosen = key.isEmpty ? nil : formatLookup[key]

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
            let summary = String(format: "%dx%d @ %.2f fps · %@",
                                 dims.width, dims.height, actualFPS, subtype)
            DispatchQueue.main.async { [weak self] in
                self?.activeFormatSummary = summary
            }
            NSLog("StreamView: active format %@ (mode=%@)",
                  summary, key.isEmpty ? "auto" : key)
        } catch {
            NSLog("StreamView: device lock error %@", error.localizedDescription)
        }

        // 分辨率变了，旧帧尺寸不再有效
        frameQueue.flush()
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
        if let s = String(bytes: bytes, encoding: .ascii),
           s.allSatisfy({ $0.isASCII && !$0.isNewline }) {
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

        if !didLogFirstFrame {
            didLogFirstFrame = true
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let pf = CVPixelBufferGetPixelFormatType(pb)
            let text = "\(w)×\(h) · \(Self.fourCCName(pf))"
            NSLog("StreamView: first frame %dx%d fmt=%@", w, h, Self.fourCCName(pf))
            DispatchQueue.main.async { [weak self] in
                self?.currentPixelFormatSummary = text
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
