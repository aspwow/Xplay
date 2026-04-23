import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var currentDeviceID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false

    let session = AVCaptureSession()
    let frameQueue = FrameQueue()

    private let videoQueue = DispatchQueue(label: "streamview.video", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "streamview.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private var currentVideoInput: AVCaptureDeviceInput?
    private var currentAudioInput: AVCaptureDeviceInput?

    private var didLogFirstFrame = false

    override init() {
        super.init()
        session.sessionPreset = .high
        audioPreview.volume = 1.0
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

            self.configureHighestFrameRate(on: device)

            DispatchQueue.main.async {
                self.isRunning = true
                self.currentDeviceID = device.uniqueID
            }
        }
    }

    // MARK: - Format / frame rate lock

    private func configureHighestFrameRate(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

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

            guard let best = exact ?? fallback else { return }
            device.activeFormat = best

            let range = best.videoSupportedFrameRateRanges.first {
                $0.maxFrameRate >= targetFPS - 0.1 && $0.minFrameRate <= targetFPS + 0.1
            } ?? best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })

            if let range {
                // Use the device's own CMTime, not a hand-built one — see OBSAVCapture.m:506.
                device.activeVideoMinFrameDuration = range.minFrameDuration
                device.activeVideoMaxFrameDuration = range.minFrameDuration
            }

            let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let actualFPS = range.map { $0.maxFrameRate } ?? 0
            NSLog("StreamView: locked %dx%d @ %.3f fps (exact=%@)",
                  dims.width, dims.height, actualFPS, exact != nil ? "yes" : "no")
        } catch {
            NSLog("StreamView: device lock error %@", error.localizedDescription)
        }
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
            NSLog("StreamView: first frame %dx%d fmt=%@", w, h, Self.fourCCName(pf))
        }

        frameQueue.push(QueuedFrame(pixelBuffer: pb, ptsHostTime: ptsHostUnits))
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        NSLog("StreamView: captureOutput dropped a frame")
    }

    private static func fourCCName(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        if let s = String(bytes: bytes, encoding: .ascii), s.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return s
        }
        return String(format: "0x%08x", code)
    }
}
