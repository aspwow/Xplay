import SwiftUI
import AppKit

@main
struct XplayApp: App {
    @StateObject private var controller = CaptureController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 640, minHeight: 360)
                .background(WindowAccessor())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .help) { }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .textFormatting) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .sidebar) { }
            CommandMenu("Source") {
                SourceMenu(controller: controller)
            }
            CommandMenu("View") {
                Button("Toggle Full Screen") { FullScreen.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Full Screen on Other Display") { FullScreen.enterOnOther() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                FullScreenDisplayMenu()
            }
        }
    }
}

private struct SourceMenu: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        if controller.availableDevices.isEmpty {
            Text("No capture devices")
        } else {
            ForEach(controller.availableDevices, id: \.uniqueID) { device in
                Button {
                    controller.select(device: device)
                } label: {
                    if device.uniqueID == controller.currentDeviceID {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
        }
        Divider()
        Button("Refresh Devices") {
            controller.refreshDevices()
        }
        .keyboardShortcut("r", modifiers: .command)
    }
}

private struct FullScreenDisplayMenu: View {
    var body: some View {
        let screens = NSScreen.screens
        if screens.count > 1 {
            ForEach(Array(screens.enumerated()), id: \.offset) { _, screen in
                Button("Full Screen on \(screen.localizedName)") {
                    FullScreen.enter(on: screen)
                }
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.title = ""
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            context.coordinator.attach(to: window)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        weak var window: NSWindow?
        private let lockedAspect = NSSize(width: 16, height: 9)

        func attach(to window: NSWindow) {
            self.window = window
            window.contentAspectRatio = lockedAspect

            let nc = NotificationCenter.default
            nc.addObserver(self,
                           selector: #selector(willEnterFullScreen),
                           name: NSWindow.willEnterFullScreenNotification,
                           object: window)
            nc.addObserver(self,
                           selector: #selector(didExitFullScreen),
                           name: NSWindow.didExitFullScreenNotification,
                           object: window)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func willEnterFullScreen() {
            window?.contentAspectRatio = .zero
        }

        @objc private func didExitFullScreen() {
            window?.contentAspectRatio = lockedAspect
        }
    }
}

enum FullScreen {
    static func toggle() {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }

    static func enterOnOther() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            window.toggleFullScreen(nil)
            return
        }
        let current = window.screen ?? screens.first!
        let other = screens.first(where: { $0 != current }) ?? current
        enter(on: other)
    }

    static func enter(on screen: NSScreen) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        let goFS = {
            var frame = window.frame
            frame.origin = screen.frame.origin
            window.setFrame(frame, display: true)
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: goFS)
        } else {
            goFS()
        }
    }
}
