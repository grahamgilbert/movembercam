import XCTest
@testable import MovemberCore

final class SetupReadinessTests: XCTestCase {
    func testInstalledCameraCompletesInstallationWithoutAnotherInstallRequest() {
        let state = SetupReadiness(cameraAccessAllowed: true, isInApplications: true,
            virtualCameraAvailable: true, zoomConfirmed: false)
        XCTAssertTrue(state.installationComplete)
        XCTAssertFalse(state.canFinish, "Zoom still needs to be checked separately.")
    }

    func testFinishRequiresEveryPrerequisite() {
        for camera in [false, true] {
            for location in [false, true] {
                for installed in [false, true] {
                    for zoom in [false, true] {
                        let state = SetupReadiness(cameraAccessAllowed: camera, isInApplications: location,
                            virtualCameraAvailable: installed, zoomConfirmed: zoom)
                        XCTAssertEqual(state.installationComplete, location && installed)
                        XCTAssertEqual(state.canFinish, camera && location && installed && zoom)
                    }
                }
            }
        }
    }

    func testPreviouslyConfirmedZoomDoesNotHideARemovedCamera() {
        let state = SetupReadiness(cameraAccessAllowed: true, isInApplications: true,
            virtualCameraAvailable: false, zoomConfirmed: true)
        XCTAssertFalse(state.installationComplete)
        XCTAssertFalse(state.canFinish)
    }
}
