import SwiftUI
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openSettings: (() -> Void)?
    private var handledCaptureResume = false
    private var launchedAtLogin = false

    @MainActor
    func settingsDidAppear(model: AppModel) {
        shutdown = { completion in model.shutdown(completion: completion) }
        guard !handledCaptureResume else { return }
        handledCaptureResume = true
        if LaunchBehavior(arguments: CommandLine.arguments, launchedAtLogin: launchedAtLogin).resumeCamera {
            model.start()
        }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil ||
            event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
        launchedAtLogin = atLogin
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                if atLogin { self.settingsWindow?.orderOut(nil) }
                else { self.showSettingsWindow() }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettingsWindow() }
        return true
    }
    private var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.title == "MovemberCam" }
    }
    private func showSettingsWindow() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil) }
        else { openSettings?() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        shutdown {
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
}

@main
struct MovemberCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var location = AppLocationManager()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("MovemberCam", id: "main") {
            MainWindow(model: model, installer: installer, loginItem: loginItem, location: location, updater: updater)
                .onAppear { delegate.settingsDidAppear(model: model) }
        }
        .defaultSize(width: 1280, height: 980)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button(model.cameraControls.title, action: model.performCameraAction)
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!model.cameraControls.isEnabled)
                Button("Refresh Cameras", action: model.refreshCameras)
                Toggle("Enable Overlay", isOn: $model.isOverlayEnabled)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Install Virtual Camera", action: installer.install).disabled(installer.busy)
                Button("Remove Virtual Camera", action: installer.uninstall).disabled(installer.busy || model.isRunning)
            }
        }
        MenuBarExtra {
            MenuBarControls(model: model, updater: updater)
        } label: {
            MenuBarIcon(delegate: delegate)
        }
    }
}

struct MenuBarIcon: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var handledRelaunch = false

    var body: some View {
        Image(systemName: "mustache.fill")
            .accessibilityLabel("MovemberCam")
            .onAppear {
                delegate.openSettings = { openWindow(id: "main") }
                guard !handledRelaunch else { return }
                handledRelaunch = true
                if CommandLine.arguments.contains("--show-settings") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "MovemberCam · Camera live" : "MovemberCam · Camera off")
        Toggle("Enable overlay", isOn: $model.isOverlayEnabled)
        Button(model.cameraControls.title, action: model.performCameraAction)
            .disabled(!model.cameraControls.isEnabled)
        Divider()
        Button("Open settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
        Divider()
        Button("Quit MovemberCam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
