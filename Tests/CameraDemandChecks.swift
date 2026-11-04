import AppKit
import AVFoundation
import SwiftUI

@main @MainActor enum CameraDemandChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    static func checkPreferredCamera() async throws {
        let suite = "MovemberCam.PreferredCameraChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let originalChoices = CameraEngine.choices
        defer {
            defaults.removePersistentDomain(forName: suite)
            CameraEngine.choices = originalChoices
        }
        let internalCamera = CameraChoice(id: "internal", name: "Internal")
        let externalCamera = CameraChoice(id: "external", name: "External")
        CameraEngine.choices = [internalCamera, externalCamera]
        let model = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
        model.selectCamera("external")
        let engine = CameraEngine.latest!
        engine.onDemand?(true)
        await settle()
        engine.finishStart()
        await settle()

        CameraEngine.choices = [internalCamera]
        model.refreshCameras()
        await settle()
        engine.finishStart()
        await settle()
        try check(model.isRunning && engine.starts == ["external", "internal"],
                  "Disconnecting the preferred camera starts the fallback")
        try check(defaults.string(forKey: "MovemberCam.cameraID") == "external",
                  "Starting the fallback preserves the preferred camera")

        CameraEngine.choices = [internalCamera, externalCamera]
        model.refreshCameras()
        await settle()
        try check(model.selectedCameraID == "external" && engine.starts.last == "external",
                  "Reconnecting the preferred camera switches active capture back")
        engine.finishStart()
        await settle()
        let starts = engine.starts.count
        model.refreshCameras()
        await settle()
        try check(engine.starts.count == starts, "Repeated discovery does not restart the preferred camera")

        CameraEngine.choices = [internalCamera]
        model.refreshCameras()
        await settle()
        engine.finishStart()
        await settle()
        model.shutdown {}

        let relaunched = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
        try check(relaunched.selectedCameraID == "internal", "Launch uses a fallback while the preference is absent")
        CameraEngine.choices = [internalCamera, externalCamera]
        relaunched.refreshCameras()
        try check(relaunched.selectedCameraID == "external" && CameraEngine.latest.starts.isEmpty,
                  "The preferred camera is restored after relaunch without opening idle hardware")

