import XCTest
@testable import MovemberCore

final class LaunchBehaviorTests: XCTestCase {
    func testOrdinaryLaunchShowsSettingsWithoutOpeningCamera() {
        let launch = LaunchBehavior(arguments: [], launchedAtLogin: false)
        XCTAssertTrue(launch.showSettings)
    }

    func testLoginLaunchStaysHiddenAndNeverResumesCapture() {
        let launch = LaunchBehavior(arguments: ["--resume-camera"], launchedAtLogin: true)
        XCTAssertFalse(launch.showSettings)
    }

    func testRestartOnlyRestoresSettings() {
        XCTAssertEqual(LaunchBehavior.restartArguments(), ["--show-settings"])
    }

    func testRelaunchWaitsForExitAndPassesPathsAsArguments() {
        let path = "/Applications/Name with 'quotes' and $(text).app"
        let arguments = LaunchBehavior.relaunchArguments(processID: 123, applicationPath: path)
        XCTAssertEqual(Array(arguments.suffix(3)), ["123", path, "--show-settings"])
        XCTAssertFalse(arguments[1].contains(path))
        XCTAssertTrue(arguments[1].contains("kill -0"))
        XCTAssertFalse(arguments.contains("--resume-camera"))
    }

}
