import SwiftUI
import AppKit
import AVFoundation
import CoreVideo
import Combine
import Foundation
import os.lock

// MARK: - 可调参数模型

/// YUV → RGB 转换矩阵预设。Kr / Kb 决定 R、B 的色差增益，Kg = 1 - Kr - Kb。
enum ColorMatrixPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case bt709  = "bt709"
    case bt601  = "bt601"
    case bt2020 = "bt2020"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bt709:  return "BT.709（HD，默认）"
        case .bt601:  return "BT.601（SD / 老设备）"
        case .bt2020: return "BT.2020（UHD）"
        }
    }

    var kr: Double {
        switch self {
        case .bt709:  return 0.2126
        case .bt601:  return 0.299
        case .bt2020: return 0.2627
        }
    }

    var kb: Double {
        switch self {
        case .bt709:  return 0.0722
        case .bt601:  return 0.114
        case .bt2020: return 0.0593
        }
    }
}

/// 亮度范围：auto 依据 CVPixelBuffer 的 fourCC 自动判断，也可强制覆盖。
enum YUVRangeMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case auto    = "auto"
    case full    = "full"
    case limited = "limited"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:    return "自动（跟随采集卡）"
        case .full:    return "Full range（0–255）"
        case .limited: return "Limited / Video range（16–235）"
        }
    }

    var code: Float {
        switch self {
        case .auto:    return 0
        case .full:    return 1
        case .limited: return 2
        }
    }
}

enum AspectMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case fit     = "fit"
    case fill    = "fill"
    case stretch = "stretch"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit:     return "适应（保留黑边）"
        case .fill:    return "填满（裁切两边）"
        case .stretch: return "拉伸（忽略比例）"
        }
    }
}

enum ScalingFilter: String, Codable, CaseIterable, Identifiable, Hashable {
    case linear  = "linear"
    case nearest = "nearest"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear:  return "双线性（平滑，默认）"
        case .nearest: return "最近邻（像素锐利）"
        }
    }
}

struct PictureParams: Codable, Equatable {
    var colorMatrix: ColorMatrixPreset = .bt709
    var rangeMode: YUVRangeMode = .auto
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var aspectMode: AspectMode = .fit
    var filter: ScalingFilter = .linear
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    static let defaults = PictureParams()
}

/// AVCaptureVideoDataOutput 可请求的「输出像素格式」。
/// 注意：这和采集卡通过 UVC 送出的线格式（yuvs / 420v / RGB24）是**两层**——
/// 前者由 App 的 videoSettings 决定，后者由采集卡固件 + 驱动决定，App 无法凭空增加。
struct OutputPixelFormatOption: Identifiable, Hashable {
    let id: String              // fourCC 字符串，或 0x... 形式
    let code: OSType
    let label: String
    let detail: String
    let supported: Bool         // 渲染器能否零拷贝处理
    let isRGB: Bool

    var pickerTitle: String {
        "\(id) · \(label) · \(supported ? "零拷贝" : "需转换")"
    }

    /// 只用 Apple 文档里稳定存在的常量；24-bit RGB 等用数值兜底，避免不同 SDK 里常量名缺失。
    static let zeroCopyCodes: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA
    ]

    private static let cv24RGB: OSType = 24                 // kCVPixelFormatType_24RGB
    private static let cv24BGR: OSType = 842_285_639       // kCVPixelFormatType_24BGR ('24BG')

    static func make(code: OSType, fourCC: String) -> OutputPixelFormatOption {
        let supported = zeroCopyCodes.contains(code)
        var label = "未知格式"
        var detail = "该格式没有对应的 Metal 零拷贝路径，选中后将自动回退到自动模式。"
        var isRGB = false

        // 用 if-else 而不是 switch 的表达式模式，避免不同 SDK 下 CoreVideo 常量
        // 被导入成 var 时 case 模式无法匹配的编译问题。
        if code == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            label = "NV12 Full (8-bit 4:2:0)"
            detail = "双平面 YUV，GPU 直接映射 r8Unorm + rg8Unorm，零拷贝。项目默认。"
        } else if code == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            label = "NV12 Video (8-bit 4:2:0)"
            detail = "双平面 YUV，零拷贝；着色器自动按 limited range 做 16–235 展开。"
        } else if code == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            label = "P010 Video (10-bit 4:2:0)"
            detail = "双平面 10-bit，用 r16Unorm / rg16Unorm 映射，零拷贝。"
        } else if code == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            label = "P010 Full (10-bit 4:2:0)"
            detail = "双平面 10-bit full range，用 r16Unorm / rg16Unorm 映射，零拷贝。"
        } else if code == kCVPixelFormatType_32BGRA {
            label = "BGRA32（RGB 输出）"
            detail = "32-bit RGB，Metal 原生 bgra8Unorm 零拷贝。但 BGRA 不是采集卡原生格式，AVFoundation 需从 YUV 转一次，内存约为 NV12 的 2.6×（Apple TN3121 不建议默认使用）。"
            isRGB = true
        } else if code == cv24RGB || code == cv24BGR {
            label = "RGB24 / BGR24（24-bit packed）"
            detail = "Windows DirectShow 常见格式。Metal 没有 24bpp 纹理格式，必须先 CPU 转成 32-bit 才能上 GPU，会破坏零拷贝并增加一次全帧拷贝，因此此处禁用。"
            isRGB = true
        } else if ["yuvs", "yuvf", "2vuy"].contains(fourCC) {
            label = "YUY2 / UYVY（打包 4:2:2）"
            detail = "采集卡常见的 UVC 线格式。打包 4:2:2 无法直接做零拷贝双平面映射，AVFoundation 会转换为 420f；直接请求反而多一次转换，因此此处禁用。"
        } else {
            label = "\(fourCC)（未适配）"
            isRGB = fourCC.contains("RGB") || fourCC.contains("BGR")
        }

        return OutputPixelFormatOption(
            id: fourCC, code: code, label: label,
            detail: detail, supported: supported, isRGB: isRGB
        )
    }
}

