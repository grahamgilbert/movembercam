import AppKit
import AVFoundation
import SwiftUI

// Inert engine exercises the production AppModel without camera access or CMIO.
struct CameraChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

final class CameraDiscovery: NSObject {
    @objc dynamic var devices: [AVCaptureDevice] = []
}

final class CameraEngine {
    static let discoverySession = CameraDiscovery()
    static var choices = [CameraChoice(id: "one", name: "One"), CameraChoice(id: "two", name: "Two")]
    static var latest: CameraEngine!
    var onPreview: (@MainActor (CMSampleBuffer) -> Void)?
    var onOutputStatus: ((VirtualCameraStatus) -> Void)?
    var onDemand: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var starts: [String] = []
    var stops = 0
    var reconnects = 0
    var startCompletion: ((Error?) -> Void)?
    var stopCompletion: (() -> Void)?
    var holdStop = false

    init(configuration: OverlayConfiguration) throws { Self.latest = self }
    static func cameras() -> [CameraChoice] { choices }
    func refreshVirtualCameraAvailability() {}
    func reconnectVirtualCamera() { reconnects += 1 }
    func showPlaceholder() {}
    func setOverlayEnabled(_ enabled: Bool) {}
    func configure(_ configuration: OverlayConfiguration, completion: @escaping (Error?) -> Void) { completion(nil) }
    func start(cameraID: String, completion: @escaping (Error?) -> Void) {
        starts.append(cameraID)
        startCompletion = completion
    }
    func finishStart(_ error: Error? = nil) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }
    func stop(completion: (() -> Void)? = nil) {
        stops += 1
        if holdStop { stopCompletion = completion } else { completion?() }
    }
    func finishStop() {
        let completion = stopCompletion
        stopCompletion = nil
        completion?()
    }
}

