import XCTest
@testable import MovemberCore

final class OverlayConfigurationTests: XCTestCase {
    func testDefaultLinksUseTheFundraiser() {
        let configuration = OverlayConfiguration()
        XCTAssertEqual(configuration.qrURL, "https://movember.com/t/musta-ch")
        XCTAssertEqual(configuration.displayURL, configuration.qrURL)
    }

    func testValidationTrimsLinksAndPreservesIndependentDisplayText() throws {
        let configuration = OverlayConfiguration(qrURL: " \nhttps://example.com/donate\t ",
            displayURL: "  example.com/my-page\n", corner: .left, mirrorCamera: true)
        let validated = try configuration.validated()
        XCTAssertEqual(validated.qrURL, "https://example.com/donate")
        XCTAssertEqual(validated.displayURL, "example.com/my-page")
        XCTAssertEqual(validated.corner, .left)
        XCTAssertTrue(validated.mirrorCamera)
    }

    func testHTTPAndHTTPSDestinationsAreAccepted() throws {
        for url in ["http://example.com", "https://example.com/path?q=donate#fundraiser", "HTTPS://example.com"] {
            XCTAssertNoThrow(try OverlayConfiguration(qrURL: url).validated(), url)
        }
    }

    func testInvalidOrCredentialBearingDestinationsAreRejected() {
        for url in ["", "example.com", "https://", "file:///tmp/page", "javascript:alert(1)",
                    "https://user@example.com", "https://user:password@example.com",
                    "https://example.com/two words", "https://example.com/\npath"] {
            XCTAssertThrowsError(try OverlayConfiguration(qrURL: url).validated(), url)
        }
    }

    func testQRDestinationLimitIsMeasuredInUTF8Bytes() {
        let prefix = "https://example.com/"
        let atLimit = prefix + String(repeating: "x", count: 220 - prefix.utf8.count)
        XCTAssertNoThrow(try OverlayConfiguration(qrURL: atLimit).validated())
        XCTAssertThrowsError(try OverlayConfiguration(qrURL: atLimit + "x").validated())
        let unicode = prefix + String(repeating: "é", count: 110)
        XCTAssertLessThan(unicode.count, 220)
        XCTAssertThrowsError(try OverlayConfiguration(qrURL: unicode).validated())
    }

    func testWrittenURLMustFitOneLine() {
        for text in ["", "   ", "first\nsecond", "first\rsecond", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try OverlayConfiguration(displayURL: text).validated(), text)
        }
        XCTAssertNoThrow(try OverlayConfiguration(displayURL: String(repeating: "a", count: 64)).validated())
    }

    func testConfigurationRoundTripsAllFields() throws {
        let expected = OverlayConfiguration(qrURL: "https://example.com/donate", displayURL: "donate.example",
            corner: .left, mirrorCamera: true)
        XCTAssertEqual(try JSONDecoder().decode(OverlayConfiguration.self,
            from: JSONEncoder().encode(expected)), expected)
    }
}
