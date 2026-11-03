import XCTest
@testable import MovemberCore

final class CameraControlStateTests: XCTestCase {
    func testPermissionCanBeRequestedBeforeAnyCamerasAreVisible() {
        let state = CameraControlState(permission: .notRequested, isBusy: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.action, .requestAccess)
    }

    func testBlockedPermissionCanOpenSettings() {
        let state = CameraControlState(permission: .blocked, isBusy: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.action, .openSettings)
    }

    func testAuthorizedCameraHasNoManualStartOrStopAction() {
        let state = CameraControlState(permission: .allowed, isBusy: false)
        XCTAssertNil(state.action)
        XCTAssertFalse(state.isEnabled)
    }

    func testTransitionsDisablePermissionActions() {
        for permission in [CameraControlState.Permission.allowed, .blocked, .notRequested] {
            XCTAssertFalse(CameraControlState(permission: permission, isBusy: true).isEnabled)
        }
    }

    func testDemandSurvivesExtensionReplacement() {
        var demand = CameraCaptureDemand()
        XCTAssertFalse(demand.shouldCapture)
        demand.update(true)
        XCTAssertTrue(demand.shouldCapture)
        demand.isSuspended = true
        XCTAssertFalse(demand.shouldCapture)
        demand.isSuspended = false
        XCTAssertTrue(demand.shouldCapture)
        demand.update(false)
        XCTAssertFalse(demand.shouldCapture)
    }

    func testFailureWaitsForAnotherConsumerSession() {
        var demand = CameraCaptureDemand()
        demand.update(true)
        demand.hasFailed = true
        demand.update(true)
        XCTAssertFalse(demand.shouldCapture)
        demand.update(false)
        demand.update(true)
        XCTAssertTrue(demand.shouldCapture)
    }

    func testPreviewAndVirtualConsumersIndependentlyKeepCaptureRunning() {
        var demand = CameraCaptureDemand()
        demand.showPreview(true)
        XCTAssertTrue(demand.shouldCapture)
        demand.update(true)
        demand.showPreview(false)
        XCTAssertTrue(demand.shouldCapture)
        demand.update(false)
        XCTAssertFalse(demand.shouldCapture)
        demand.showPreview(true)
        demand.update(false)
        XCTAssertTrue(demand.shouldCapture)
    }

    func testIdleVirtualSnapshotDoesNotRetryAFailedPreview() {
        var demand = CameraCaptureDemand()
        demand.showPreview(true)
        demand.hasFailed = true
        demand.update(false)
        XCTAssertFalse(demand.shouldCapture)
        demand.showPreview(false)
        demand.showPreview(true)
        XCTAssertTrue(demand.shouldCapture)
    }
}
