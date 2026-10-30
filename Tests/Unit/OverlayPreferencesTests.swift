import XCTest
@testable import MovemberCore

final class OverlayPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "MovemberCam.unit-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    func testEmptyPreferencesUseDefaults() {
        XCTAssertEqual(OverlayPreferences.load(from: defaults), OverlayConfiguration())
    }

    func testCorruptOrInvalidPreferencesFallBackToDefaults() throws {
        defaults.set(Data("broken JSON".utf8), forKey: OverlayPreferences.key)
        XCTAssertEqual(OverlayPreferences.load(from: defaults), OverlayConfiguration())
        let invalid = OverlayConfiguration(qrURL: "file:///tmp/fundraiser")
        defaults.set(try JSONEncoder().encode(invalid), forKey: OverlayPreferences.key)
        XCTAssertEqual(OverlayPreferences.load(from: defaults), OverlayConfiguration())
    }

    func testCustomSettingsSurviveReopeningPreferences() {
        let expected = OverlayConfiguration(qrURL: "https://example.com/custom", displayURL: "my.example",
            corner: .left, mirrorCamera: true)
        OverlayPreferences.save(expected, to: defaults)
        XCTAssertEqual(OverlayPreferences.load(from: UserDefaults(suiteName: suite)!), expected)
    }

    func testMigrationPreservesCustomDisplayURLAndOverlaySettings() {
        let old = OverlayConfiguration(qrURL: "https://movember.com", displayURL: "custom.example",
            corner: .left, mirrorCamera: true)
        OverlayPreferences.save(old, to: defaults)
        var expected = old
        expected.qrURL = OverlayConfiguration.defaultFundraisingURL
        XCTAssertEqual(OverlayPreferences.load(from: defaults), expected)
        XCTAssertEqual(OverlayPreferences.load(from: UserDefaults(suiteName: suite)!), expected)
    }

    func testMigrationPreservesCustomQRDestination() {
        for oldDisplay in ["movember.com", "https://movember.com"] {
            OverlayPreferences.save(OverlayConfiguration(qrURL: "https://example.com/custom",
                displayURL: oldDisplay), to: defaults)
            let migrated = OverlayPreferences.load(from: defaults)
            XCTAssertEqual(migrated.qrURL, "https://example.com/custom")
            XCTAssertEqual(migrated.displayURL, OverlayConfiguration.defaultFundraisingURL)
        }
    }
}
