import XCTest
@testable import MovemberCore

final class VirtualCameraStatusTests: XCTestCase {
    func testSendingCompletesInstallationEvenBeforeAVFoundationDiscoversTheCamera() {
        let status = VirtualCameraStatus.sending
        XCTAssertTrue(status.isInstalled)
    }

    func testStoppingCaptureDoesNotUninstallTheCamera() {
        XCTAssertTrue(VirtualCameraStatus.idle(isInstalled: true).isInstalled)
        XCTAssertFalse(VirtualCameraStatus.idle(isInstalled: false).isInstalled)
    }

    func testConnectionErrorsAreNotReportedAsMissingInstallation() {
        for status in [VirtualCameraStatus.cannotOpen(-1), .cannotStart(-4), .cannotStart(-1)] {
            XCTAssertTrue(status.isInstalled)
        }
    }

    func testMissingDeviceRequiresInstallationAgain() {
        XCTAssertFalse(VirtualCameraStatus.notInstalled.isInstalled)
    }
}
