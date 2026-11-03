import AppKit
import AVFoundation
import SwiftUI

// Inert engine exercises the production AppModel without camera access or CMIO.
struct CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class CameraDiscovery: NSObject {
    @objc dynamic var devices: [AVCaptureDevice] = []
}

@MainActor final class VideoPreviewFeed {
    var sample: CMSampleBuffer?
}

final class CameraEngine {
    static let discoverySession = CameraDiscovery()
    static var choices = [CameraChoice(id: "one", name: "One"), CameraChoice(id: "two", name: "Two")]
    static var latest: CameraEngine!
    var onPreview: (@MainActor (CMSampleBuffer) -> Void)?
    var onOutputStatus: ((VirtualCameraStatus) -> Void)?
    var onDemand: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts: [String] = []
    var stops = 0
    var startCompletion: ((Error?) -> Void)?
    var stopCompletion: (() -> Void)?
    var holdStop = false

    init(configuration: OverlayConfiguration) throws { Self.latest = self }
    static func cameras() -> [CameraChoice] { choices }
    func refreshVirtualCameraAvailability() {}
    func showPlaceholder() {}
    func setOverlayEnabled(_ enabled: Bool) {}
    func configure(_ configuration: OverlayConfiguration, completion: @escaping (Error?) -> Void) { completion(nil) }
    func start(cameraID: String, completion: @escaping (Error?) -> Void) {
        starts.append(cameraID)
        startCompletion = completion
    }
    func finishStart(_ error: Error? = nil) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }
    func stop(completion: (() -> Void)? = nil) {
        stops += 1
        if holdStop { stopCompletion = completion } else { completion?() }
    }
    func finishStop() {
        let completion = stopCompletion
        stopCompletion = nil
        completion?()
    }
}

@main @MainActor enum CameraDemandChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
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
    }

    static func main() async {
        do { try await run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
