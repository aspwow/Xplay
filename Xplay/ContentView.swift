import SwiftUI
import AppKit
import AVFoundation
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

struct CaptureParams: Codable, Equatable {
    /// "" = 自动；否则是 CaptureFormatOption.id（形如 "1920x1080@6000"）
    var formatKey: String = ""
    var audioVolume: Double = 1
    var audioMuted: Bool = false

    static let defaults = CaptureParams()
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
                    Button("重新应用格式") { controller.applyPreferredFormat() }
                }
            }

            Section("分辨率 / 帧率") {
                Picker("采集格式", selection: $settings.capture.formatKey) {
                    Text("自动（优先 1920×1080 @ 60 fps）").tag("")
                    ForEach(controller.availableFormats) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text("列表来自设备实际支持的 AVCaptureDevice.Format，切换时立即重新锁定格式与帧时长，无需重启。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("当前生效")
                    Spacer()
                    Text(controller.activeFormatSummary)
                        .foregroundColor(.secondary)
                }
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
                infoRow("生效格式", controller.activeFormatSummary)
                infoRow("实际像素缓冲", controller.currentPixelFormatSummary)
                infoRow("已连接设备", "\(controller.availableDevices.count) 个")
                infoRow("候选格式", "\(controller.availableFormats.count) 种")
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
