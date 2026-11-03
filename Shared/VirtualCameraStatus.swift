import Foundation

/// Installation and delivery status come from the same CoreMediaIO observation.
enum VirtualCameraStatus: Equatable {
    case idle(isInstalled: Bool)
    case notInstalled
    case requiresUpdate
    case connecting
    case sending
    case cannotOpen(Int32)
    case cannotStart(Int32)

    var isInstalled: Bool {
        switch self {
        case .idle(let installed): return installed
        case .notInstalled: return false
        case .connecting, .sending, .cannotOpen, .cannotStart, .requiresUpdate: return true
        }
    }

    var message: String {
        switch self {
        case .idle: return "Virtual camera idle"
        case .notInstalled: return "Virtual camera not installed"
        case .requiresUpdate: return "Update the virtual camera to enable automatic capture"
        case .connecting: return "Connecting virtual camera…"
        case .sending: return "Sending to MovemberCam"
        case .cannotOpen(let result): return "Cannot open virtual camera (\(result))"
        case .cannotStart(-4): return "Virtual camera rejected the connection"
        case .cannotStart(let result): return "Cannot start virtual camera (\(result))"
        }
    }

    var errorCode: Int32? {
        switch self {
        case .cannotOpen(let code), .cannotStart(let code): return code
        default: return nil
        }
    }

    var isUsable: Bool {
        switch self {
        case .idle(isInstalled: true), .sending: return true
        default: return false
        }
    }

}

/// A device being discoverable does not prove its sink connection works.
struct VirtualCameraConnectionHealth {
    private(set) var failure: VirtualCameraStatus?
    var expectsFrames = false
    private(set) var hasSentFrame = false

    mutating func failed(_ status: VirtualCameraStatus) { failure = status; hasSentFrame = false }
    mutating func sentFrame() { failure = nil; hasSentFrame = true }
    mutating func reset() { failure = nil; hasSentFrame = false }

    func status(isInstalled: Bool, supportsDemand: Bool) -> VirtualCameraStatus {
        guard isInstalled else { return .notInstalled }
        guard supportsDemand else { return .requiresUpdate }
        if let failure { return failure }
        if hasSentFrame { return .sending }
        return expectsFrames ? .connecting : .idle(isInstalled: true)
    }
}
