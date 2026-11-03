import AppKit
import SwiftUI

@MainActor
final class AppLocationManager: ObservableObject {
    @Published var isOfferingMove = false
    @Published private(set) var isMoving = false
    @Published var error: String?
    private var checked = false
    private let destination = URL(fileURLWithPath: "/Applications/MovemberCam.app", isDirectory: true)

    var isInApplications: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path == "/Applications"
    }
    var replacesExistingCopy: Bool { FileManager.default.fileExists(atPath: destination.path) }

    func checkLocation() {
        guard !checked else { return }
        checked = true
        isOfferingMove = !isInApplications
    }

    func moveAndRestart() {
        guard !isMoving, !isInApplications else { return }
        isMoving = true
        error = nil
        let source = Bundle.main.bundleURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".MovemberCam-\(UUID().uuidString).app", isDirectory: true)
        Task {
            do {
                try FileManager.default.copyItem(at: source, to: staging)
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Preserve the previous installed copy in Trash instead of deleting it.
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                }
                try FileManager.default.moveItem(at: staging, to: destination)
                relaunch(at: destination)
            } catch {
                if FileManager.default.fileExists(atPath: staging.path) {
                    try? FileManager.default.trashItem(at: staging, resultingItemURL: nil)
                }
                self.error = "Couldn’t move MovemberCam: \(error.localizedDescription) You can drag the app to Applications in Finder instead."
                isMoving = false
            }
        }
    }

    @discardableResult
    func restart() -> Bool { restart(showSettings: true, activates: true, cameraRecovery: false) }

    func restart(showSettings: Bool, activates: Bool, cameraRecovery: Bool) -> Bool {
        guard !isMoving else { return false }
        isMoving = true
        return relaunch(at: Bundle.main.bundleURL, showSettings: showSettings,
                        activates: activates, cameraRecovery: cameraRecovery)
    }

    @discardableResult
    private func relaunch(at url: URL, showSettings: Bool = true, activates: Bool = true,
                          cameraRecovery: Bool = false) -> Bool {
        do {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = LaunchBehavior.relaunchArguments(processID: ProcessInfo.processInfo.processIdentifier,
                applicationPath: url.path, showSettings: showSettings,
                activates: activates, cameraRecovery: cameraRecovery)
            relaunch.standardInput = FileHandle.nullDevice
            relaunch.standardOutput = FileHandle.nullDevice
            relaunch.standardError = FileHandle.nullDevice
            try relaunch.run()
            // Leave the Swift task before AppKit enters its termination run loop.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            return true
        } catch {
            self.error = "Couldn’t reopen MovemberCam: \(error.localizedDescription) Open it from Applications to continue."
            isMoving = false
            return false
        }
    }
}
