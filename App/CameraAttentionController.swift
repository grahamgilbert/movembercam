import AppKit
import Combine

/// Lives with the menu bar app, so recovery remains observable with Settings closed.
@MainActor
final class CameraAttentionController: ObservableObject {
    @Published private(set) var issue: CameraAttentionIssue?
    @Published private(set) var notificationsAvailable: Bool?
    var onShowSettings: (() -> Void)? {
        didSet {
            if pendingShowSettings, onShowSettings != nil {
                pendingShowSettings = false
                onShowSettings?()
            }
        }
    }
    private let notifications: CameraIssueNotifying
    private let defaults: UserDefaults
    private let zoom: ZoomRestartTracker
    // 1.0.4 could record a delivered notification whose foreground banner was
    // suppressed. Allow one corrected alert for an unresolved issue after upgrading.
    private static let deliveredKey = "MovemberCam.deliveredCameraIssues.v2"
    private var policy: CameraAttentionNotificationPolicy
    private var subscriptions: Set<AnyCancellable> = []
    private weak var model: AppModel?
    private weak var installer: ExtensionInstaller?
    private var restartApp: (() -> Void)?
    private var deliveryTask: Task<Void, Never>?
    private var pendingShowSettings = false
    private var stopped = false
    private var isWorking = false

    init(notifications: CameraIssueNotifying? = nil, defaults: UserDefaults = .standard, zoom: ZoomRestartTracker? = nil) {
        let notifications = notifications ?? CameraIssueNotifications()
        self.notifications = notifications
        self.defaults = defaults
        self.zoom = zoom ?? ZoomRestartTracker(defaults: defaults)
        policy = CameraAttentionNotificationPolicy(delivered: Set((defaults.stringArray(forKey: Self.deliveredKey) ?? [])
            .compactMap(CameraAttentionIssue.Kind.init(rawValue:))))
        notifications.onOpenSettings = { [weak self] in self?.showSettings() }
        notifications.onRecover = { [weak self] kind in
            guard self?.issue?.kind == kind else { return }
            self?.recover()
        }
        notifications.shouldPresent = { [weak self] kind in
            guard let self else { return false }
            return !self.stopped && !self.isWorking && self.issue?.kind == kind
        }
    }