        CameraEngine.choices = [internalCamera]
        relaunched.refreshCameras()
        relaunched.selectCamera("internal")
        CameraEngine.choices = [internalCamera, externalCamera]
        relaunched.refreshCameras()
        try check(relaunched.selectedCameraID == "internal"
                  && defaults.string(forKey: "MovemberCam.cameraID") == "internal",
                  "Explicitly selecting the fallback replaces the old preference")
        relaunched.shutdown {}
    }

    static func run() async throws {
        let suite = "MovemberCam.CameraDemandChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("one", forKey: "MovemberCam.cameraID")
        let model = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
        let engine = CameraEngine.latest!
        try check(engine.starts.isEmpty, "Launch leaves the physical camera closed")
        engine.onDemand?(true)
        await settle()
        try check(engine.starts == ["one"] && model.isBusy, "Consumer demand starts the selected camera")
        engine.onDemand?(false)
        await settle()
        engine.finishStart()
        await settle()
        try check(!model.isRunning && !model.isBusy && engine.stops == 1,
                  "Consumer closing during startup releases capture after startup completes")

        engine.onDemand?(true)
        await settle()
        engine.finishStart()
        await settle()
        try check(model.isRunning, "A later consumer session starts capture again")
        model.selectCamera("two")
        await settle()
        try check(engine.starts.last == "two", "Camera switching restarts capture while demand remains")
        engine.finishStart()
        await settle()

        engine.holdStop = true
        engine.onDemand?(false)
        await settle()
        engine.onDemand?(true)
        await settle()
        let startsBeforeStop = engine.starts.count
        engine.finishStop()
        await settle()
        try check(engine.starts.count == startsBeforeStop + 1,
                  "Demand arriving during shutdown resumes after the old capture stops")
        engine.holdStop = false
        engine.finishStart()
        await settle()

        var prepared = false
        engine.holdStop = true
        let stopsBeforeUpdate = engine.stops
        model.setCaptureSuspended(true)
        model.prepareForExtensionUpdate { prepared = true }
        CameraEngine.choices = []
        model.refreshCameras()
        CameraEngine.choices = [CameraChoice(id: "two", name: "Two")]
        model.refreshCameras()
        engine.finishStop()
        engine.holdStop = false
        await settle()
        let pausedStarts = engine.starts.count
        engine.onDemand?(true)
        await settle()
        try check(prepared && !model.isRunning && engine.starts.count == pausedStarts && engine.stops == stopsBeforeUpdate + 1,
                  "Extension replacement completes one shared stop despite concurrent camera changes")
        model.setCaptureSuspended(false)
        await settle()
        try check(engine.starts.count == pausedStarts + 1, "Capture resumes after replacement if a consumer remains")
        engine.finishStart(VideoError.message("Controlled failure"))
        await settle()
        engine.onDemand?(true)
        await settle()
        try check(!model.isBusy && !model.isRunning && engine.starts.count == pausedStarts + 1,
                  "A failed camera does not enter an automatic retry loop")
        model.retryCamera()
        await settle()
        try check(engine.starts.count == pausedStarts + 2, "Refresh Cameras retries a failed capture")
        engine.finishStart()
        await settle()

        CameraEngine.choices = []
        model.refreshCameras()
        await settle()
        try check(!model.isRunning && model.selectedCameraID.isEmpty, "Unplugging the last camera releases capture")
        CameraEngine.choices = [CameraChoice(id: "one", name: "One")]
        model.refreshCameras()
        await settle()
        try check(engine.starts.last == "one" && model.isBusy, "Reconnecting a camera resumes an active consumer")
        engine.finishStart()
        await settle()
        model.shutdown {}
        engine.onDemand?(true)
        model.setCaptureSuspended(false)
        await settle()
        try check(engine.startCompletion == nil, "App termination cannot restart capture")

        var permission: AVAuthorizationStatus = .notDetermined
        var grant: CheckedContinuation<Bool, Never>?
        let permissionModel = AppModel(defaults: defaults, cameraAuthorization: { permission }, requestCameraAccess: {
            await withCheckedContinuation { grant = $0 }
        })
        let permissionEngine = CameraEngine.latest!
        permissionEngine.onDemand?(true)
        await settle()
        try check(grant != nil && permissionEngine.starts.isEmpty, "Demand requests permission before opening hardware")
        permissionEngine.onDemand?(false)
        await settle()
        permission = .authorized
        grant?.resume(returning: true)
        await settle()
        try check(permissionEngine.starts.isEmpty && !permissionModel.isBusy,
                  "Granting permission after the consumer closes does not open the camera")
        permissionEngine.onDemand?(true)
        await settle()
        permissionEngine.finishStart()
        await settle()
        try check(permissionModel.isRunning, "A new consumer can use the granted permission")
        permissionModel.shutdown {}

        permission = .denied
        let blocked = AppModel(defaults: defaults, cameraAuthorization: { permission })
        let blockedEngine = CameraEngine.latest!
        blockedEngine.onDemand?(true)
        await settle()
        try check(blocked.cameraDenied && blockedEngine.starts.isEmpty, "Denied access keeps hardware closed")
        permission = .authorized
        blocked.refreshCameras()
        await settle()
        try check(!blocked.cameraDenied && blockedEngine.starts.count == 1,
                  "Granting access in System Settings resumes an active consumer")
        blocked.shutdown {}

        let preview = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
        let previewEngine = CameraEngine.latest!
        preview.setPreviewVisible(true)
        await settle()
        try check(previewEngine.starts.count == 1, "Opening Settings starts capture without a virtual consumer")
        previewEngine.finishStart()
        await settle()
        previewEngine.onDemand?(true)
        await settle()
        preview.setPreviewVisible(false)
        await settle()
        try check(preview.isRunning && previewEngine.stops == 0,
                  "Closing Settings preserves capture for an active video app")
        previewEngine.onDemand?(false)
        await settle()
        try check(!preview.isRunning && previewEngine.stops == 1,
                  "Closing the last preview or virtual consumer releases capture")
        preview.setPreviewVisible(true)
        await settle()
        previewEngine.finishStart()
        await settle()
        previewEngine.onDemand?(false)
        await settle()
        try check(preview.isRunning, "Idle virtual camera does not stop the open Settings preview")
        preview.setPreviewVisible(false)
        await settle()
        try check(!preview.isRunning, "Closing Settings alone releases a preview-only capture")
        preview.shutdown {}
        try await checkPreferredCamera()
    }

    static func main() async {
        do { try await run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
