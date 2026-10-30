import XCTest
@testable import MovemberCore

final class CameraControlStateTests: XCTestCase {
    func testPermissionCanBeRequestedBeforeAnyCamerasAreVisible() {
        let state = CameraControlState(permission: .notRequested, isRunning: false, isBusy: false, hasCamera: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.action, .requestAccess)
    }

    func testBlockedPermissionCanOpenSettingsWithoutAVisibleCamera() {
        let state = CameraControlState(permission: .blocked, isRunning: false, isBusy: false, hasCamera: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.action, .openSettings)
    }

    func testStartingCaptureRequiresACameraAndPermission() {
        XCTAssertFalse(CameraControlState(permission: .allowed, isRunning: false, isBusy: false, hasCamera: false).isEnabled)
        let ready = CameraControlState(permission: .allowed, isRunning: false, isBusy: false, hasCamera: true)
        XCTAssertTrue(ready.isEnabled)
        XCTAssertEqual(ready.action, .start)
    }

    func testStoppingRemainsAvailableIfTheSelectedCameraDisappears() {
        let state = CameraControlState(permission: .allowed, isRunning: true, isBusy: false, hasCamera: false)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.action, .stop)
    }

    func testTransitionsDisableTheButtonForEveryPermissionState() {
        for permission in [CameraControlState.Permission.allowed, .blocked, .notRequested] {
            XCTAssertFalse(CameraControlState(permission: permission, isRunning: false, isBusy: true, hasCamera: true).isEnabled)
        }
    }
}
