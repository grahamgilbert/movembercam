import AppKit
import SystemExtensions

/// Activation and camera discovery are separate events. Verify both before
/// reporting success; an installed extension can still be unavailable to clients.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var state = CameraExtensionUpdateState.unchecked
    var message: String {
        state == .unavailable && didRestartForRecovery
            ? "Enable MovemberCam in System Settings to finish connecting the camera." : state.message
    }
    var recoveryAction: CameraExtensionRecoveryAction { state.recoveryAction(afterAppRestart: didRestartForRecovery) }
    var recoveryEnabled: Bool { recoveryAction != .none && (!busy || recoveryAction == .openSettings) }
    private static let restartKey = "MovemberCam.extensionRecoveryRestart"
    private var recoveryVersion: String? { bundledVersion.map { "\($0.release)(\($0.build))" } }
    private var didRestartForRecovery: Bool {
        guard let recoveryVersion else { return false }
        return recoveryDefaults.string(forKey: Self.restartKey) == recoveryVersion
    }
    func noteAppRestart() {
        if let recoveryVersion { recoveryDefaults.set(recoveryVersion, forKey: Self.restartKey) }
    }
    var busy: Bool { state.busy || changeRequest != nil }
    var isReady: Bool { state == .ready }
    var blocksCapture: Bool { state == .installing || state == .removing }
    var needsApproval: Bool { state == .awaitingApproval || state == .disabled || state == .unavailable }
    var prepareForActivation: (@escaping () -> Void) -> Void = { $0() }
    var refreshCamera: () -> Void = {}

    private let bundledVersion: CameraExtensionVersion?
    private let recoveryDefaults: UserDefaults
    private let canInstall: Bool
    private let submit: (OSSystemExtensionRequest) -> Void
    private let schedule: (@escaping () -> Void) -> Void
    private var checked = false
    private var propertiesRequest: OSSystemExtensionRequest?
    private var changeRequest: OSSystemExtensionRequest?
    private var removing = false
    private var verificationID = UUID()
    private var recoveryAttempts = 0

    override convenience init() {
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(VideoFormat.extensionIdentifier).systemextension")
        let info = Bundle(url: url)?.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { release in
            (info?["CFBundleVersion"] as? String).map { CameraExtensionVersion(release: release, build: $0) }
        }
        self.init(bundledVersion: version,
                  canInstall: Bundle.main.object(forInfoDictionaryKey: "MovemberCamPreviewBuild") as? String != "YES" &&
                    Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications",
                  submit: { OSSystemExtensionManager.shared.submitRequest($0) },
                  schedule: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: $0) })
    }

    init(bundledVersion: CameraExtensionVersion?, canInstall: Bool,
         submit: @escaping (OSSystemExtensionRequest) -> Void,
         schedule: @escaping (@escaping () -> Void) -> Void, recoveryDefaults: UserDefaults = .standard) {
        self.bundledVersion = bundledVersion
        self.canInstall = canInstall
        self.recoveryDefaults = recoveryDefaults
        self.submit = submit
        self.schedule = schedule
        super.init()
    }

    func checkForUpgrade() {
        guard !checked, canInstall else { return }
        checked = true
        refresh()
    }

    func refresh() {
        guard !busy, canInstall else { return }
        recoveryAttempts = 0
        state = .checking
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: VideoFormat.extensionIdentifier, queue: .main)
        propertiesRequest = request
        request.delegate = self
        submit(request)
    }

    func install() {
        guard !busy else { return }
        guard canInstall, bundledVersion != nil else {
            state = .failed("Run a signed MovemberCam build from Applications to install its virtual camera.")
            return
        }
        recoveryAttempts = 0
        activate()
    }

    private func activate() {
        verificationID = UUID()
        state = .installing
        prepareForActivation { [weak self] in
            guard let self, self.state == .installing else { return }
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: VideoFormat.extensionIdentifier, queue: .main)
            self.changeRequest = request
            self.removing = false
            request.delegate = self
            self.submit(request)
        }
    }

    func uninstall() {
        guard !busy, canInstall else { return }
        verificationID = UUID()
        state = .removing
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: VideoFormat.extensionIdentifier, queue: .main)
        changeRequest = request
        removing = true
        request.delegate = self
        submit(request)
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        guard request === propertiesRequest else { return }
        propertiesRequest = nil
        inspect(properties.map {
            InstalledCameraExtension(version: CameraExtensionVersion(release: $0.bundleShortVersion, build: $0.bundleVersion),
                isEnabled: $0.isEnabled, isAwaitingApproval: $0.isAwaitingUserApproval, isUninstalling: $0.isUninstalling)
        })
    }

    func inspect(_ installed: [InstalledCameraExtension]) {
        guard let bundledVersion else { state = .failed("The bundled camera extension is missing."); return }
        switch CameraExtensionUpgradeAction.decide(bundled: bundledVersion, installed: installed) {
        case .installUpdate: activate()
        case .verify: verify()
        case .notInstalled: state = .notInstalled
        case .enableInSettings: state = .disabled
        case .approveInSettings: state = .awaitingApproval
        case .restartMac: state = .restartRequired
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === changeRequest else { return }
        state = .awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        let old = CameraExtensionVersion(release: existing.bundleShortVersion, build: existing.bundleVersion)
        let new = CameraExtensionVersion(release: ext.bundleShortVersion, build: ext.bundleVersion)
        return new < old ? .cancel : .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard request === changeRequest else { return }
        changeRequest = nil
        if result == .willCompleteAfterReboot { state = .restartRequired }
        else if removing { state = .removed; refreshCamera() }
        else { verify() }
    }

    private func verify() {
        state = .verifying
        let id = UUID()
        verificationID = id
        poll(id: id, remaining: 20)
    }

    private func poll(id: UUID, remaining: Int) {
        guard verificationID == id, state == .verifying else { return }
        refreshCamera()
        schedule { [weak self] in
            guard let self, self.verificationID == id, self.state == .verifying else { return }
            if remaining > 1 { self.poll(id: id, remaining: remaining - 1) }
            else if self.recoveryAttempts == 0 {
                // Retry once after the previous extension's launchd job has exited.
                self.recoveryAttempts += 1
                self.activate()
            } else { self.state = .unavailable }
        }
    }

    func observeCameraStatus(_ status: VirtualCameraStatus) {
        if (state == .verifying || state == .unavailable), status.isUsable {
            verificationID = UUID()
            state = .ready
            if didRestartForRecovery { recoveryDefaults.removeObject(forKey: Self.restartKey) }
        } else if state == .ready, !status.isUsable {
            verify()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === changeRequest || request === propertiesRequest else { return }
        changeRequest = nil
        propertiesRequest = nil
        verificationID = UUID()
        let failure = error as NSError
        let validation = failure.domain == OSSystemExtensionErrorDomain && [8, 9].contains(failure.code)
        state = .failed("Camera extension update failed: \(error.localizedDescription)" +
            (validation ? " Install a signed, notarized MovemberCam release, then retry." : " Retry, or open System Settings to check MovemberCam’s approval."))
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }
}
