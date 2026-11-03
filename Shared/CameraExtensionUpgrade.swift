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
        let enabled = active.filter(\.isEnabled).max(by: { $0.version < $1.version })
        let pending = active.filter(\.isAwaitingApproval).max(by: { $0.version < $1.version })
        if let pending {
            if let enabled {
                if pending.version >= enabled.version { return .approveInSettings }
            } else { return .approveInSettings }
        }
        guard let enabled else {
            return .enableInSettings
        }
        return enabled.version < bundled ? .installUpdate : .verify
    }
}

enum CameraExtensionUpdateState: Equatable {
    case unchecked, checking, notInstalled, installing, awaitingApproval, disabled
    case awaitingActivation, verifying, ready, restartRequired, unavailable, removing, removed
    case failed(String)

    var diagnosticName: String {
        if case .failed = self { return "failed" }
        return String(describing: self)
    }

    var busy: Bool {
        switch self {
        case .checking, .installing, .awaitingActivation, .verifying, .removing: return true
        default: return false
        }
    }

    var connectionSummary: String? {
        switch self {
        case .unchecked, .ready: return nil
        case .notInstalled: return "Virtual camera not installed"
        case .checking: return "Checking camera extension…"
        case .installing: return "Updating virtual camera…"
        case .awaitingApproval: return "Camera extension approval required"
        case .disabled: return "Camera extension disabled"
        case .awaitingActivation: return "Waiting for macOS activation"
        case .verifying: return "Connecting virtual camera…"
        case .restartRequired: return "Mac restart required"
        case .unavailable: return "Virtual camera unavailable"
        case .removing: return "Removing virtual camera…"
        case .removed: return "Virtual camera removed"
        case .failed: return "Camera extension setup failed"
        }
    }

    var message: String {
        switch self {
        case .unchecked, .notInstalled: return "Install the virtual camera to use MovemberCam in video apps."
        case .checking: return "Checking the installed camera extension…"
        case .installing: return "Updating the virtual camera…"
        case .awaitingApproval: return "macOS is waiting for approval of MovemberCam Camera. " + CameraExtensionSettings.instructions()
        case .disabled: return "macOS reports MovemberCam Camera is disabled. " + CameraExtensionSettings.instructions()
        case .awaitingActivation: return "MovemberCam Camera is enabled. Waiting for macOS to finish activation…"
        case .verifying: return "Connecting the updated camera…"
        case .ready: return "Virtual camera ready."
        case .restartRequired: return "Restart your Mac to finish changing the camera extension."
        case .unavailable: return "The virtual camera is unavailable. Retry its connection."
        case .removing: return "Removing the virtual camera…"
        case .removed: return "Virtual camera removed."
        case .failed(let message): return message
        }
    }
}

enum CameraExtensionSettings {
    static func instructions(macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        if macOSMajorVersion < 15 {
            return "In System Settings → Privacy & Security, allow MovemberCam’s system extension."
        }
        let category = macOSMajorVersion >= 26 ? " → By Category" : ""
        return "In System Settings → General → Login Items & Extensions\(category) → Camera Extensions, enable MovemberCam Camera."
    }
}


enum CameraExtensionRecoveryAction: Equatable {
    case none, install, retry, reconnect, repairRegistration, restartApp, openSettings

    var title: String? {
        switch self {
        case .none: return nil
        case .install: return "Install Virtual Camera"
        case .retry: return "Retry Update"
        case .reconnect: return "Retry Connection"
        case .repairRegistration: return "Repair Virtual Camera"
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
        case .unavailable: return afterAppRestart ? .openSettings : .reconnect
        default: return .none
        }
    }
}