    func bind(model: AppModel, installer: ExtensionInstaller, restartApp: @escaping () -> Void) {
        guard self.model == nil else { return }
        self.model = model
        self.installer = installer
        self.restartApp = restartApp
        installer.prepareForActivation = model.prepareForExtensionUpdate
        installer.captureSuspensionChanged = model.setCaptureSuspended
        installer.refreshCamera = model.refreshCameras
        installer.reconnectCamera = model.reconnectVirtualCamera
        installer.cameraRegistrationWillChange = { [weak zoom] in zoom?.cameraWillChange() }
        model.setCaptureSuspended(installer.blocksCapture)

        model.$virtualCameraStatus.receive(on: DispatchQueue.main).sink { [weak installer] status in
            installer?.observeCameraStatus(status)
        }.store(in: &subscriptions)

        let updates: [AnyPublisher<Void, Never>] = [
            installer.$state.map { _ in () }.eraseToAnyPublisher(),
            installer.$statusCheckError.map { _ in () }.eraseToAnyPublisher(),
            model.$virtualCameraStatus.map { _ in () }.eraseToAnyPublisher(),
            model.$cameraFailure.map { _ in () }.eraseToAnyPublisher(),
            model.$cameraDenied.map { _ in () }.eraseToAnyPublisher(),
            model.$isBusy.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedCameraID.map { _ in () }.eraseToAnyPublisher(),
            model.$cameras.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(updates).receive(on: DispatchQueue.main).sink { [weak self] in
            self?.refresh()
        }.store(in: &subscriptions)
        zoom.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: event).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.model?.refreshCameras()
                if self.installer?.offersStatusCheck == true { self.installer?.refresh() }
                if self.notificationsAvailable == false, let issue = self.issue {
                    // Check again after a visit to macOS notification settings.
                    self.policy.retryUnsent(issue.kind)
                    self.refresh()
                }
            }.store(in: &subscriptions)
        // Approval can change while another app, such as Zoom, stays in front.
        Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.recheckPendingApproval()
            self?.refresh()
        }.store(in: &subscriptions)
        installer.checkForUpgrade()
        refresh()
    }

    private func recheckPendingApproval() {
        guard !stopped, let installer, installer.offersStatusCheck, !installer.isCheckingStatus else { return }
        installer.refresh()
    }

    func showSettings() {
        if let onShowSettings { onShowSettings() }
        else { pendingShowSettings = true }
    }

    var canRecover: Bool {
        guard let issue, let model, let installer else { return false }
        switch issue.recovery {
        case .installExtension, .retryExtension, .repairExtension: return !installer.busy
        case .requestCameraAccess, .retryCapture, .restartApp: return !model.isBusy
        case .restartZoom: return !zoom.isRestarting
        default: return true
        }
    }

    func recover() {
        guard canRecover, let issue, let model, let installer else { return }
        switch issue.recovery {
        case .extensionSettings: installer.openSettings()
        case .installExtension: installer.install()
        case .repairExtension: installer.repairRegistration()
        case .retryExtension:
            if installer.state == .unavailable { installer.retryConnection() }
            else { installer.refresh() }
        case .restartApp: restartApp?()
        case .requestCameraAccess: model.performCameraAction()
        case .cameraSettings: model.openCameraSettings()
        case .retryCapture: showSettings(); model.retryCamera()
        case .restartZoom: zoom.restartZoomForUser()
        case .showSettings: showSettings()
        }
    }

    func prepareForTermination() {
        stopped = true
        installer?.stopRecovery()
        zoom.stop()
        deliveryTask?.cancel()
    }

    private func refresh() {
        guard !stopped, let model, let installer else { return }
        if installer.state == .removed { zoom.cameraRemoved() }
        zoom.refresh(cameraReady: installer.isReady && model.virtualCameraStatus.isUsable)
        let snapshot = CameraAttentionSnapshot(extensionState: installer.state, extensionMessage: installer.message,
            extensionRecovery: installer.recoveryAction, outputStatus: model.virtualCameraStatus,
            cameraPermission: model.cameraControls.permission, hasCamera: !model.selectedCameraID.isEmpty,
            captureFailure: model.cameraFailure, isBusy: model.isBusy)
        let previous = issue
        isWorking = installer.showsProgress || installer.state == .unchecked || model.isBusy || zoom.isLoading || zoom.isRestarting
        let clientIssue = installer.isReady && model.virtualCameraStatus.isUsable ? zoom.issue : nil
        let healthy = snapshot.isHealthy && clientIssue == nil && !zoom.isLoading
        var nextIssue = snapshot.issue ?? clientIssue
        if nextIssue == nil, let previous, !healthy, isWorking {
            nextIssue = CameraAttentionIssue(kind: previous.kind, title: "Camera recovery in progress",
                message: installer.state.connectionSummary ?? "Updating the physical camera…", recovery: .showSettings)
        }
        if issue != nextIssue { issue = nextIssue }
        if healthy || installer.state == .removed {
            let hadDelivered = !policy.delivered.isEmpty
            policy.recovered()
            if hadDelivered { persistDelivered() }
            if previous != nil || deliveryTask != nil {
                deliveryTask?.cancel()
                notifications.clear()
            }
        }
        guard deliveryTask == nil,
              let next = policy.next(issue: issue, isWorking: isWorking) else { return }
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil; self.refresh() }
            let authorized = await self.notifications.authorize()
            self.notificationsAvailable = authorized
            guard authorized else { return }
            guard !Task.isCancelled, !self.stopped, !self.isWorking,
                  self.issue?.kind == next.kind else {
                self.policy.retryUnsent(next.kind)
                return
            }
            do {
                try await self.notifications.deliver(self.issue ?? next)
                guard !Task.isCancelled, !self.stopped, !self.isWorking,
                      self.issue?.kind == next.kind else {
                    self.notifications.clear()
                    self.policy.retryUnsent(next.kind)
                    return
                }
                self.policy.didDeliver(next.kind)
                self.persistDelivered()
            } catch {
                self.notificationsAvailable = false
            }
        }
    }

    func acknowledgeZoomCamera() { zoom.acknowledge() }

    private func persistDelivered() {
        defaults.set(policy.delivered.map(\.rawValue).sorted(), forKey: Self.deliveredKey)
    }
}
