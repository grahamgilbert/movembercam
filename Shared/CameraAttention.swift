import Foundation

struct CameraAttentionIssue: Equatable {
    enum Kind: String, Hashable {
        case extensionPermission, missingExtension, extensionFailure, restartRequired
        case cameraPermission, missingCamera, captureFailure, videoAppRestart
    }
    enum Recovery: Equatable {
        case extensionSettings, installExtension, retryExtension, repairExtension, restartApp
        case requestCameraAccess, cameraSettings, retryCapture, restartZoom, showSettings

        var title: String {
            switch self {
            case .extensionSettings: return "Open Camera Extension Settings…"
            case .installExtension: return "Install Virtual Camera"
            case .retryExtension: return "Retry Camera Connection"
            case .repairExtension: return "Repair Virtual Camera"
            case .restartApp: return "Restart MovemberCam"
            case .requestCameraAccess: return "Allow Camera Access…"
            case .cameraSettings: return "Open Camera Privacy Settings…"
            case .retryCapture: return "Retry Physical Camera"
            case .restartZoom: return "Restart Zoom"
            case .showSettings: return "Open MovemberCam Settings…"
            }
        }
    }

    var notificationCopy: (title: String, body: String) {
        switch kind {
        case .extensionPermission: return ("Camera needs approval", "Open MovemberCam to enable it.")
        case .missingExtension: return ("Set up your virtual camera", "Open MovemberCam to finish setup.")
        case .extensionFailure: return ("Camera connection failed", "Open MovemberCam to reconnect.")
        case .restartRequired: return ("Restart your Mac", "Restart to finish camera setup.")
        case .cameraPermission: return ("Allow camera access", "Open MovemberCam to allow access.")
        case .missingCamera: return ("No camera connected", "Connect a camera, then open MovemberCam.")
        case .captureFailure: return ("Camera stopped", "Open MovemberCam to reconnect.")
        case .videoAppRestart: return ("Restart Zoom for MovemberCam", "Finish any call, then restart Zoom.")
        }
    }

    let kind: Kind
    let title: String
    let message: String
    let recovery: Recovery
}

struct CameraAttentionSnapshot {
    var extensionState: CameraExtensionUpdateState
    var extensionMessage: String? = nil
    var extensionRecovery: CameraExtensionRecoveryAction = .none
    var outputStatus = VirtualCameraStatus.idle(isInstalled: true)
    var cameraPermission = CameraControlState.Permission.allowed
    var hasCamera = true
    var captureFailure: String? = nil
    var isBusy = false

    var isHealthy: Bool {
        extensionState == .ready && outputStatus.isUsable && cameraPermission == .allowed &&
            hasCamera && captureFailure == nil && !isBusy
    }

    var issue: CameraAttentionIssue? {
        let message = extensionMessage ?? extensionState.message
        switch extensionState {
        case .removed: return nil
        case .awaitingApproval, .disabled:
            return CameraAttentionIssue(kind: .extensionPermission,
                title: extensionState == .disabled ? "Virtual camera is disabled" : "Camera extension approval needed",
                message: message, recovery: .extensionSettings)
        case .notInstalled:
            return CameraAttentionIssue(kind: .missingExtension, title: "Virtual camera is not installed",
                message: "Zoom and other video apps cannot use MovemberCam until its virtual camera is installed.",
                recovery: .installExtension)
        case .failed:
            return CameraAttentionIssue(kind: .extensionFailure, title: "Virtual camera setup failed",
                message: message, recovery: .retryExtension)
        case .unavailable:
            return CameraAttentionIssue(kind: .extensionFailure, title: "Virtual camera is unavailable",
                message: message, recovery: extensionRecovery == .openSettings ? .extensionSettings :
                    extensionRecovery == .repairRegistration ? .repairExtension :
                    extensionRecovery == .reconnect ? .retryExtension : .restartApp)
        case .restartRequired:
            return CameraAttentionIssue(kind: .restartRequired, title: "Camera extension needs a Mac restart",
                message: message, recovery: .showSettings)
        default: break
        }
        switch cameraPermission {
        case .blocked:
            return CameraAttentionIssue(kind: .cameraPermission, title: "Physical camera access is off",
                message: "Allow MovemberCam in System Settings → Privacy & Security → Camera to use your physical camera.",
                recovery: .cameraSettings)
        case .notRequested:
            return CameraAttentionIssue(kind: .cameraPermission, title: "Physical camera access is needed",
                message: "Allow camera access in MovemberCam so it can provide video to your calls.", recovery: .requestCameraAccess)
        case .allowed: break
        }
        if !hasCamera {
            return CameraAttentionIssue(kind: .missingCamera, title: "No physical camera is connected",
                message: "Connect or choose a physical camera in MovemberCam Settings.", recovery: .showSettings)
        }
        if let captureFailure {
            return CameraAttentionIssue(kind: .captureFailure, title: "Physical camera stopped",
                message: captureFailure, recovery: .retryCapture)
        }
        if extensionState == .ready && !outputStatus.isUsable {
            return CameraAttentionIssue(kind: .extensionFailure, title: "Virtual camera cannot send video",
                message: "MovemberCam is not delivering video to other apps. Retry the camera connection in Settings.",
                recovery: .retryExtension)
        }
        return nil
    }
}

/// Remember delivered issue kinds until recovery, including across app restarts.
/// Transient checking states must not cause the same warning to be posted again.
struct CameraAttentionNotificationPolicy {
    private(set) var delivered: Set<CameraAttentionIssue.Kind>
    private var attempted: Set<CameraAttentionIssue.Kind> = []

    init(delivered: Set<CameraAttentionIssue.Kind> = []) { self.delivered = delivered }

    mutating func next(issue: CameraAttentionIssue?, isWorking: Bool) -> CameraAttentionIssue? {
        guard let issue, !isWorking,
              !delivered.contains(issue.kind), !attempted.contains(issue.kind) else { return nil }
        attempted.insert(issue.kind)
        return issue
    }

    mutating func didDeliver(_ kind: CameraAttentionIssue.Kind) { delivered.insert(kind) }
    mutating func retryUnsent(_ kind: CameraAttentionIssue.Kind) { attempted.remove(kind) }
    mutating func recovered() { delivered.removeAll(); attempted.removeAll() }
}
