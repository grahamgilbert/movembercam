import AppKit
import SystemExtensions

@MainActor final class FakeCameraNotifications: CameraIssueNotifying {
    var onOpenSettings: (() -> Void)?
    var shouldPresent: ((CameraAttentionIssue.Kind) -> Bool)?
    var authorized = true
    var holdAuthorization = false
    var authorization: CheckedContinuation<Bool, Never>?
    var authorizationCalls = 0
    var delivered: [CameraAttentionIssue] = []
    var clears = 0
    var failDelivery = false
    func authorize() async -> Bool {
        authorizationCalls += 1
        if holdAuthorization { return await withCheckedContinuation { authorization = $0 } }
        return authorized
    }
    func deliver(_ issue: CameraAttentionIssue) async throws {
        if failDelivery { throw VideoError.message("Controlled notification failure") }
        delivered.append(issue)
    }
    func clear() { clears += 1 }
}

@main @MainActor enum CameraAttentionChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VideoError.message("FAIL: \(message)") }
        checks += 1
        print("PASS: \(message)")
    }
    static func settle() async {
        // Combine delivers on the main run loop independently of actor tasks.
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    @MainActor final class Harness {
        let suite = "MovemberCam.attention-checks.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: AppModel
        let engine: CameraEngine
        let notifications = FakeCameraNotifications()
        let attention: CameraAttentionController
        var requests: [OSSystemExtensionRequest] = []
        lazy var installer = ExtensionInstaller(bundledVersion: CameraExtensionVersion(release: "1.0.4", build: "16"),
            canInstall: true, submit: { [unowned self] in self.requests.append($0) }, schedule: { _ in },
            recoveryDefaults: defaults)
        init(previouslySuppressedAlert: Bool = false) {
            defaults = UserDefaults(suiteName: suite)!
            if previouslySuppressedAlert {
                defaults.set(["extensionPermission"], forKey: "MovemberCam.deliveredCameraIssues")
            }
            model = AppModel(defaults: defaults, cameraAuthorization: { .authorized })
            engine = CameraEngine.latest!
            attention = CameraAttentionController(notifications: notifications, defaults: defaults)
        }
        func bind() { attention.bind(model: model, installer: installer, restartApp: {}) }
        func approve(_ enabled: Bool) {
            let installed = InstalledCameraExtension(version: CameraExtensionVersion(release: "1.0.4", build: "16"),
                isEnabled: enabled, isAwaitingApproval: !enabled, isUninstalling: false)
            installer.receiveInstalled([installed], for: requests.last!)
        }
        func ready() async {
            installer.refresh()
            approve(true)
            engine.onOutputStatus?(.idle(isInstalled: true))
            await CameraAttentionChecks.settle()
        }
        func close() {
            attention.prepareForTermination()
            model.shutdown {}
            defaults.removePersistentDomain(forName: suite)
        }
    }

    static func run() async throws {
        let h = Harness(previouslySuppressedAlert: true)
        defer { h.close() }
        h.model.setPreviewVisible(true)
        await settle()
        h.engine.finishStart()
        await settle()
        h.bind()
        h.approve(false)
        await settle()
        let notificationContent = CameraIssueNotifications.content(for: h.attention.issue!)
        try check(notificationContent.title == "Camera needs approval" && notificationContent.body == "Open MovemberCam to enable it.",
                  "Native notifications use concise copy while Settings retains the detailed recovery steps")
        try check(h.model.isRunning && h.attention.issue?.kind == .extensionPermission && h.notifications.delivered.count == 1,
                  "Approval sends a notification even while the Settings preview is running")
        try check(h.notifications.delivered.count == 1,
                  "A suppressed 1.0.4 banner does not prevent the corrected alert after upgrading")
        h.model.setPreviewVisible(false)
        await settle()
        try check(h.notifications.delivered.count == 1, "Closing Settings does not repeat an existing alert")
        try check(h.notifications.shouldPresent?(.extensionPermission) == true,
                  "Background issue remains eligible for a notification banner")
        for _ in 0..<3 { h.installer.refresh(); h.approve(false); h.model.refreshCameras() }
        await settle()
        try check(h.notifications.delivered.count == 1, "Repeated status updates do not spam notifications")
        let relaunched = CameraAttentionController(notifications: FakeCameraNotifications(), defaults: h.defaults)
        try check(h.defaults.stringArray(forKey: "MovemberCam.deliveredCameraIssues.v2") == ["extensionPermission"],
                  "Delivered warning is persisted across app restarts")
        relaunched.prepareForTermination()
        var opened = 0
        h.notifications.onOpenSettings?()
        h.attention.onShowSettings = { opened += 1 }
        try check(opened == 1, "A notification tap before window setup opens Settings once setup completes")
        try check(h.notifications.shouldPresent?(.extensionPermission) == true,
                  "Opening Settings from a notification does not suppress its banner")
        h.installer.refresh(); h.approve(true)
        await settle()
        try check(h.attention.issue?.title == "Camera recovery in progress",
                  "Warning stays visible with truthful progress until the virtual camera connects")
        try check(h.engine.reconnects == 1, "Approval automatically resets the local output connection without restarting capture")
        h.engine.onOutputStatus?(.idle(isInstalled: true))
        await settle()
        try check(h.installer.isReady && h.attention.issue == nil && h.notifications.clears > 0,
                  "Verified camera recovery clears the warning and its notification")
        try check(h.defaults.stringArray(forKey: "MovemberCam.deliveredCameraIssues.v2") == [],
                  "Recovery allows a future incident to notify again")
        h.installer.inspect([InstalledCameraExtension(version: CameraExtensionVersion(release: "1.0.4", build: "16"),
            isEnabled: false, isAwaitingApproval: true, isUninstalling: false)])
        await settle()
        try check(h.notifications.delivered.count == 2, "A new incident with Settings closed sends a background warning after recovery")

        let beforeRecheck = h.requests.count
        try? await Task.sleep(nanoseconds: 5_100_000_000)
        try check(h.requests.count > beforeRecheck && h.installer.isCheckingStatus,
                  "Approval is rechecked in the background without opening Settings or refocusing the app")
        h.approve(false)
        await settle()
        try check(h.notifications.delivered.count == 2,
                  "Background approval checks preserve the incident notification limit")

        let denied = Harness()
        defer { denied.close() }
        denied.notifications.authorized = false
        denied.bind(); denied.approve(false)
        await settle(); denied.model.refreshCameras(); await settle()
        try check(denied.attention.issue != nil && denied.attention.notificationsAvailable == false &&
                  denied.notifications.authorizationCalls == 1 && denied.notifications.delivered.isEmpty,
                  "Denied notifications keep the visible warning without a permission retry loop")

        denied.notifications.authorized = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        try check(denied.notifications.delivered.count == 1,
                  "Enabling alerts after denial notifies for the unresolved issue on returning to the app")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        try check(denied.notifications.delivered.count == 1,
                  "Refocusing the app does not repeat the newly permitted alert")

        let race = Harness()
        defer { race.close() }
        race.notifications.holdAuthorization = true
        race.bind(); race.approve(false)
        await settle()
        await race.ready()
        race.notifications.authorization?.resume(returning: true)
        await settle()
        try check(race.attention.issue == nil && race.notifications.delivered.isEmpty,
                  "Recovery during notification authorization never sends a stale warning")

        let failure = Harness()
        defer { failure.close() }
        failure.notifications.failDelivery = true
        failure.bind(); failure.approve(false)
        await settle(); failure.model.refreshCameras(); await settle()
        try check(failure.notifications.authorizationCalls == 1 && failure.attention.issue != nil,
                  "Notification delivery failure leaves recovery visible without retrying endlessly")
    }
    static func main() async {
        do { try await run(); print("\(checks) camera attention checks passed") }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
