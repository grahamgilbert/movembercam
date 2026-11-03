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

    func testOldExtensionRequiresAnUpdateBeforeItIsUsable() {
        XCTAssertTrue(VirtualCameraStatus.requiresUpdate.isInstalled)
        XCTAssertFalse(VirtualCameraStatus.requiresUpdate.isUsable)
    }

    func testActiveCaptureMustSendAFrameBeforeConnectionIsUsable() {
        var health = VirtualCameraConnectionHealth()
        health.expectsFrames = true
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .connecting)
        XCTAssertFalse(health.status(isInstalled: true, supportsDemand: true).isUsable)
        health.sentFrame()
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .sending)
    }

    func testDiscoveryCannotEraseAConnectionFailure() {
        var health = VirtualCameraConnectionHealth()
        health.expectsFrames = true
        health.failed(.cannotStart(-4))
        for _ in 0..<30 {
            XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .cannotStart(-4))
        }
        health.reset()
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .connecting)
        health.failed(.cannotOpen(-1))
        health.sentFrame()
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .sending)
    }

    func testIdleDiscoveryRemainsUsableWithoutOpeningPhysicalCamera() {
        let health = VirtualCameraConnectionHealth()
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: true), .idle(isInstalled: true))
        XCTAssertEqual(health.status(isInstalled: false, supportsDemand: false), .notInstalled)
        XCTAssertEqual(health.status(isInstalled: true, supportsDemand: false), .requiresUpdate)
    }

    func testMissingDeviceRequiresInstallationAgain() {
        XCTAssertFalse(VirtualCameraStatus.notInstalled.isInstalled)
    }
}
