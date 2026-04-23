import SwiftUI
import AVFoundation

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
