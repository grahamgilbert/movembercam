import SwiftUI
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: ((@escaping () -> Void) -> Void)?
    var openSettings: (() -> Void)?
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil ||
            event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
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

    var body: some Scene {
        WindowGroup("MovemberCam", id: "main") {
            MainWindow(model: model, installer: installer, loginItem: loginItem, location: location)
                .onAppear { delegate.shutdown = { completion in model.shutdown(completion: completion) } }
        }
        .defaultSize(width: 1280, height: 980)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            SetupGuideCommands()
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button(model.isRunning ? "Stop Camera" : "Start Camera") {
                    if model.isRunning { model.stop() } else { model.start() }
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(model.isBusy || model.selectedCameraID.isEmpty)
                Button("Refresh Cameras", action: model.refreshCameras)
                Toggle("Enable Overlay", isOn: $model.isOverlayEnabled)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Install Virtual Camera", action: installer.install).disabled(installer.busy)
                Button("Remove Virtual Camera", action: installer.uninstall).disabled(installer.busy || model.isRunning)
            }
        }
        Window("MovemberCam Setup", id: "setup") {
            OnboardingView(model: model, installer: installer, loginItem: loginItem, location: location)
        }
        .defaultSize(width: 820, height: 740)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuBarControls(model: model)
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
                if CommandLine.arguments.contains("--show-setup") {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                } else if CommandLine.arguments.contains("--show-settings") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct MenuBarControls: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "MovemberCam · Camera live" : "MovemberCam · Camera off")
        Toggle("Enable overlay", isOn: $model.isOverlayEnabled)
        Button(model.isRunning ? "Stop camera" : "Start camera") {
            if model.isRunning { model.stop() } else { model.start() }
        }.disabled(model.isBusy || model.selectedCameraID.isEmpty)
        Divider()
        Button("Open settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Setup guide…") {
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit MovemberCam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SetupGuideCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("MovemberCam Setup Guide…") { openWindow(id: "setup") }
        }
    }
}
