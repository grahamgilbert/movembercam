import XCTest
@testable import MovemberCore

final class LaunchBehaviorTests: XCTestCase {
    func testOrdinaryLaunchShowsSettingsWithoutOpeningCamera() {
        let launch = LaunchBehavior(arguments: [], launchedAtLogin: false)
        XCTAssertTrue(launch.showSettings)
        XCTAssertFalse(launch.resumeCamera)
    }

    func testLoginLaunchStaysHiddenAndNeverResumesCapture() {
        let launch = LaunchBehavior(arguments: ["--resume-camera"], launchedAtLogin: true)
        XCTAssertFalse(launch.showSettings)
        XCTAssertFalse(launch.resumeCamera)
    }

    func testRestartResumesOnlyPreviouslyActiveCapture() {
        for wasCapturing in [true, false] {
            let launch = LaunchBehavior(arguments: LaunchBehavior.restartArguments(wasCapturing: wasCapturing),
                                        launchedAtLogin: false)
            XCTAssertTrue(launch.showSettings)
            XCTAssertEqual(launch.resumeCamera, wasCapturing)
        }
    }
}
