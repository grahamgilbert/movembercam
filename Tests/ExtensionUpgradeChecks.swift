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
        var suspensions: [Bool] = []
        let defaults: UserDefaults
        init(defaults: UserDefaults = .standard) { self.defaults = defaults }
        lazy var installer: ExtensionInstaller = {
            let value = ExtensionInstaller(bundledVersion: CameraExtensionVersion(release: "1.0.3", build: "10"),
                canInstall: true, submit: { [unowned self] in self.requests.append($0) },
                schedule: { [unowned self] in self.ticks.append($0) }, recoveryDefaults: self.defaults)
            value.prepareForActivation = { [unowned self] completion in self.paused = true; completion() }
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
        try check(!update.installer.blocksCapture && update.suspensions == [true, false],
                  "Leaving installation allows consumer demand to control capture again")
        update.installer.observeCameraStatus(.requiresUpdate)
        try check(!update.installer.isReady, "An extension without demand reporting cannot complete verification")
        update.installer.observeCameraStatus(.cannotOpen(-1))
        try check(!update.installer.isReady, "A connection failure cannot report a successful update")
        update.installer.observeCameraStatus(.idle(isInstalled: true))
        update.drain()
        try check(update.installer.isReady && update.requests.count == 1, "A usable camera completes verification and cancels pending retry timers")
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
        try check(recovery.requests.count == 2 && recovery.installer.state == .installing,
                  "Missing device triggers one delayed registration retry")
        recovery.installer.request(recovery.requests[1], didFinishWithResult: .completed)
        recovery.drain()
        try check(recovery.requests.count == 2 && recovery.installer.state == .unavailable && !recovery.installer.busy,
                  "Failed recovery stops retrying and explains settings and Mac restart recovery")
        recovery.installer.request(recovery.requests[0], didFinishWithResult: .completed)
        try check(recovery.installer.state == .unavailable, "Stale request completions cannot overwrite recovery guidance")
        try check(recovery.installer.recoveryAction == .restartApp, "Unavailable camera offers one app-restart action")
        recovery.installer.noteAppRestart()
        try check(recovery.installer.recoveryAction == .openSettings, "A previous app restart advances to one settings action")
        recovery.installer.observeCameraStatus(.idle(isInstalled: true))
        try check(recovery.installer.isReady && recovery.requests.count == 2,
                  "Late camera discovery clears recovery guidance without another activation")
        print("\(checks) extension upgrade checks passed")
    }
    static func main() {
        do { try run() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
