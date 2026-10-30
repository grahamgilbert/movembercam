import Foundation

struct CameraControlState {
    enum Permission: Equatable { case allowed, notRequested, blocked }
    enum Action: Equatable { case start, stop, requestAccess, openSettings }
    var permission: Permission
    var isRunning: Bool
    var isBusy: Bool
    var hasCamera: Bool

    var action: Action {
        if isRunning { return .stop }
        switch permission {
        case .allowed: return .start
        case .notRequested: return .requestAccess
        case .blocked: return .openSettings
        }
    }

    var isEnabled: Bool { !isBusy && (isRunning || permission != .allowed || hasCamera) }
    var title: String {
        if isBusy { return "Please Wait…" }
        switch action {
        case .start: return "Start Camera"
        case .stop: return "Stop Camera"
        case .requestAccess: return "Allow Camera Access…"
        case .openSettings: return "Open Camera Settings…"
        }
    }
}
