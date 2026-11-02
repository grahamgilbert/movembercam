import XCTest
@testable import MovemberCore

final class VideoFormatTests: XCTestCase {
    func testExactCameraSizesArePreserved() {
        for format in VideoFormat.supported {
            XCTAssertEqual(format.bestMatch(in: VideoFormat.supported), format)
        }
    }

    func testUnknownSizeUsesClosestAspectRatioWithoutUpscaling() {
        let camera = VideoFormat(width: 2048, height: 1536)
        XCTAssertEqual(camera.bestMatch(in: VideoFormat.supported), VideoFormat(width: 1920, height: 1440))
        XCTAssertEqual(VideoFormat(width: 2304, height: 1296).bestMatch(in: VideoFormat.supported),
                       VideoFormat(width: 1920, height: 1080))
    }

    func testOlderExtensionFallsBackToItsAdvertised720pFormat() {
        XCTAssertEqual(VideoFormat(width: 3840, height: 2160).bestMatch(in: [.hd720]), .hd720)
        XCTAssertNil(VideoFormat.hd720.bestMatch(in: []))
    }

    func testChoosesLargestModeAt30FPSAndIgnores8K() {
        let modes = [mode(1280, 720, 15...60), mode(3840, 2160, 30...30), mode(7680, 4320, 30...30)]
        XCTAssertEqual(VideoFormat.preferredCaptureModeIndex(in: modes), 1)
    }

    func testPrefers30FPSToHigherResolutionAt15FPS() {
        XCTAssertEqual(VideoFormat.preferredCaptureModeIndex(in: [mode(1920, 1080, 30...60), mode(3840, 2160, 15...15)]), 0)
    }

    func testCameraWithout30FPSUsesNearestRate() {
        let modes = [mode(3840, 2160, 15...15), mode(1920, 1080, 29.97...29.97)]
        XCTAssertEqual(VideoFormat.preferredCaptureModeIndex(in: modes), 1)
        XCTAssertEqual(modes[1].frameRate, 29.97)
    }

    func testDisjointFrameRateRangesAreRespected() {
        let mode = VideoFormat.CaptureMode(format: .hd720, frameRateRanges: [10...15, 60...120])
        XCTAssertEqual(mode.frameRate, 15)
    }

    func testNoUsableModesReturnsNil() {
        XCTAssertNil(VideoFormat.preferredCaptureModeIndex(in: []))
        XCTAssertNil(VideoFormat.preferredCaptureModeIndex(in: [mode(0, 720, 30...30), mode(7680, 4320, 30...30)]))
        XCTAssertNil(VideoFormat.preferredCaptureModeIndex(in: [.init(format: .hd720, frameRateRanges: [])]))
    }

    private func mode(_ width: Int, _ height: Int, _ rates: ClosedRange<Double>) -> VideoFormat.CaptureMode {
        .init(format: VideoFormat(width: width, height: height), frameRateRanges: [rates])
    }
}
