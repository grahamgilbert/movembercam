import AppKit
import ServiceManagement
import SystemExtensions
import os

/// Activation and camera discovery are separate events. Verify both before
/// reporting success; an installed extension can still be unavailable to clients.
final class ExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    private static let logger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "ExtensionInstaller")
    private var lastInstalledSnapshot: String?
    @Published private(set) var state = CameraExtensionUpdateState.unchecked {
        didSet {
            if oldValue != state {
                Self.logger.notice("Installer state \(oldValue.diagnosticName, privacy: .public) -> \(self.state.diagnosticName, privacy: .public) recoveryAttempt=\(self.recoveryAttempts, privacy: .public)")
            }
            let wasBlocking = oldValue == .installing || oldValue == .removing
            if blocksCapture != wasBlocking { captureSuspensionChanged(blocksCapture) }
        }
    }
    @Published private(set) var isCheckingStatus = false
    @Published private(set) var statusCheckError: String?
    var message: String {
        let message: String
        if state == .unavailable && changeRequest != nil {
            message = "MovemberCam Camera is enabled, but macOS hasn’t finished activation. Restart MovemberCam to reconnect."
        } else if state == .unavailable && didRestartForRecovery {
            message = "The camera is still unavailable. " + CameraExtensionSettings.instructions() +
                " If it is already enabled, restart your Mac to finish connecting it."
        } else { message = state.message }
        return statusCheckError.map { message + " Couldn’t recheck macOS status: " + $0 } ?? message
    }
    var recoveryAction: CameraExtensionRecoveryAction {
        if state == .unavailable && changeRequest != nil { return .restartApp }
        return state.recoveryAction(afterAppRestart: didRestartForRecovery)
    }
    var offersAppRestart: Bool { state == .unavailable && !didRestartForRecovery && changeRequest == nil }
    var recoveryEnabled: Bool {
        recoveryAction != .none && (!busy || recoveryAction == .openSettings ||
            (state == .unavailable && recoveryAction == .restartApp))
    }
    var showsProgress: Bool { state.busy }
    var offersStatusCheck: Bool {
        [.awaitingApproval, .awaitingActivation, .disabled, .unavailable].contains(state)
    }
    private static let restartKey = "MovemberCam.extensionRecoveryRestart"
    private var recoveryVersion: String? { bundledVersion.map { "\($0.release)(\($0.build))" } }
    private var didRestartForRecovery: Bool {
        guard let recoveryVersion else { return false }
        return recoveryDefaults.string(forKey: Self.restartKey) == recoveryVersion
    }
    func noteAppRestart() {
        if let recoveryVersion { recoveryDefaults.set(recoveryVersion, forKey: Self.restartKey) }
    }
    var busy: Bool { state.busy || state == .awaitingApproval || changeRequest != nil || propertiesRequest != nil }
    var isReady: Bool { state == .ready }
    var blocksCapture: Bool { state == .installing || state == .removing }
    var needsApproval: Bool { state == .awaitingApproval || state == .disabled }
    var prepareForActivation: (@escaping () -> Void) -> Void = { $0() }
    var captureSuspensionChanged: (Bool) -> Void = { _ in }
    var refreshCamera: () -> Void = {}
    var reconnectCamera: () -> Void = {}

    private let bundledVersion: CameraExtensionVersion?
    private let recoveryDefaults: UserDefaults
    private let canInstall: Bool
    private let submit: (OSSystemExtensionRequest) -> Void
    private let schedule: (@escaping () -> Void) -> Void
    private var checked = false
    private var propertiesRequest: OSSystemExtensionRequest?
    private enum PropertiesPurpose {
        case discovery
        case recovery(CameraExtensionUpdateState)
        case approval(OSSystemExtensionRequest)
    }
    private var propertiesPurpose: PropertiesPurpose?
    private var changeRequest: OSSystemExtensionRequest?
    private var removing = false
    private var verificationID = UUID()
    private var recoveryAttempts = 0
    private var lastCameraStatus = VirtualCameraStatus.idle(isInstalled: false)

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
        let version = bundledVersion.map { "\($0.release)(\($0.build))" } ?? "missing"
        Self.logger.notice("Installer initialized version=\(version, privacy: .public) canInstall=\(canInstall, privacy: .public)")
    }

    func checkForUpgrade() {
        guard !checked, canInstall else { return }
        checked = true
        refresh()
    }

    func refresh() {
        guard canInstall, propertiesRequest == nil else { return }
        if let changeRequest {
            // Querying macOS is safe while activation waits for the user. Keep the
            // activation request alive and never submit a duplicate change request.
            guard offersStatusCheck else { return }
            propertiesPurpose = .approval(changeRequest)
        } else {
            guard !state.busy else { return }
            if !offersStatusCheck { recoveryAttempts = 0 }
            if offersStatusCheck { propertiesPurpose = .recovery(state) }
            else {
                state = .checking
                propertiesPurpose = .discovery
            }
        }
        statusCheckError = nil
        isCheckingStatus = true
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: VideoFormat.extensionIdentifier, queue: .main)
        propertiesRequest = request
        request.delegate = self
        Self.logger.debug("Status query submitted request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
        submit(request)
        waitForStatus(request, remaining: 20)
    }

    private func waitForStatus(_ request: OSSystemExtensionRequest, remaining: Int) {
        schedule { [weak self, weak request] in
            guard let self, let request, self.propertiesRequest === request else { return }
            if remaining > 1 { self.waitForStatus(request, remaining: remaining - 1) }
            else {
                Self.logger.error("Status query timed out request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
                self.request(request, didFailWithError: VideoError.message(
                    "macOS did not respond to the camera status check. Try again or restart MovemberCam."))
            }
        }
    }

    func retryConnection() {
        guard canInstall, !busy, state == .unavailable else { return }
        recoveryAttempts = 0
        Self.logger.notice("User requested connection recovery")
        if !lastCameraStatus.isInstalled || lastCameraStatus == .requiresUpdate { activate() }
        else { verify(resetConnection: true) }
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
        statusCheckError = nil
        state = .installing
        prepareForActivation { [weak self] in
            guard let self, self.state == .installing else { return }
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: VideoFormat.extensionIdentifier, queue: .main)
            self.changeRequest = request
            self.removing = false
            request.delegate = self
            Self.logger.notice("Activation submitted request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
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
        Self.logger.notice("Removal submitted request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
        submit(request)
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        receiveInstalled(properties.map {
            InstalledCameraExtension(version: CameraExtensionVersion(release: $0.bundleShortVersion, build: $0.bundleVersion),
                isEnabled: $0.isEnabled, isAwaitingApproval: $0.isAwaitingUserApproval, isUninstalling: $0.isUninstalling)
        }, for: request)
    }

    func receiveInstalled(_ installed: [InstalledCameraExtension], for request: OSSystemExtensionRequest) {
        guard request === propertiesRequest else {
            Self.logger.debug("Ignored stale status response request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
            return
        }
        let snapshot = installed.map { "\($0.version.release)(\($0.version.build)) enabled=\($0.isEnabled) approval=\($0.isAwaitingApproval) uninstalling=\($0.isUninstalling)" }.joined(separator: "; ")
        if snapshot != lastInstalledSnapshot {
            lastInstalledSnapshot = snapshot
            Self.logger.notice("Installed extensions [\(snapshot, privacy: .public)]")
        }
        let purpose = propertiesPurpose
        propertiesRequest = nil
        propertiesPurpose = nil
        isCheckingStatus = false
        switch purpose {
        case .discovery:
            guard changeRequest == nil else { return }
            inspect(installed)
        case .recovery(let previous):
            guard changeRequest == nil, state == previous else { return }
            inspect(installed)
        case .approval(let activation):
            // A query sent before completion/failure must not overwrite its result.
            guard changeRequest === activation else { return }
            inspectPendingApproval(installed)
        case nil: break
        }
    }

    private func inspectPendingApproval(_ installed: [InstalledCameraExtension]) {
        guard let bundledVersion else { return }
        let candidates = installed.filter { !$0.isUninstalling && $0.version >= bundledVersion }
        guard !candidates.isEmpty else { return }
        switch CameraExtensionUpgradeAction.decide(bundled: bundledVersion, installed: candidates) {
        case .approveInSettings:
            verificationID = UUID()
            state = .awaitingApproval
        case .enableInSettings:
            verificationID = UUID()
            state = .disabled
        case .verify:
            guard state != .awaitingActivation && state != .unavailable else { return }
            let id = UUID()
            verificationID = id
            state = .awaitingActivation
            waitForActivation(id: id, remaining: 20)
        default: break
        }
    }

    private func waitForActivation(id: UUID, remaining: Int) {
        schedule { [weak self] in
            guard let self, self.verificationID == id, self.state == .awaitingActivation else { return }
            if remaining > 1 { self.waitForActivation(id: id, remaining: remaining - 1) }
            else {
                Self.logger.error("Activation completion timed out")
                self.state = .unavailable
            }
        }
    }

    func inspect(_ installed: [InstalledCameraExtension]) {
        guard let bundledVersion else { state = .failed("The bundled camera extension is missing."); return }
        switch CameraExtensionUpgradeAction.decide(bundled: bundledVersion, installed: installed) {
        case .installUpdate: activate()
        case .verify:
            if state == .unavailable {
                // Background property queries must not restart an exhausted verification cycle.
                refreshCamera()
            } else {
                verify(resetConnection: state == .awaitingApproval || state == .disabled)
            }
        case .notInstalled: state = .notInstalled
        case .enableInSettings: state = .disabled
        case .approveInSettings: state = .awaitingApproval
        case .restartMac: state = .restartRequired
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request === changeRequest else { return }
        verificationID = UUID()
        statusCheckError = nil
        Self.logger.notice("Activation awaiting user approval request=\(ObjectIdentifier(request).hashValue, privacy: .public)")
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
        Self.logger.notice("Extension change completed removal=\(self.removing, privacy: .public) request=\(ObjectIdentifier(request).hashValue, privacy: .public) result=\(result.rawValue, privacy: .public)")
        changeRequest = nil
        statusCheckError = nil
        if result == .willCompleteAfterReboot { state = .restartRequired }
        else if removing { state = .removed; refreshCamera() }
        else { verify(resetConnection: true) }
    }

    private func verify(resetConnection: Bool = false) {
        state = .verifying
        let id = UUID()
        verificationID = id
        if resetConnection { reconnectCamera() }
        Self.logger.notice("Verifying connection cycle=\(id.uuidString, privacy: .public)")
        poll(id: id, remaining: 20)
    }

    private func poll(id: UUID, remaining: Int) {
        guard verificationID == id, state == .verifying else { return }
        refreshCamera()
        schedule { [weak self] in
            guard let self, self.verificationID == id, self.state == .verifying else { return }
            if remaining > 1 { self.poll(id: id, remaining: remaining - 1) }
            else if self.recoveryAttempts == 0 {
                self.recoveryAttempts += 1
                if !self.lastCameraStatus.isInstalled || self.lastCameraStatus == .requiresUpdate {
                    // macOS can reject the replacement launch while the old job is
                    // still being removed (EALREADY). A sink reset cannot register
                    // a device that does not exist. Retry activation once, keeping
                    // the same recovery budget across its completion callback.
                    Self.logger.warning("No usable device after activation; retrying registration once cycle=\(id.uuidString, privacy: .public)")
                    self.activate()
                } else {
                    Self.logger.warning("Connection verification timed out; retrying local sink connection cycle=\(id.uuidString, privacy: .public)")
                    self.reconnectCamera()
                    self.poll(id: id, remaining: 20)
                }
            } else {
                Self.logger.error("Connection recovery exhausted cycle=\(id.uuidString, privacy: .public)")
                self.state = .unavailable
            }
        }
    }

    func observeCameraStatus(_ status: VirtualCameraStatus) {
        lastCameraStatus = status
        if (state == .verifying || state == .unavailable), changeRequest == nil, status.isUsable {
            verificationID = UUID()
            state = .ready
            if didRestartForRecovery { recoveryDefaults.removeObject(forKey: Self.restartKey) }
        } else if state == .ready, !status.isUsable {
            recoveryAttempts = 0
            // Output is already connecting; resetting on every connecting event
            // would feed another reset back into the status observer.
            verify()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request === changeRequest || request === propertiesRequest else { return }
        let detail = error as NSError
        Self.logger.error("Extension request failed request=\(ObjectIdentifier(request).hashValue, privacy: .public) domain=\(detail.domain, privacy: .public) code=\(detail.code, privacy: .public)")
        if request === propertiesRequest {
            let purpose = propertiesPurpose
            propertiesRequest = nil
            propertiesPurpose = nil
            isCheckingStatus = false
            if case .approval(let activation) = purpose {
                if changeRequest === activation { statusCheckError = error.localizedDescription }
                return
            }
            if case .recovery(let previous) = purpose {
                if changeRequest == nil, state == previous { statusCheckError = error.localizedDescription }
                return
            }
        }
        changeRequest = nil
        propertiesRequest = nil
        propertiesPurpose = nil
        isCheckingStatus = false
        statusCheckError = nil
        verificationID = UUID()
        let failure = error as NSError
        let validation = failure.domain == OSSystemExtensionErrorDomain && [8, 9].contains(failure.code)
        state = .failed("Camera extension update failed: \(error.localizedDescription)" +
            (validation ? " Install a signed, notarized MovemberCam release, then retry." : " Retry, or open System Settings to check MovemberCam’s approval."))
    }

    func openSettings() {
        if #available(macOS 15, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?General")!)
        }
    }
}
