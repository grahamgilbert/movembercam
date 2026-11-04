import SwiftUI

@main
enum MovemberCamEntry {
    static func main() {
        if CommandLine.arguments.contains(CameraDiscoveryProbe.argument) {
            exit(CameraDiscoveryProbe.inspect().rawValue)
        }
        MovemberCamApp.main()
    }
}

struct MovemberCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var attention = CameraAttentionController()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var location = AppLocationManager()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("MovemberCam", id: "main") {
            MainWindow(model: model, installer: installer, loginItem: loginItem, location: location, updater: updater, attention: attention, onPreviewTabChanged: delegate.previewTabChanged)
                .onAppear { delegate.settingsDidAppear(model: model, installer: installer, attention: attention, location: location) }
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                if model.cameraControls.action != nil {
                    Button(model.cameraControls.title, action: model.performCameraAction)
                        .disabled(!model.cameraControls.isEnabled)
                }
                Button("Refresh Cameras", action: model.retryCamera)
                Toggle("Enable Overlay", isOn: $model.isOverlayEnabled)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Install Virtual Camera", action: installer.install).disabled(installer.busy)
                Button("Remove Virtual Camera", action: installer.uninstall).disabled(installer.busy || model.isRunning)
            }
        }
        MenuBarExtra {
            MenuBarControls(installer: installer, model: model, updater: updater, attention: attention)
        } label: {
            MenuBarIcon(delegate: delegate, model: model, installer: installer, attention: attention, location: location)
        }
    }
}

struct MenuBarIcon: View {
    let delegate: AppDelegate
    let model: AppModel
    let installer: ExtensionInstaller
    @ObservedObject var attention: CameraAttentionController
    let location: AppLocationManager
    @Environment(\.openWindow) private var openWindow
    @State private var handledRelaunch = false

    var body: some View {
        Image(nsImage: MenuBarStatusImage.make(needsAttention: attention.issue != nil))
            .accessibilityLabel(attention.issue.map { "MovemberCam: " + $0.title } ?? "MovemberCam")
            .help(attention.issue?.title ?? "MovemberCam")
            .onAppear {
                delegate.openSettings = { openWindow(id: "main") }
                delegate.settingsDidAppear(model: model, installer: installer, attention: attention, location: location)
                guard !handledRelaunch else { return }
                handledRelaunch = true
                if CommandLine.arguments.contains("--show-settings") {
                    openWindow(id: "main")
                    if !CommandLine.arguments.contains("--background-recovery") {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }
}

struct MenuBarControls: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var attention: CameraAttentionController

    var body: some View {
        if attention.issue == nil {
            Text(installer.state.connectionSummary ?? (model.isRunning ? "MovemberCam · Camera live" : "MovemberCam · Waiting for a video app"))
        }
        if attention.issue?.recovery == .restartZoom {
            Button("Restart Zoom", action: attention.recover).disabled(!attention.canRecover)
        }
        Toggle("Enable overlay", isOn: $model.isOverlayEnabled)
        if model.cameraControls.action != nil {
            Button(model.cameraControls.title, action: model.performCameraAction)
                .disabled(!model.cameraControls.isEnabled)
        }
        Divider()
        Button("Open settings…", action: attention.showSettings)
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("Quit MovemberCam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
