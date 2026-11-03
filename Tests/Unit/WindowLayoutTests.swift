import XCTest
@testable import MovemberCore

final class WindowLayoutTests: XCTestCase {
    func testOversizedSavedWindowFitsFourteenInchDisplay() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 890)
        let saved = CGRect(x: 120, y: -100, width: 1280, height: 1050)
        let fitted = WindowLayout.fittedFrame(saved, visibleFrame: screen, minimumSize: CGSize(width: 860, height: 620))
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(fitted))
        XCTAssertLessThan(fitted.height, saved.height)
    }

    func testScaledLaptopScreenCanShrinkBelowPreferredMinimum() {
        let screen = CGRect(x: 0, y: 23, width: 1024, height: 650)
        let fitted = WindowLayout.fittedFrame(CGRect(x: 0, y: 0, width: 1280, height: 980), visibleFrame: screen,
                                               minimumSize: CGSize(width: 1100, height: 720))
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(fitted))
        XCTAssertEqual(fitted.size, CGSize(width: 1000, height: 626))
    }

    func testSavedPositionOnDisconnectedMonitorMovesOntoLaptop() {
        let screen = CGRect(x: 0, y: 25, width: 1280, height: 720)
        let fitted = WindowLayout.fittedFrame(CGRect(x: 2800, y: 900, width: 1100, height: 720), visibleFrame: screen,
                                               minimumSize: CGSize(width: 860, height: 620))
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(fitted))
    }

    func testWindowAlreadyInsideUsableAreaIsUnchanged() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 890)
        let frame = CGRect(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertEqual(WindowLayout.fittedFrame(frame, visibleFrame: screen, minimumSize: CGSize(width: 860, height: 620)), frame)
    }

    func testDisplayToLeftOfMainScreenKeepsNegativeCoordinates() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 870)
        let fitted = WindowLayout.fittedFrame(CGRect(x: 100, y: 100, width: 1100, height: 720), visibleFrame: screen,
                                               minimumSize: CGSize(width: 860, height: 620))
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(fitted))
        XCTAssertLessThan(fitted.maxX, 0)
    }
}
