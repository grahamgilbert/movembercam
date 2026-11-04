import XCTest
@testable import MovemberCore

final class VideoAppRestartStateTests: XCTestCase {
    let setup = Date(timeIntervalSince1970: 200)
    let old = VideoAppProcess(pid: 10, launchedAt: Date(timeIntervalSince1970: 100))

    func testExistingZoomNeedsRestartEvenWhenCameraIsReady() {
        var state = VideoAppRestartState()
        state.cameraBecameAvailable(at: setup, running: old)
        XCTAssertEqual(state.pending, old)
        state.reconcile(running: old)
        XCTAssertEqual(state.pending, old)
    }

    func testZoomStartedAfterSetupNeedsNoWarning() {
        var state = VideoAppRestartState()
        state.cameraBecameAvailable(at: setup, running: VideoAppProcess(pid: 11, launchedAt: setup.addingTimeInterval(1)))
        XCTAssertNil(state.pending)
    }

    func testQuitAndRelaunchClearTrackedOldInstance() {
        var state = VideoAppRestartState()
        state.cameraBecameAvailable(at: setup, running: old)
        state.reconcile(running: nil)
        XCTAssertNil(state.pending)
        state.cameraBecameAvailable(at: setup.addingTimeInterval(20), running: old)
        state.reconcile(running: VideoAppProcess(pid: old.pid, launchedAt: setup.addingTimeInterval(21)))
        XCTAssertNil(state.pending, "A reused PID must not be mistaken for the original process")
    }

    func testTrackingSurvivesAppRelaunchAndRepeatedProbes() throws {
        var state = VideoAppRestartState()
        state.cameraBecameAvailable(at: setup, running: old)
        var restored = try JSONDecoder().decode(VideoAppRestartState.self, from: JSONEncoder().encode(state))
        restored.cameraBecameAvailable(at: setup, running: old)
        XCTAssertEqual(restored.pending, old)
        restored.acknowledge()
        restored.cameraBecameAvailable(at: setup, running: old)
        XCTAssertNil(restored.pending)
    }

    func testAnotherCameraSetupTracksZoomAgainAfterAcknowledgement() {
        var state = VideoAppRestartState()
        state.cameraBecameAvailable(at: setup, running: old)
        state.acknowledge()
        state.cameraWillChange()
        XCTAssertTrue(state.awaitingCamera)
        state.cameraBecameAvailable(at: setup.addingTimeInterval(30), running: old)
        XCTAssertEqual(state.pending, old)
        XCTAssertFalse(state.awaitingCamera)
    }

    func testZoomOpenedDuringApprovalIsTrackedWhenSetupCompletes() {
        var state = VideoAppRestartState()
        state.cameraWillChange()
        let zoom = VideoAppProcess(pid: 12, launchedAt: setup.addingTimeInterval(1))
        state.cameraBecameAvailable(at: setup.addingTimeInterval(10), running: zoom)
        XCTAssertEqual(state.pending, zoom)
    }
}
