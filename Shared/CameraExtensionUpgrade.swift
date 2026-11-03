import Foundation

struct CameraExtensionVersion: Equatable, Comparable {
    let release: String
    let build: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        let order = lhs.release.compare(rhs.release, options: .numeric)
        return order == .orderedAscending ||
            (order == .orderedSame && lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending)
    }
}

struct InstalledCameraExtension {
    let version: CameraExtensionVersion
    let isEnabled: Bool
    let isAwaitingApproval: Bool
    let isUninstalling: Bool
}

enum CameraExtensionUpgradeAction: Equatable {
    case installUpdate, verify, notInstalled, enableInSettings, approveInSettings, restartMac

    static func decide(bundled: CameraExtensionVersion, installed: [InstalledCameraExtension]) -> Self {
        let active = installed.filter { !$0.isUninstalling }
        guard !active.isEmpty else { return installed.isEmpty ? .notInstalled : .restartMac }
        if active.contains(where: { $0.isAwaitingApproval }) { return .approveInSettings }
        guard let enabled = active.filter(\.isEnabled).max(by: { $0.version < $1.version }) else {
            return .enableInSettings
        }
        return enabled.version < bundled ? .installUpdate : .verify
    }
}

enum CameraExtensionUpdateState: Equatable {
    case unchecked, checking, notInstalled, installing, awaitingApproval, disabled
    case verifying, ready, restartRequired, unavailable, removing, removed
    case failed(String)

    var busy: Bool {
        switch self {
        case .checking, .installing, .verifying, .removing: return true
        default: return false
        }
    }

    var message: String {
        switch self {
        case .unchecked, .notInstalled: return "Install the virtual camera to use MovemberCam in video apps."
        case .checking: return "Checking the installed camera extension…"
        case .installing: return "Updating the virtual camera…"
        case .awaitingApproval: return "Approve MovemberCam in System Settings → General → Login Items & Extensions."
        case .disabled: return "MovemberCam is disabled. Enable it in System Settings → General → Login Items & Extensions."
        case .verifying: return "Connecting the updated camera…"
        case .ready: return "Virtual camera ready."
        case .restartRequired: return "Restart your Mac to finish changing the camera extension."
        case .unavailable: return "Restart MovemberCam to finish connecting the updated camera."
        case .removing: return "Removing the virtual camera…"
        case .removed: return "Virtual camera removed."
        case .failed(let message): return message
        }
    }
}


enum CameraExtensionRecoveryAction: Equatable {
    case none, install, retry, restartApp, openSettings

    var title: String? {
        switch self {
        case .none: return nil
        case .install: return "Install Virtual Camera"
        case .retry: return "Retry Update"
        case .restartApp: return "Restart MovemberCam"
        case .openSettings: return "Open System Settings"
        }
    }
}

extension CameraExtensionUpdateState {
    func recoveryAction(afterAppRestart: Bool) -> CameraExtensionRecoveryAction {
        switch self {
        case .unchecked, .notInstalled, .removed: return .install
        case .awaitingApproval, .disabled: return .openSettings
        case .failed: return .retry
        case .unavailable: return afterAppRestart ? .openSettings : .restartApp
        default: return .none
        }
    }
}
