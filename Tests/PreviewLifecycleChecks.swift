import AppKit
import SwiftUI

/// Uses the real Settings view, delegate, and AppKit window events with an inert camera.
@main @MainActor enum PreviewLifecycleChecks {
    static var passed: [String] = []

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        passed.append(message)
        print("PASS: \(message)")
    }

    static func eventually(_ message: String, engine: CameraEngine, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            try await Task.sleep(nanoseconds: 80_000_000)
            engine.finishStart()
            if condition() { try check(true, message); return }
        } while Date() < deadline
        try check(false, message)
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        let suite = "MovemberCam.preview-lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        UserDefaults.standard.set("app", forKey: "MovemberCam.settingsTab")
        let model = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
        let engine = CameraEngine.latest!
        let installer = ExtensionInstaller(bundledVersion: CameraExtensionVersion(release: "1.0.9", build: "21"),
            canInstall: false, submit: { _ in }, schedule: { _ in }, recoveryDefaults: defaults)
        let tracker = ZoomRestartTracker(defaults: defaults, running: { nil }, providerStarted: { nil })
        let attention = CameraAttentionController(notifications: QuietNotifications(), defaults: defaults, zoom: tracker)
        let location = AppLocationManager()
        let view = MainWindow(model: model, installer: installer, loginItem: LoginItemManager(), location: location,
            updater: AppUpdater(), attention: attention, onPreviewTabChanged: delegate.previewTabChanged)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MovemberCam"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        delegate.settingsDidAppear(model: model, installer: installer, attention: attention, location: location)
        installer.inspect([InstalledCameraExtension(version: CameraExtensionVersion(release: "1.0.9", build: "21"),
            isEnabled: true, isAwaitingApproval: false, isUninstalling: false)])
        engine.onOutputStatus?(.idle(isInstalled: true))
        window.orderFrontRegardless()
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                try check(engine.starts.isEmpty, "Opening App settings never opens the physical camera")
                UserDefaults.standard.set("camera", forKey: "MovemberCam.settingsTab")
                try await eventually("A visible Camera tab starts preview capture", engine: engine) { model.isRunning }
                let starts = engine.starts.count
                UserDefaults.standard.set("overlay", forKey: "MovemberCam.settingsTab")
                try await Task.sleep(nanoseconds: 300_000_000)
                try check(model.isRunning && engine.starts.count == starts,
                    "Switching between Camera and Overlay keeps the existing preview session")
                UserDefaults.standard.set("app", forKey: "MovemberCam.settingsTab")
                try await eventually("Switching to App stops unused capture", engine: engine) { !model.isRunning && !model.isBusy }
                UserDefaults.standard.set("camera", forKey: "MovemberCam.settingsTab")
                try await eventually("Returning to Camera restarts preview", engine: engine) { model.isRunning }
                window.miniaturize(nil)
                try await eventually("Minimizing Settings stops preview-only capture", engine: engine) { !model.isRunning && !model.isBusy }
                window.deminiaturize(nil)
                window.orderFrontRegardless()
                try await eventually("Restoring Settings resumes preview", engine: engine) { model.isRunning }
                window.orderOut(nil)
                try await eventually("Ordering Settings off screen stops capture", engine: engine) { !model.isRunning && !model.isBusy }
                window.orderFrontRegardless()
                try await eventually("Showing Settings resumes its preview", engine: engine) { model.isRunning }
                let cover = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                cover.isOpaque = true
                cover.backgroundColor = .windowBackgroundColor
                cover.level = .floating
                cover.orderFrontRegardless()
                try await eventually("Fully covering Settings releases preview-only capture", engine: engine) {
                    !window.occlusionState.contains(.visible) && !model.isRunning && !model.isBusy
                }
                engine.onDemand?(true)
                try await eventually("A video app keeps capture available while Settings is covered", engine: engine) { model.isRunning }
                UserDefaults.standard.set("app", forKey: "MovemberCam.settingsTab")
                cover.orderOut(nil)
                try await Task.sleep(nanoseconds: 300_000_000)
                try check(model.isRunning, "App settings do not interrupt an active video consumer")
                engine.onDemand?(false)
                try await eventually("The last consumer leaving App settings releases capture", engine: engine) { !model.isRunning && !model.isBusy }
                UserDefaults.standard.set("camera", forKey: "MovemberCam.settingsTab")
                try await eventually("Preview can start again after a consumer leaves", engine: engine) { model.isRunning }
                engine.onDemand?(true)
                try await Task.sleep(nanoseconds: 100_000_000)
                window.close()
                try await Task.sleep(nanoseconds: 300_000_000)
                try check(model.isRunning, "Closing Settings preserves an active video consumer")
                engine.onDemand?(false)
                try await eventually("Closing the last consumer after Settings closes releases capture", engine: engine) { !model.isRunning && !model.isBusy }
                print("\(passed.count) native preview lifecycle checks passed")
                attention.prepareForTermination()
                model.shutdown {}
                defaults.removePersistentDomain(forName: suite)
                UserDefaults.standard.removeObject(forKey: "MovemberCam.settingsTab")
                app.delegate = nil
                app.terminate(nil)
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        }
        app.run()
    }
}
