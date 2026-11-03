import SwiftUI
import Carbon
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openSettings: (() -> Void)?
    private weak var model: AppModel?
    private weak var attention: CameraAttentionController?
    private var finishedLaunching = false
    private var windowObservers: [NSObjectProtocol] = []

    @MainActor
    func settingsDidAppear(model: AppModel, installer: ExtensionInstaller,
                           attention: CameraAttentionController, location: AppLocationManager) {
        self.model = model
        self.attention = attention
        attention.onShowSettings = { [weak self] in self?.showSettingsWindow() }
        attention.bind(model: model, installer: installer) {
            model.prepareForRestart {
                installer.noteAppRestart()
                location.restart()
            }
        }
        shutdown = { completion in
            attention.prepareForTermination()
            model.shutdown(completion: completion)
        }
        if windowObservers.isEmpty {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow,
                              window.title == "MovemberCam" else { return }
                        self.updatePreviewVisibility(closing: name == NSWindow.willCloseNotification)
                    }
                })
            }
        }
        updatePreviewVisibility()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "Lifecycle")
            .notice("App launched version=\(version, privacy: .public) build=\(build, privacy: .public) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil ||
            event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                self.finishedLaunching = true
                if atLogin { self.settingsWindow?.orderOut(nil) }
                else { self.showSettingsWindow() }
                self.updatePreviewVisibility()
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
    func showSettingsWindow() {
        NSApp.unhide(nil)
        if let settingsWindow {
            settingsWindow.deminiaturize(nil)
            settingsWindow.makeKeyAndOrderFront(nil)
        }
        else { openSettings?() }
        NSApp.activate(ignoringOtherApps: true)
        updatePreviewVisibility()
    }
    private func updatePreviewVisibility(closing: Bool = false) {
        // Wait until login launch has hidden Settings before considering preview demand.
        guard finishedLaunching else { return }
        let window = settingsWindow
        let visible = !closing && window?.isVisible == true && window?.isMiniaturized == false && !NSApp.isHidden
        model?.setPreviewVisible(visible)
    }
    func applicationDidHide(_ notification: Notification) { updatePreviewVisibility() }
    func applicationDidUnhide(_ notification: Notification) { updatePreviewVisibility() }
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
    @StateObject private var attention = CameraAttentionController()
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var location = AppLocationManager()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("MovemberCam", id: "main") {
            MainWindow(model: model, installer: installer, loginItem: loginItem, location: location, updater: updater, attention: attention)
                .onAppear { delegate.settingsDidAppear(model: model, installer: installer, attention: attention, location: location) }
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
                    NSApp.activate(ignoringOtherApps: true)
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
