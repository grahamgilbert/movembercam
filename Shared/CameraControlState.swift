import Foundation

struct CameraControlState {
    enum Permission: Equatable { case allowed, notRequested, blocked }
    enum Action: Equatable { case requestAccess, openSettings }
    var permission: Permission
    var isBusy: Bool

    var action: Action? {
        switch permission {
        case .allowed: return nil
        case .notRequested: return .requestAccess
        case .blocked: return .openSettings
        }
    }

    var isEnabled: Bool { !isBusy && action != nil }
    var title: String {
        switch permission {
        case .allowed: return "Camera starts automatically"
        case .notRequested: return "Allow Camera Access…"
        case .blocked: return "Open Camera Settings…"
        }
    }
}

/// A failed session retries on a new consumer session or an explicit source change.
/// Suspending for extension replacement must not discard existing consumer demand.
struct CameraCaptureDemand {
    private(set) var isRequested = false
    private(set) var isPreviewVisible = false
    var isSuspended = false
    var hasFailed = false

    mutating func update(_ requested: Bool) {
        isRequested = requested
        if !requested && !isPreviewVisible { hasFailed = false }
    }

    mutating func showPreview(_ visible: Bool) {
        if visible != isPreviewVisible { hasFailed = false }
        isPreviewVisible = visible
    }

    var shouldCapture: Bool { (isRequested || isPreviewVisible) && !isSuspended && !hasFailed }
}
