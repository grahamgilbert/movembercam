import XCTest
@testable import MovemberCore

final class CameraExtensionUpgradeTests: XCTestCase {
    private let bundled = CameraExtensionVersion(release: "1.0.3", build: "10")
    private func installed(_ build: String, enabled: Bool = true, approval: Bool = false,
                           uninstalling: Bool = false, release: String = "1.0.3") -> InstalledCameraExtension {
        InstalledCameraExtension(version: CameraExtensionVersion(release: release, build: build),
            isEnabled: enabled, isAwaitingApproval: approval, isUninstalling: uninstalling)
    }
    func testUpgradeUsesNumericBuildOrder() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: [installed("9")]), .installUpdate)
    }
    func testFirstInstallRemainsAnExplicitChoice() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: []), .notInstalled)
    }
    func testMatchingAndNewerVersionsAreVerifiedWithoutDowngrading() {
        for build in ["10", "11"] {
            XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: [installed(build)]), .verify)
        }
    }
    func testDisabledExtensionsAreNotAutomaticallyReenabled() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: [installed("9", enabled: false)]), .enableInSettings)
    }
    func testAwaitingApprovalDoesNotSubmitAnotherUpdate() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: [installed("10", enabled: false, approval: true)]), .approveInSettings)
    }
    func testOldRemovalEntriesDoNotTriggerReinstallation() {
        let entries = [installed("9", uninstalling: true), installed("10")]
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: entries), .verify)
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled, installed: [entries[0]]), .restartMac)
    }
    func testReleaseVersionTakesPriorityOverBuildCounter() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled,
            installed: [installed("999", release: "1.0.2")]), .installUpdate)
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled,
            installed: [installed("1", release: "1.0.10")]), .verify)
    }
    func testConnectionErrorsDoNotCountAsAUsableCamera() {
        XCTAssertTrue(VirtualCameraStatus.sending.isUsable)
        XCTAssertTrue(VirtualCameraStatus.idle(isInstalled: true).isUsable)
        for status in [VirtualCameraStatus.notInstalled, .idle(isInstalled: false), .cannotOpen(-1), .cannotStart(-4)] {
            XCTAssertFalse(status.isUsable)
        }
    }
    func testRecoveryPresentsOnlyTheNextAction() {
        XCTAssertEqual(CameraExtensionUpdateState.notInstalled.recoveryAction(afterAppRestart: false), .install)
        XCTAssertEqual(CameraExtensionUpdateState.awaitingApproval.recoveryAction(afterAppRestart: false), .openSettings)
        XCTAssertEqual(CameraExtensionUpdateState.unavailable.recoveryAction(afterAppRestart: false), .restartApp)
        XCTAssertEqual(CameraExtensionUpdateState.unavailable.recoveryAction(afterAppRestart: true), .openSettings)
        for state in [CameraExtensionUpdateState.checking, .installing, .verifying, .ready, .restartRequired] {
            XCTAssertEqual(state.recoveryAction(afterAppRestart: false), .none)
        }
    }

}
