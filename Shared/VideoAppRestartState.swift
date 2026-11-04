import Foundation

struct VideoAppProcess: Codable, Equatable {
    let pid: Int32
    let launchedAt: Date
}

/// A camera being available does not refresh an existing video app's device list.
struct VideoAppRestartState: Codable, Equatable {
    private(set) var cameraAvailableAt: Date?
    private(set) var pending: VideoAppProcess?
    private(set) var awaitingCamera = false
    private(set) var acknowledgedAt: Date?

    mutating func cameraWillChange() { awaitingCamera = true }

    mutating func cameraBecameAvailable(at date: Date, running: VideoAppProcess?) {
        guard awaitingCamera || cameraAvailableAt == nil || date > cameraAvailableAt! else {
            reconcile(running: running)
            return
        }
        awaitingCamera = false
        cameraAvailableAt = date
        acknowledgedAt = nil
        pending = running.flatMap { $0.launchedAt <= date ? $0 : nil }
    }

    mutating func reconcile(running: VideoAppProcess?) {
        if pending != nil && pending != running { pending = nil }
    }

    mutating func acknowledge() {
        pending = nil
        acknowledgedAt = cameraAvailableAt
    }

    mutating func cameraRemoved() { self = Self() }
}
