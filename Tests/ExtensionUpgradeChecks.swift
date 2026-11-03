import Foundation
import SystemExtensions

@main enum ExtensionUpgradeChecks {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw VideoError.message("FAIL: \(message)") }
        checks += 1
        print("PASS: \(message)")
    }
    final class Harness {
        var requests: [OSSystemExtensionRequest] = []
        var ticks: [() -> Void] = []
        var paused = false
        var reconnects = 0
        var suspensions: [Bool] = []
        let defaults: UserDefaults
        private let suite: String?
        init(defaults: UserDefaults? = nil) {
            if let defaults { self.defaults = defaults; suite = nil }
            else {
                let suite = "MovemberCam.upgrade-harness.\(UUID().uuidString)"
                self.suite = suite
                self.defaults = UserDefaults(suiteName: suite)!
            }
        }
        deinit { if let suite { defaults.removePersistentDomain(forName: suite) } }
        lazy var installer: ExtensionInstaller = {
            let value = ExtensionInstaller(bundledVersion: CameraExtensionVersion(release: "1.0.3", build: "10"),
                canInstall: true, submit: { [unowned self] in self.requests.append($0) },
                schedule: { [unowned self] in self.ticks.append($0) }, recoveryDefaults: self.defaults)
            value.prepareForActivation = { [unowned self] completion in self.paused = true; completion() }
            value.reconnectCamera = { [unowned self] in self.reconnects += 1 }
            value.captureSuspensionChanged = { [unowned self] in self.suspensions.append($0) }
            return value
        }()
        func drain() { while !ticks.isEmpty { ticks.removeFirst()() } }
    }
    static func run() throws {
        let first = Harness()
        first.installer.checkForUpgrade()
        first.installer.checkForUpgrade()
        try check(first.requests.count == 1, "Startup checks the installed version only once")
        first.installer.request(first.requests[0], foundProperties: [])
        try check(first.installer.state == .notInstalled && first.requests.count == 1,
                  "A fresh installation does not activate a camera without an explicit install")

        let update = Harness()
        update.installer.inspect([InstalledCameraExtension(version: CameraExtensionVersion(release: "1.0.1", build: "6"),
            isEnabled: true, isAwaitingApproval: false, isUninstalling: false)])
        try check(update.paused && update.requests.count == 1 && update.installer.busy,
                  "An older extension pauses capture and starts its automatic update")
        try check(update.suspensions == [true], "Installer suspends capture without relying on a visible Settings window")
        let activation = update.requests[0]
        update.installer.install()
        try check(update.requests.count == 1, "Repeated install actions do not overlap a pending update")
        update.installer.observeCameraStatus(.idle(isInstalled: true))
        try check(!update.installer.isReady, "An older visible camera does not finish a pending activation")
        update.installer.requestNeedsUserApproval(activation)
        try check(update.installer.needsApproval && update.installer.busy, "Pending approval stays visible and blocks duplicate requests")
        try check(update.installer.recoveryEnabled && update.installer.recoveryAction == .openSettings,
                  "System Settings remains actionable while macOS is waiting for approval")
        update.installer.request(activation, didFinishWithResult: .completed)
        try check(update.installer.state == .verifying, "Activation completion waits for device discovery")
        try check(update.reconnects == 1, "Activation reconnects the app sink without relaunching or reinstalling")
        try check(!update.installer.blocksCapture && update.suspensions == [true, false],
                  "Leaving installation allows consumer demand to control capture again")
        update.installer.observeCameraStatus(.requiresUpdate)
        try check(!update.installer.isReady, "An extension without demand reporting cannot complete verification")
        update.installer.observeCameraStatus(.cannotOpen(-1))
        try check(!update.installer.isReady, "A connection failure cannot report a successful update")
        update.installer.observeCameraStatus(.idle(isInstalled: true))
        update.drain()
        try check(update.installer.isReady && update.requests.count == 1, "A usable camera completes verification and cancels pending retry timers")
        update.installer.observeCameraStatus(.connecting)
        try check(update.installer.state == .verifying && update.reconnects == 1,
                  "A connecting event starts bounded verification without resetting the same in-flight connection")
        update.installer.observeCameraStatus(.sending)
        update.drain()
        try check(update.installer.isReady && update.reconnects == 1,
                  "A newly connected sink completes verification without a reconnect feedback loop")
        update.installer.uninstall()
        update.installer.request(update.requests.last!, didFinishWithResult: .completed)
        try check(update.installer.state == .removed, "Uninstallation reports removal rather than update success")
        try check(update.suspensions == [true, false, true, false], "Removal also suspends capture for its lifetime")

        let reboot = Harness()
        reboot.installer.install()
        reboot.installer.request(reboot.requests[0], didFinishWithResult: .willCompleteAfterReboot)
        reboot.installer.observeCameraStatus(.idle(isInstalled: true))
        try check(reboot.installer.state == .restartRequired && !reboot.installer.busy,
                  "A required Mac restart stays visible even while the old camera is available")

        let failure = Harness()
        failure.installer.install()
        failure.installer.request(failure.requests[0], didFailWithError: NSError(domain: OSSystemExtensionErrorDomain,
            code: 9, userInfo: [NSLocalizedDescriptionKey: "Validation failed"]))
        failure.installer.observeCameraStatus(.sending)
        try check(!failure.installer.isReady && failure.installer.message.contains("notarized"),
                  "Validation errors remain visible when an older extension is still sending")

        let suite = "MovemberCam.upgrade-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovery = Harness(defaults: defaults)
        recovery.installer.install()
        recovery.installer.request(recovery.requests[0], didFinishWithResult: .completed)
        recovery.drain()
        try check(recovery.requests.count == 1 && recovery.reconnects == 2,
                  "A stalled connection retries the local sink once without reinstalling the extension")
        try check(recovery.installer.state == .unavailable && !recovery.installer.busy,
                  "Failed local recovery ends verification and exposes restart recovery after a bounded wait")
        for _ in 0..<4 {
            recovery.installer.refresh()
            recovery.installer.receiveInstalled([entry()], for: recovery.requests.last!)
            recovery.installer.observeCameraStatus(.cannotStart(-4))
            recovery.drain()
        }
        try check(recovery.installer.state == .unavailable && recovery.reconnects == 2,
                  "Enabled background status checks cannot restart exhausted recovery or hide its failure")
        recovery.installer.request(recovery.requests[0], didFinishWithResult: .completed)
        try check(recovery.installer.state == .unavailable, "Stale request completions cannot overwrite recovery guidance")
        try check(recovery.installer.recoveryAction == .restartApp, "Unavailable camera offers one app-restart action")
        recovery.installer.noteAppRestart()
        try check(recovery.installer.recoveryAction == .openSettings, "A previous app restart advances to one settings action")
        try check(!recovery.installer.needsApproval && recovery.installer.message.contains("already enabled"),
                  "A failed connection after restart does not falsely claim camera permission is disabled")
        recovery.installer.observeCameraStatus(.idle(isInstalled: true))
        try check(recovery.installer.isReady && recovery.reconnects == 2,
                  "Late camera discovery clears recovery guidance without another activation")
        try checkApprovalRecovery()
        print("\(checks) extension upgrade checks passed")
    }

    static func entry(_ build: String = "10", enabled: Bool = true, approval: Bool = false) -> InstalledCameraExtension {
        InstalledCameraExtension(version: CameraExtensionVersion(release: "1.0.3", build: build),
            isEnabled: enabled, isAwaitingApproval: approval, isUninstalling: false)
    }

    static func pendingApproval() -> Harness {
        let harness = Harness()
        harness.installer.install()
        harness.installer.requestNeedsUserApproval(harness.requests[0])
        return harness
    }

    static func checkApprovalRecovery() throws {
        let approved = pendingApproval()
        let activation = approved.requests[0]
        try check(approved.installer.offersStatusCheck && !approved.installer.showsProgress,
                  "Approval waits show camera-specific guidance and a status check instead of an installation spinner")
        approved.installer.refresh()
        try check(approved.requests.count == 2 && approved.installer.isCheckingStatus,
                  "Returning from Settings can query approval while the activation request is still pending")
        approved.installer.refresh()
        approved.installer.install()
        approved.installer.uninstall()
        try check(approved.requests.count == 2, "Status rechecks are serialized and never duplicate pending changes")
        approved.installer.receiveInstalled([entry()], for: approved.requests[1])
        try check(approved.installer.state == .awaitingActivation && !approved.installer.needsApproval &&
                  approved.installer.message.contains("is enabled"), "Enabled permission is distinguished from unfinished activation")
        approved.installer.observeCameraStatus(.sending)
        try check(!approved.installer.isReady, "An older visible device cannot finish a still-pending activation")
        approved.installer.refresh()
        approved.installer.receiveInstalled([entry()], for: approved.requests.last!)
        try check(approved.installer.state == .awaitingActivation,
                  "Repeated enabled snapshots remain in connection verification without requesting approval again")
        approved.drain()
        try check(approved.installer.state == .unavailable && approved.installer.recoveryEnabled &&
                  approved.installer.recoveryAction == .restartApp && approved.installer.message.contains("is enabled"),
                  "A missing completion offers restart recovery after a bounded wait, even with a pending request")
        approved.installer.install()
        try check(approved.requests.count == 3, "A stalled pending activation still blocks duplicate installation")
        approved.installer.request(activation, didFinishWithResult: .completed)
        approved.installer.observeCameraStatus(.sending)
        try check(approved.installer.isReady, "The original activation can still complete after status reconciliation")

        let waiting = pendingApproval()
        waiting.installer.refresh()
        waiting.installer.receiveInstalled([entry("9"), entry(enabled: false, approval: true)], for: waiting.requests.last!)
        try check(waiting.installer.state == .awaitingApproval && !waiting.installer.showsProgress,
                  "A genuine pending approval remains actionable without a false busy spinner")
        waiting.installer.refresh()
        waiting.installer.receiveInstalled([entry(enabled: false)], for: waiting.requests.last!)
        try check(waiting.installer.state == .disabled && waiting.installer.recoveryEnabled,
                  "An explicit disabled snapshot presents enable guidance while preserving the activation request")

        let older = pendingApproval()
        older.installer.refresh()
        older.installer.receiveInstalled([entry("9")], for: older.requests.last!)
        try check(older.installer.state == .awaitingApproval, "Approval of an older version cannot approve the requested update")

        let failure = pendingApproval()
        failure.installer.refresh()
        failure.installer.request(failure.requests.last!, didFailWithError: NSError(domain: "StatusCheck", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Controlled status query failure"]))
        try check(failure.installer.state == .awaitingApproval && failure.installer.busy &&
                  failure.installer.message.contains("Controlled status query failure") && !failure.installer.isCheckingStatus,
                  "A read-only status failure is visible and leaves the pending activation alive")
        failure.installer.refresh()
        try check(failure.installer.statusCheckError == nil, "A status retry clears the previous inspection error")
        failure.installer.request(failure.requests[0], didFinishWithResult: .completed)
        failure.installer.observeCameraStatus(.sending)
        let lateQuery = failure.requests.last!
        failure.installer.receiveInstalled([entry(enabled: false, approval: true)], for: lateQuery)
        try check(failure.installer.isReady && !failure.installer.isCheckingStatus,
                  "A late approval snapshot cannot overwrite successful activation")

        let lateFailure = pendingApproval()
        lateFailure.installer.refresh()
        let query = lateFailure.requests.last!
        lateFailure.installer.request(lateFailure.requests[0], didFinishWithResult: .completed)
        lateFailure.installer.observeCameraStatus(.sending)
        lateFailure.installer.request(query, didFailWithError: NSError(domain: "StatusCheck", code: 2))
        try check(lateFailure.installer.isReady && lateFailure.installer.statusCheckError == nil,
                  "A late inspection error cannot replace a successful connection")

        let reboot = pendingApproval()
        reboot.installer.refresh()
        reboot.installer.receiveInstalled([entry()], for: reboot.requests.last!)
        reboot.installer.request(reboot.requests[0], didFinishWithResult: .willCompleteAfterReboot)
        reboot.drain()
        try check(reboot.installer.state == .restartRequired, "Activation wait callbacks cannot override a required Mac restart")

        let restored = Harness()
        restored.installer.inspect([entry(enabled: false, approval: true)])
        restored.installer.install()
        try check(restored.requests.isEmpty && restored.installer.busy && !restored.installer.showsProgress,
                  "Approval pending across an app restart still blocks duplicate installation without a spinner")
        restored.installer.refresh()
        restored.installer.request(restored.requests.last!, didFailWithError: NSError(domain: "StatusCheck", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Restored approval check failed"]))
        try check(restored.installer.state == .awaitingApproval && restored.installer.message.contains("Restored approval check failed"),
                  "Failed status rechecks preserve an approval state learned from macOS")
        restored.installer.refresh()
        restored.installer.receiveInstalled([entry()], for: restored.requests.last!)
        restored.installer.observeCameraStatus(.sending)
        try check(restored.installer.isReady, "An app restarted during approval can reconcile an enabled camera without a new activation")

        let unresponsive = pendingApproval()
        unresponsive.installer.refresh()
        let timedOutQuery = unresponsive.requests.last!
        unresponsive.drain()
        try check(unresponsive.installer.state == .awaitingApproval && !unresponsive.installer.isCheckingStatus &&
                  unresponsive.installer.message.contains("did not respond"),
                  "An unanswered status query stops checking after a bounded wait and preserves approval recovery")
        unresponsive.installer.refresh()
        let retryQuery = unresponsive.requests.last!
        unresponsive.installer.receiveInstalled([entry()], for: timedOutQuery)
        try check(unresponsive.installer.state == .awaitingApproval && unresponsive.installer.isCheckingStatus,
                  "A timed-out status response cannot overwrite a newer query")
        unresponsive.installer.receiveInstalled([entry()], for: retryQuery)
        unresponsive.installer.request(unresponsive.requests[0], didFinishWithResult: .completed)
        unresponsive.installer.observeCameraStatus(.sending)
        try check(unresponsive.installer.isReady, "The original activation still completes after an inspection timeout")
    }
    static func main() {
        do { try run() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
