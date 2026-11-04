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
    @Published private(set) var previewFormat = VideoFormat.hd720
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var isApplying = false
    @Published var error: String?
    @Published private(set) var cameraFailure: String?
    @Published var cameraDenied = false
    @Published var isOverlayEnabled = true {
        didSet {
            engine?.setOverlayEnabled(isOverlayEnabled)
            defaults.set(isOverlayEnabled, forKey: "MovemberCam.overlayEnabled")
        }
    }
    private var engine: CameraEngine?
    private var observers: [NSObjectProtocol] = []
    private var cameraObservation: NSKeyValueObservation?
    // Automatic fallbacks must not replace the user's preferred camera.
    private var preferredCameraID: String
    private var generation = UUID()
    private var demand = CameraCaptureDemand()
    private var isShuttingDown = false
    private var isStopping = false
    private var stopCompletions: [() -> Void] = []
    private let defaults: UserDefaults
    private let cameraAuthorization: () -> AVAuthorizationStatus
    private let requestCameraAccess: () async -> Bool

    init(defaults: UserDefaults = .standard,
         restoringAfterRecovery: Bool = CommandLine.arguments.contains("--camera-recovery"),
         cameraAuthorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         requestCameraAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }) {
        self.defaults = defaults
        preferredCameraID = defaults.string(forKey: "MovemberCam.cameraID") ?? ""
        self.cameraAuthorization = cameraAuthorization
        self.requestCameraAccess = requestCameraAccess
        let stored = OverlayPreferences.load(from: defaults)
        draft = OverlayPreferences.takeRecoveryDraft(from: defaults, restoring: restoringAfterRecovery) ?? stored
        applied = stored
        do {
            let engine = try CameraEngine(configuration: stored)
            self.engine = engine
            isOverlayEnabled = defaults.object(forKey: "MovemberCam.overlayEnabled") as? Bool ?? true
            engine.setOverlayEnabled(isOverlayEnabled)
            engine.onPreview = { [weak self] sample in
                guard let self else { return }
                if let buffer = sample.imageBuffer {
                    let format = VideoFormat(buffer)
                    if format != self.previewFormat { self.previewFormat = format }
                }
                self.previewFeed.sample = sample
            }
            engine.onOutputStatus = { [weak self] status in Task { @MainActor in self?.virtualCameraStatus = status } }
            engine.onDemand = { [weak self] needed in
                Task { @MainActor in
                    guard let self else { return }
                    self.demand.update(needed)
                    self.reconcileCapture()
                }
            }
            engine.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, !self.demand.isSuspended, !self.isShuttingDown else { return }
                    self.error = message
                    self.cameraFailure = message
                    self.demand.hasFailed = true
                    self.stop()
                }
            }
            engine.showPlaceholder()
        } catch { self.error = error.localizedDescription; self.cameraFailure = error.localizedDescription }
        refreshCameras()
        cameraObservation = CameraEngine.discoverySession.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshCameras() }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            })
        }
    }

    var hasChanges: Bool { draft != applied }
    func preserveDraftForRecovery() { OverlayPreferences.preserveDraft(draft, in: defaults) }
    var cameraControls: CameraControlState {
        let permission: CameraControlState.Permission
        switch cameraAuthorization() {
        case .authorized: permission = .allowed
        case .notDetermined: permission = .notRequested
        default: permission = .blocked
        }
        return CameraControlState(permission: permission, isBusy: isBusy)
    }

    func performCameraAction() {
        switch cameraControls.action {
        case nil: return
        case .openSettings: openCameraSettings()
        case .requestAccess:
            guard !isBusy else { return }
            isBusy = true
            let token = UUID()
            generation = token
            Task {
                let authorized = await requestCameraAccess()
                guard generation == token else { return }
                cameraDenied = !authorized
                error = authorized ? nil : "Allow MovemberCam in System Settings → Privacy & Security → Camera."
                isBusy = false
                demand.hasFailed = false
                refreshCameras()
            }
        }
    }
    var validationMessage: String? {
        do { _ = try draft.validated(); return nil } catch { return error.localizedDescription }
    }

    func reconnectVirtualCamera() { engine?.reconnectVirtualCamera() }

    func retryCamera() {
        demand.hasFailed = false
        refreshCameras()
    }

    func refreshCameras() {
        if cameraDenied && cameraAuthorization() == .authorized {
            cameraDenied = false
            demand.hasFailed = false
            error = nil
        }
        cameras = CameraEngine.cameras()
        engine?.refreshVirtualCameraAvailability()
        let availableID: String
        if cameras.contains(where: { $0.id == preferredCameraID }) {
            availableID = preferredCameraID
        } else {
            availableID = cameras.contains(where: { $0.id == selectedCameraID })
                ? selectedCameraID : cameras.first?.id ?? ""
        }
        if availableID != selectedCameraID {
            let wasCapturing = isRunning || isBusy
            let disconnected = !cameras.contains(where: { $0.id == selectedCameraID })
            selectedCameraID = availableID
            demand.hasFailed = false
            if wasCapturing {
                stop()
                error = disconnected
                    ? (availableID.isEmpty ? "The selected camera disconnected. Connect a camera to continue."
                        : "The selected camera disconnected. Using the next available camera.")
                    : nil
            }
        }
        reconcileCapture()
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
                    OverlayPreferences.save(valid, to: self.defaults)
                    self.error = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func selectCamera(_ cameraID: String) {
        guard !isBusy,
              cameras.contains(where: { $0.id == cameraID }) else { return }
        preferredCameraID = cameraID
        defaults.set(cameraID, forKey: "MovemberCam.cameraID")
        guard cameraID != selectedCameraID else { return }
        selectedCameraID = cameraID
        demand.hasFailed = false
        if isRunning { stop() } else { reconcileCapture() }
    }

    func setCaptureSuspended(_ suspended: Bool) {
        demand.isSuspended = suspended
        reconcileCapture()
    }

    func setPreviewVisible(_ visible: Bool) {
        demand.showPreview(visible)
        reconcileCapture()
    }

    private func reconcileCapture() {
        guard !isBusy, !isShuttingDown else { return }
        if demand.shouldCapture && !selectedCameraID.isEmpty {
            if !isRunning { start() }
        } else if isRunning { stop() }
    }

    private func start() {
        guard demand.shouldCapture, !isBusy, !isRunning, !selectedCameraID.isEmpty, engine != nil else { return }
        error = nil
        cameraFailure = nil
        isBusy = true
        let token = UUID()
        generation = token
        let cameraID = selectedCameraID
        Task {
            let authorized: Bool
            switch cameraAuthorization() {
            case .authorized: authorized = true
            case .notDetermined: authorized = await requestCameraAccess()
            default: authorized = false
            }
            guard generation == token else { return }
            guard authorized else {
                cameraDenied = true
                error = "Camera access is off. Allow MovemberCam in System Settings → Privacy & Security → Camera."
                isBusy = false
                demand.hasFailed = true
                return
            }
            guard demand.shouldCapture else {
                isBusy = false
                reconcileCapture()
                return
            }
            cameraDenied = false
            self.engine?.start(cameraID: cameraID) { [weak model = self] error in
                Task { @MainActor in
                    guard let self = model, self.generation == token else { return }
                    self.isBusy = false
                    self.isRunning = error == nil
                    self.error = error?.localizedDescription
                    self.cameraFailure = error?.localizedDescription
                    self.demand.hasFailed = error != nil
                    if error == nil && self.preferredCameraID.isEmpty {
                        self.preferredCameraID = cameraID
                        self.defaults.set(cameraID, forKey: "MovemberCam.cameraID")
                    }
                    self.reconcileCapture()
                }
            }
        }
    }

    func prepareForExtensionUpdate(_ completion: @escaping () -> Void) {
        demand.isSuspended = true
        stop(completion: completion)
    }

    private func stop(completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        guard !isStopping else { return }
        isStopping = true
        let token = UUID()
        generation = token
        isBusy = true
        engine?.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.isRunning = false
                self.isBusy = false
                self.isStopping = false
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                completions.forEach { $0() }
                self.reconcileCapture()
            }
        }
        if engine == nil {
            isRunning = false
            isBusy = false
            isStopping = false
            let completions = stopCompletions
            stopCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        isShuttingDown = true
        demand.isSuspended = true
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
