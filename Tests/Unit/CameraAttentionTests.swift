import XCTest
@testable import MovemberCore

final class CameraAttentionTests: XCTestCase {
    func testExtensionApprovalTakesPriorityOverPhysicalCameraAccess() {
        let snapshot = CameraAttentionSnapshot(extensionState: .awaitingApproval, cameraPermission: .blocked)
        XCTAssertEqual(snapshot.issue?.kind, .extensionPermission)
        XCTAssertEqual(snapshot.issue?.recovery, .extensionSettings)
        XCTAssertTrue(snapshot.issue!.message.contains("Camera Extensions"))
        XCTAssertFalse(snapshot.isHealthy)
    }

    func testPhysicalCameraPermissionHasItsOwnRecovery() {
        var snapshot = CameraAttentionSnapshot(extensionState: .ready, cameraPermission: .notRequested)
        XCTAssertEqual(snapshot.issue?.recovery, .requestCameraAccess)
        snapshot.cameraPermission = .blocked
        XCTAssertEqual(snapshot.issue?.recovery, .cameraSettings)
        snapshot.cameraPermission = .allowed
        XCTAssertNil(snapshot.issue)
        XCTAssertTrue(snapshot.isHealthy)
    }

    func testActionableFailuresAndIntentionalRemoval() {
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .notInstalled).issue?.recovery, .installExtension)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .disabled).issue?.kind, .extensionPermission)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .failed("Failure")).issue?.message, "Failure")
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .unavailable).issue?.recovery, .restartApp)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .unavailable, extensionRecovery: .openSettings).issue?.recovery, .extensionSettings)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .restartRequired).issue?.kind, .restartRequired)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .ready, hasCamera: false).issue?.kind, .missingCamera)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .ready, captureFailure: "Capture failed").issue?.recovery, .retryCapture)
        XCTAssertEqual(CameraAttentionSnapshot(extensionState: .ready, outputStatus: .cannotStart(-4)).issue?.kind, .extensionFailure)
        XCTAssertNil(CameraAttentionSnapshot(extensionState: .removed, hasCamera: false).issue)
    }

    func testNotificationsWaitForFinishedWork() {
        let issue = CameraAttentionSnapshot(extensionState: .disabled).issue!
        var policy = CameraAttentionNotificationPolicy()
        XCTAssertNil(policy.next(issue: issue, isWorking: true))
        XCTAssertEqual(policy.next(issue: issue, isWorking: false), issue)
        XCTAssertNil(policy.next(issue: issue, isWorking: false))
    }

    func testDeliveredWarningsSurviveRechecksAndAppRestartsUntilRecovery() {
        let issue = CameraAttentionSnapshot(extensionState: .disabled).issue!
        var policy = CameraAttentionNotificationPolicy()
        _ = policy.next(issue: issue, isWorking: false)
        policy.didDeliver(issue.kind)
        XCTAssertNil(policy.next(issue: nil, isWorking: true))
        XCTAssertNil(policy.next(issue: issue, isWorking: false))
        var relaunched = CameraAttentionNotificationPolicy(delivered: policy.delivered)
        XCTAssertNil(relaunched.next(issue: issue, isWorking: false))
        let other = CameraAttentionSnapshot(extensionState: .ready, hasCamera: false).issue!
        XCTAssertEqual(relaunched.next(issue: other, isWorking: false), other)
        relaunched.recovered()
        XCTAssertEqual(relaunched.next(issue: issue, isWorking: false), issue)
    }

    func testNotificationCopyIsBriefAndExcludesDetailedDiagnostics() {
        let kinds: [CameraAttentionIssue.Kind] = [.extensionPermission, .missingExtension, .extensionFailure,
            .restartRequired, .cameraPermission, .missingCamera, .captureFailure]
        for kind in kinds {
            let issue = CameraAttentionIssue(kind: kind, title: "Detailed failure", message: "Private diagnostic detail → Settings → Submenu", recovery: .showSettings)
            XCTAssertLessThanOrEqual(issue.notificationCopy.title.count, 30)
            XCTAssertLessThanOrEqual(issue.notificationCopy.body.count, 60)
            XCTAssertFalse(issue.notificationCopy.body.contains("→"))
            XCTAssertFalse(issue.notificationCopy.body.contains("Private"))
        }
        let approval = CameraAttentionSnapshot(extensionState: .awaitingApproval).issue!
        XCTAssertEqual(approval.notificationCopy.title, "Camera needs approval")
        XCTAssertEqual(approval.notificationCopy.body, "Open MovemberCam to enable it.")
        XCTAssertTrue(approval.message.contains("System Settings"))
    }

    func testUnsentAlertsCanRetryWithoutLoopingWhenPermissionIsDenied() {
        let issue = CameraAttentionSnapshot(extensionState: .disabled).issue!
        var policy = CameraAttentionNotificationPolicy()
        XCTAssertNotNil(policy.next(issue: issue, isWorking: false))
        XCTAssertNil(policy.next(issue: issue, isWorking: false))
        policy.retryUnsent(issue.kind)
        XCTAssertNotNil(policy.next(issue: issue, isWorking: false))
    }
}