struct CaptureParams: Codable, Equatable {
    /// "" = 自动；否则是 CaptureFormatOption.id（形如 "1920x1080@6000"）
    var formatKey: String = ""
    /// "" = 自动；否则是 OutputPixelFormatOption.id（fourCC）
    var outputPixelFormat: String = ""
    var audioVolume: Double = 1
    var audioMuted: Bool = false

    static let defaults = CaptureParams()

    /// 兼容旧版 UserDefaults（没有 outputPixelFormat 字段时按自动处理，不丢其它设置）。
    private enum CodingKeys: String, CodingKey {
        case formatKey, outputPixelFormat, audioVolume, audioMuted
    }

    init(formatKey: String = "", outputPixelFormat: String = "",
         audioVolume: Double = 1, audioMuted: Bool = false) {
        self.formatKey = formatKey
        self.outputPixelFormat = outputPixelFormat
        self.audioVolume = audioVolume
        self.audioMuted = audioMuted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatKey = try c.decodeIfPresent(String.self, forKey: .formatKey) ?? ""
        outputPixelFormat = try c.decodeIfPresent(String.self, forKey: .outputPixelFormat) ?? ""
        audioVolume = try c.decodeIfPresent(Double.self, forKey: .audioVolume) ?? 1
        audioMuted = try c.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? false
    }
}

/// 全局参数中心。UI 在主线程读写 @Published，渲染线程通过 xxxSnapshot() 拿加锁快照，
/// 避免 CVDisplayLink 回调与 SwiftUI 互相争用。所有改动写入 UserDefaults，重启保留。
final class XplaySettings: ObservableObject {
    static let shared = XplaySettings()

    private static let pictureKey = "xplay.picture.v1"
    private static let captureKey = "xplay.capture.v1"

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let pictureLock: OSAllocatedUnfairLock<PictureParams>
    private let captureLock: OSAllocatedUnfairLock<CaptureParams>
    private var bag = Set<AnyCancellable>()

    @Published var picture: PictureParams
    @Published var capture: CaptureParams

    private init() {
        let p = Self.load(PictureParams.self, key: Self.pictureKey, fallback: .defaults)
        let c = Self.load(CaptureParams.self, key: Self.captureKey, fallback: .defaults)
        self.picture = p
        self.capture = c
        self.pictureLock = OSAllocatedUnfairLock(initialState: p)
        self.captureLock = OSAllocatedUnfairLock(initialState: c)

        // @Published 不会回放初始值，所以这里不能用 dropFirst()，否则第一次改动会被吞掉
        $picture
            .sink { [weak self] value in
                guard let self else { return }
                self.pictureLock.withLock { $0 = value }
                self.save(value, key: Self.pictureKey)
            }
            .store(in: &bag)

        $capture
            .sink { [weak self] value in
                guard let self else { return }
                self.captureLock.withLock { $0 = value }
                self.save(value, key: Self.captureKey)
            }
            .store(in: &bag)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return value
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    func pictureSnapshot() -> PictureParams { pictureLock.withLock { $0 } }
    func captureSnapshot() -> CaptureParams { captureLock.withLock { $0 } }

    func selectedOutputFormat(in options: [OutputPixelFormatOption]) -> OutputPixelFormatOption? {
        let key = capture.outputPixelFormat
        guard !key.isEmpty else { return nil }
        return options.first { $0.id == key }
    }

    func resetPicture() { picture = .defaults }
    func resetAll() {
        picture = .defaults
        capture = .defaults
    }
}

// MARK: - 主画面

struct ContentView: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.isRunning {
                PreviewView(controller: controller)
                    .ignoresSafeArea()
            } else if controller.permissionDenied {
                VStack(spacing: 12) {
                    Text("Camera access denied")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("Enable camera access in System Settings → Privacy & Security → Camera, then relaunch.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding()
            } else if controller.availableDevices.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for capture device…")
                        .foregroundColor(.secondary)
                }
            } else {
                devicePicker
            }
        }
        .onAppear { controller.start() }
        .overlay(alignment: .bottomTrailing) {
            if controller.isRunning {
                SettingsGearButton(controller: controller)
                    .padding(14)
            }
        }
    }

    private var devicePicker: some View {
        VStack(spacing: 16) {
            Text("Select a capture device")
                .font(.title2)
                .foregroundColor(.white)
            ForEach(controller.availableDevices, id: \.uniqueID) { device in
                Button {
                    controller.select(device: device)
                } label: {
                    Text(device.localizedName)
                        .frame(minWidth: 260)
                }
                .controlSize(.large)
            }
        }
        .padding()
    }
}

