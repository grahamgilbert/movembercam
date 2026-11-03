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
    func testOlderPendingApprovalDoesNotHideANewerEnabledExtension() {
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled,
            installed: [installed("8", enabled: false, approval: true), installed("10")]), .verify)
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled,
            installed: [installed("8", enabled: false, approval: true), installed("9")]), .installUpdate)
        XCTAssertEqual(CameraExtensionUpgradeAction.decide(bundled: bundled,
            installed: [installed("11", enabled: false, approval: true), installed("10")]), .approveInSettings)
    }
    func testApprovalInstructionsNameTheCameraSpecificSettings() {
        XCTAssertTrue(CameraExtensionSettings.instructions(macOSMajorVersion: 14).contains("Privacy & Security"))
        XCTAssertTrue(CameraExtensionSettings.instructions(macOSMajorVersion: 15).contains("Camera Extensions"))
        let modern = CameraExtensionSettings.instructions(macOSMajorVersion: 26)
        XCTAssertTrue(modern.contains("By Category → Camera Extensions"))
        XCTAssertTrue(modern.contains("MovemberCam Camera"))
    }
    func testEnabledButPendingActivationDoesNotAskForPermissionAgain() {
        XCTAssertTrue(CameraExtensionUpdateState.awaitingActivation.message.contains("is enabled"))
        XCTAssertTrue(CameraExtensionUpdateState.awaitingActivation.busy)
        XCTAssertFalse(CameraExtensionUpdateState.awaitingApproval.busy)
        XCTAssertEqual(CameraExtensionUpdateState.awaitingApproval.connectionSummary, "Camera extension approval required")
        XCTAssertEqual(CameraExtensionUpdateState.awaitingActivation.connectionSummary, "Waiting for macOS activation")
        XCTAssertNil(CameraExtensionUpdateState.ready.connectionSummary)
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
        for state in [CameraExtensionUpdateState.checking, .installing, .awaitingActivation, .verifying, .ready, .restartRequired] {
            XCTAssertEqual(state.recoveryAction(afterAppRestart: false), .none)
        }
    }

}
