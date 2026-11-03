import XCTest
@testable import MovemberCore

final class RecoveryDraftTests: XCTestCase {
    func testRecoveryKeepsInvalidEditsWithoutApplyingThemAndConsumesSnapshotOnce() {
        let name = "MovemberCam.draft-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let applied = OverlayConfiguration()
        OverlayPreferences.save(applied, to: defaults)
        var draft = applied
        draft.qrURL = "unfinished edit"
        OverlayPreferences.preserveDraft(draft, in: defaults)
        XCTAssertEqual(OverlayPreferences.takeRecoveryDraft(from: defaults, restoring: true), draft)
        XCTAssertEqual(OverlayPreferences.load(from: defaults), applied)
        XCTAssertNil(OverlayPreferences.takeRecoveryDraft(from: defaults, restoring: true))
    }

    func testOrdinaryLaunchDiscardsAnUnusedRecoverySnapshot() {
        let name = "MovemberCam.draft-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        OverlayPreferences.preserveDraft(OverlayConfiguration(), in: defaults)
        XCTAssertNil(OverlayPreferences.takeRecoveryDraft(from: defaults, restoring: false))
        XCTAssertNil(OverlayPreferences.takeRecoveryDraft(from: defaults, restoring: true))
    }
}
