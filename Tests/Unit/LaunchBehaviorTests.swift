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

    func testRelaunchWaitsForExitAndPassesPathsAsArguments() {
        let path = "/Applications/Name with 'quotes' and $(text).app"
        let arguments = LaunchBehavior.relaunchArguments(processID: 123, applicationPath: path, wasCapturing: false)
        XCTAssertEqual(Array(arguments.suffix(3)), ["123", path, "--show-settings"])
        XCTAssertFalse(arguments[1].contains(path))
        XCTAssertTrue(arguments[1].contains("kill -0"))
        XCTAssertFalse(arguments.contains("--resume-camera"))
    }

}
