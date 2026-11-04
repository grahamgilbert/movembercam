import AppKit
import Carbon
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openSettings: (() -> Void)?
    private weak var model: AppModel?
    private weak var attention: CameraAttentionController?
    private var finishedLaunching = false
    private var previewTabIsSelected = false
    private var previewWasVisible: Bool?
    private static let previewLogger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "PreviewDemand")
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
        installer.restartForStaleDiscovery = { [weak self, weak model, weak location] in
            guard let self, let model, let location, !model.isBusy, !location.isMoving else { return false }
            model.preserveDraftForRecovery()
            let visible = self.settingsWindow?.isVisible == true &&
                self.settingsWindow?.isMiniaturized == false && !NSApp.isHidden
            return location.restart(showSettings: visible, activates: NSRunningApplication.current.isActive,
                                    cameraRecovery: true)
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
                let launch = LaunchBehavior(arguments: CommandLine.arguments, launchedAtLogin: atLogin)
                if !launch.showSettings { self.settingsWindow?.orderOut(nil) }
                else if CommandLine.arguments.contains("--background-recovery") {
                    self.settingsWindow?.orderFront(nil)
                } else { self.showSettingsWindow() }
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
    func previewTabChanged(_ selected: Bool) {
        previewTabIsSelected = selected
        updatePreviewVisibility()
    }

    private func updatePreviewVisibility(closing: Bool = false) {
        // Wait until login launch has hidden Settings before considering preview demand.
        guard finishedLaunching else { return }
        let window = settingsWindow
        let windowVisible = window?.isVisible == true
        let unoccluded = window?.occlusionState.contains(.visible) == true
        let minimized = window?.isMiniaturized == true
        let visible = previewTabIsSelected && !closing && windowVisible && unoccluded && !minimized && !NSApp.isHidden
        if visible != previewWasVisible {
            Self.previewLogger.notice("Settings preview demand=\(visible, privacy: .public) previewTab=\(self.previewTabIsSelected, privacy: .public) windowVisible=\(windowVisible, privacy: .public) unoccluded=\(unoccluded, privacy: .public) minimized=\(minimized, privacy: .public) appHidden=\(NSApp.isHidden, privacy: .public)")
            previewWasVisible = visible
        }
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
