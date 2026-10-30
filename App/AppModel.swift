import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var draft: OverlayConfiguration
    @Published private(set) var applied: OverlayConfiguration
    @Published var cameras: [CameraChoice] = []
    @Published private(set) var virtualCameraStatus = VirtualCameraStatus.idle(isInstalled: false)
    var virtualCameraAvailable: Bool { virtualCameraStatus.isInstalled }
    var outputStatus: String { virtualCameraStatus.message }
    @Published private(set) var selectedCameraID = ""
    let previewFeed = VideoPreviewFeed()
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var isApplying = false
    @Published var error: String?
    @Published var cameraDenied = false
    @Published var isOverlayEnabled = true {
        didSet {
            engine?.setOverlayEnabled(isOverlayEnabled)
            UserDefaults.standard.set(isOverlayEnabled, forKey: "MovemberCam.overlayEnabled")
        }
    }
    private var engine: CameraEngine?
    private var observers: [NSObjectProtocol] = []
    private var cameraObservation: NSKeyValueObservation?
    private var generation = UUID()

    init() {
        let stored = OverlayPreferences.load()
        draft = stored
        applied = stored
        do {
            let engine = try CameraEngine(configuration: stored)
            self.engine = engine
            isOverlayEnabled = UserDefaults.standard.object(forKey: "MovemberCam.overlayEnabled") as? Bool ?? true
            engine.setOverlayEnabled(isOverlayEnabled)
            engine.onPreview = { [weak self] sample in self?.previewFeed.sample = sample }
            engine.onOutputStatus = { [weak self] status in Task { @MainActor in self?.virtualCameraStatus = status } }
            engine.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.error = message
                    self.stop()
                }
            }
            engine.showPlaceholder()
        } catch { self.error = error.localizedDescription }
        refreshCameras()
        cameraObservation = CameraEngine.discoverySession.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshCameras() }
        }
        selectedCameraID = UserDefaults.standard.string(forKey: "MovemberCam.cameraID") ?? ""
        if !cameras.contains(where: { $0.id == selectedCameraID }) { selectedCameraID = cameras.first?.id ?? "" }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    var hasChanges: Bool { draft != applied }
    var cameraControls: CameraControlState {
        let permission: CameraControlState.Permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = .allowed
        case .notDetermined: permission = .notRequested
        default: permission = .blocked
        }
        return CameraControlState(permission: permission, isRunning: isRunning, isBusy: isBusy, hasCamera: !selectedCameraID.isEmpty)
    }

    func performCameraAction() {
        switch cameraControls.action {
        case .start: start()
        case .stop: stop()
        case .openSettings: openCameraSettings()
        case .requestAccess:
            guard !isBusy else { return }
            isBusy = true
            Task {
                let authorized = await AVCaptureDevice.requestAccess(for: .video)
                cameraDenied = !authorized
                error = authorized ? nil : "Allow MovemberCam in System Settings → Privacy & Security → Camera."
                isBusy = false
                refreshCameras()
            }
        }
    }
    var validationMessage: String? {
        do { _ = try draft.validated(); return nil } catch { return error.localizedDescription }
    }

    func refreshCameras() {
        cameras = CameraEngine.cameras()
        engine?.refreshVirtualCameraAvailability()
        if !cameras.contains(where: { $0.id == selectedCameraID }) {
            if isRunning || isBusy {
                stop()
                error = "The selected camera disconnected. Choose a camera and start again."
            }
            selectedCameraID = cameras.first?.id ?? ""
        }
    }

    func apply() {
        do {
            let valid = try draft.validated()
            guard let engine else { return }
            isApplying = true
            engine.configure(valid) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isApplying = false
                    if let error { self.error = error.localizedDescription; return }
                    self.applied = valid
                    self.draft = valid
                    OverlayPreferences.save(valid)
                    self.error = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func selectCamera(_ cameraID: String) {
        guard !isBusy, cameraID != selectedCameraID,
              cameras.contains(where: { $0.id == cameraID }) else { return }
        selectedCameraID = cameraID
        UserDefaults.standard.set(cameraID, forKey: "MovemberCam.cameraID")
        if isRunning { stop(restarting: true) }
    }

    func start() {
        guard !isBusy, !isRunning, !selectedCameraID.isEmpty, engine != nil else { return }
        error = nil
        isBusy = true
        let token = UUID()
        generation = token
        let cameraID = selectedCameraID
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard generation == token else { return }
            guard authorized else {
                cameraDenied = true
                error = "Camera access is off. Allow MovemberCam in System Settings → Privacy & Security → Camera."
                isBusy = false
                return
            }
            cameraDenied = false
            self.engine?.start(cameraID: cameraID) { [weak model = self] error in
                Task { @MainActor in
                    guard let self = model, self.generation == token else { return }
                    self.isBusy = false
                    self.isRunning = error == nil
                    self.error = error?.localizedDescription
                    if error == nil { UserDefaults.standard.set(cameraID, forKey: "MovemberCam.cameraID") }
                }
            }
        }
    }

    func stop() {
        stop(restarting: false)
    }

    private func stop(restarting: Bool) {
        let token = UUID()
        generation = token
        isBusy = true
        engine?.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.isRunning = false
                self.isBusy = false
                self.virtualCameraStatus = .idle(isInstalled: self.virtualCameraAvailable)
                if restarting { self.start() }
            }
        }
        if engine == nil { isRunning = false; isBusy = false }
    }

    func shutdown(completion: @escaping () -> Void) {
        generation = UUID()
        guard let engine else { completion(); return }
        engine.stop(completion: completion)
    }

    func prepareForRestart(completion: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        shutdown {
            Task { @MainActor in
                self.isRunning = false
                self.isBusy = false
                completion()
            }
        }
    }

    func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
}
