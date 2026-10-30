import Foundation

/// Installation and delivery status come from the same CoreMediaIO observation.
enum VirtualCameraStatus: Equatable {
    case idle(isInstalled: Bool)
    case notInstalled
    case sending
    case cannotOpen(Int32)
    case cannotStart(Int32)

    var isInstalled: Bool {
        switch self {
        case .idle(let installed): return installed
        case .notInstalled: return false
        case .sending, .cannotOpen, .cannotStart: return true
        }
    }

    var message: String {
        switch self {
        case .idle: return "Virtual camera idle"
        case .notInstalled: return "Virtual camera not installed"
        case .sending: return "Sending to MovemberCam"
        case .cannotOpen(let result): return "Cannot open virtual camera (\(result))"
        case .cannotStart(-4): return "Virtual camera rejected the connection"
        case .cannotStart(let result): return "Cannot start virtual camera (\(result))"
        }
    }
}