/// 平时几乎隐形，鼠标移上去才显现，不破坏「画面即 UI」的零装饰设计。
private struct SettingsGearButton: View {
    let controller: CaptureController
    @State private var hovering = false

    var body: some View {
        Button {
            SettingsWindow.show(controller: controller)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .padding(10)
                .background(Capsule().fill(Color.black.opacity(hovering ? 0.65 : 0.3)))
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.32)
        .onHover { hovering = $0 }
        .help("参数设置 (⌘,)")
    }
}

// MARK: - 设置面板（AppKit 承载，可在全屏画面之上悬浮）

enum SettingsWindow {
    private static var panel: NSWindow?

    static func show(controller: CaptureController) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(controller: controller, settings: XplaySettings.shared)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Xplay 参数设置"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrameAutosaveName("Xplay.SettingsPanel")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = window
    }
}

struct SettingsView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var settings: XplaySettings

    var body: some View {
        TabView {
            capturePane
                .tabItem { Label("采集", systemImage: "camera") }
            picturePane
                .tabItem { Label("画面", systemImage: "slider.horizontal.3") }
            statusPane
                .tabItem { Label("状态", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(minWidth: 470, idealWidth: 500, minHeight: 540)
    }

    // MARK: 采集

    private var capturePane: some View {
        Form {
            Section("采集设备") {
                Picker("设备", selection: Binding(
                    get: { controller.currentDeviceID ?? "" },
                    set: { id in
                        if let device = controller.availableDevices.first(where: { $0.uniqueID == id }) {
                            controller.select(device: device)
                        }
                    }
                )) {
                    if controller.availableDevices.isEmpty {
                        Text("未检测到设备").tag("")
                    }
                    ForEach(controller.availableDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                HStack {
                    Button("重新枚举设备") { controller.refreshDevices() }
                    Button("重新应用格式") { controller.applyPreferredFormat(force: true) }
                }
            }

            Section("分辨率 / 帧率") {
                Picker("采集格式", selection: $settings.capture.formatKey) {
                    Text("自动（优先 1920×1080 @ 60 fps）").tag("")
                    ForEach(controller.availableFormats) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text("列表来自设备实际支持的 AVCaptureDevice.Format，末尾的 fourCC（yuvs / 420v / …）是采集卡通过 UVC 送出的**原生线格式**，由固件与驱动决定，App 只能枚举、不能凭空增加。切换时立即重新锁定 activeFormat 与帧时长，无需重启。MB/s 按未压缩 8-bit NV12 估算，只用来判断 USB 带宽；设备用 MJPEG / H.264 / DSC 压缩时实际占用会小很多。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("设备 UVC 线格式")
                    Spacer()
                    Text(controller.deviceNativeFormatSummary)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("设备实际生效")
                    Spacer()
                    Text(controller.activeFormatSummary)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("输出像素缓冲")
                    Spacer()
                    Text(controller.currentPixelFormatSummary)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                if let warning = controller.scalingWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("重新校验设备格式") { controller.applyPreferredFormat(force: true) }
            }

            Section("输出像素格式（videoSettings）") {
                Picker("像素格式", selection: $settings.capture.outputPixelFormat) {
                    Text("自动（420f，零拷贝 YUV）").tag("")
                    ForEach(controller.availableOutputFormats) { option in
                        Text(option.pickerTitle).tag(option.id)
                    }
                }
                if let chosen = settings.selectedOutputFormat(in: controller.availableOutputFormats) {
                    Text("\(chosen.id) · \(chosen.label)\n\(chosen.detail)")
                        .font(.caption)
                        .foregroundColor(chosen.supported ? .secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("由 AVCaptureVideoDataOutput.availableVideoPixelFormatTypes 运行时枚举。Windows 上的 RGB24 属于驱动/DirectShow 转换出的 pin，不是 UVC 采集卡送出的原生格式；macOS 这边对应的是 BGRA32（32-bit 对齐，Metal 可零拷贝）。24-bit packed RGB 在 Metal 里没有对应纹理格式。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = controller.outputFormatWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("实际输出缓冲")
                    Spacer()
                    Text(controller.currentPixelFormatSummary)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Button("重新枚举输出格式") { controller.refreshOutputFormats() }
            }

            Section("音频") {
                Toggle("静音（透传音量置 0）", isOn: $settings.capture.audioMuted)
                HStack {
                    Text("音量")
                    Slider(value: $settings.capture.audioVolume, in: 0...1, step: 0.01)
                    Text(String(format: "%.0f%%", settings.capture.audioVolume * 100))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                .disabled(settings.capture.audioMuted)
            }
        }
    }

    // MARK: 画面

    private var picturePane: some View {
        Form {
            Section("色彩空间") {
                Picker("YUV → RGB 矩阵", selection: $settings.picture.colorMatrix) {
                    ForEach(ColorMatrixPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("亮度范围", selection: $settings.picture.rangeMode) {
                    ForEach(YUVRangeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("MS2109 / MS2130 类采集卡常输出 full-range NV12。若画面发灰、发白或过曝，手动在 Full / Limited 之间切换即可对比。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("画面调整（GPU 实时生效）") {
                sliderRow("亮度", value: $settings.picture.brightness, range: -0.5...0.5, format: "%+.2f")
                sliderRow("对比度", value: $settings.picture.contrast, range: 0.5...2.0, format: "%.2f")
                sliderRow("饱和度", value: $settings.picture.saturation, range: 0...2.0, format: "%.2f")
                Button("恢复画面默认值") { settings.resetPicture() }
            }

            Section("几何与采样") {
                Picker("画面填充", selection: $settings.picture.aspectMode) {
                    ForEach(AspectMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("缩放滤镜", selection: $settings.picture.filter) {
                    ForEach(ScalingFilter.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("水平镜像", isOn: $settings.picture.flipHorizontal)
                Toggle("垂直翻转", isOn: $settings.picture.flipVertical)
            }
        }
    }

    // MARK: 状态

    private var statusPane: some View {
        Form {
            Section("运行状态") {
                infoRow("设备 activeFormat", controller.activeFormatSummary)
                infoRow("设备 UVC 线格式", controller.deviceNativeFormatSummary)
                infoRow("输出 CVPixelBuffer", controller.currentPixelFormatSummary)
                infoRow("请求的输出像素格式", settings.capture.outputPixelFormat.isEmpty
                        ? "自动（420f）" : settings.capture.outputPixelFormat)
                infoRow("设备尺寸", controller.activeWidth > 0
                        ? "\(controller.activeWidth) × \(controller.activeHeight)" : "—")
                infoRow("已连接设备", "\(controller.availableDevices.count) 个")
                infoRow("候选采集格式", "\(controller.availableFormats.count) 种")
                infoRow("可请求像素格式", "\(controller.availableOutputFormats.count) 种")
            }
            if let warning = controller.outputFormatWarning {
                Section("像素格式告警") {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let warning = controller.scalingWarning {
                Section("缩放告警") {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新应用格式") { controller.applyPreferredFormat(force: true) }
                }
            }
            Section("4K / 高帧率说明") {
                Text("设备 activeFormat 是采集卡真正输出的档位；CVPixelBuffer 是 AVCaptureVideoDataOutput 交付给渲染器的缓冲。两者尺寸不同说明发生了缩放或驱动降档。3840×2160 @ 144 fps 未压缩约需 1.8 GB/s，2560×1440 @ 144 fps 约需 800 MB/s，都超过 USB 3.2 Gen1，实际能否跑满取决于采集卡是否用 MJPEG / H.264 / DSC 压缩以及所接的 USB 控制器。带宽不够时驱动会静默降档，状态页会显示告警。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("快捷键") {
                infoRow("全屏切换", "⌘F")
                infoRow("副屏全屏", "⌘⇧F")
                infoRow("刷新设备", "⌘R")
                infoRow("参数设置", "⌘,")
            }
            Section("说明") {
                Text("所有参数写入 UserDefaults，重启后保留。分辨率只在设备真实支持的格式里选；矩阵、范围与画面调整全部在 Metal 片元着色器中完成，不增加帧拷贝，不改变 OBS 式 vsync 取帧逻辑。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("重置全部参数") { settings.resetAll() }
            }
        }
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           format: String) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}
