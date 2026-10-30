import Foundation

struct SetupReadiness {
    var cameraAccessAllowed: Bool
    var isInApplications: Bool
    var virtualCameraAvailable: Bool
    var zoomConfirmed: Bool

    var installationComplete: Bool { isInApplications && virtualCameraAvailable }
    var canFinish: Bool { cameraAccessAllowed && installationComplete && zoomConfirmed }
}
