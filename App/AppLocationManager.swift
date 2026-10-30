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
                await relaunch(at: destination)
            } catch {
                if FileManager.default.fileExists(atPath: staging.path) {
                    try? FileManager.default.trashItem(at: staging, resultingItemURL: nil)
                }
                self.error = "Couldn’t move MovemberCam: \(error.localizedDescription) You can drag the app to Applications in Finder instead."
                isMoving = false
            }
        }
    }

    func restart() { Task { await relaunch(at: Bundle.main.bundleURL) } }

    private func relaunch(at url: URL) async {
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = [NSApp.keyWindow?.title == "MovemberCam Setup" ? "--show-setup" : "--show-settings"]
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Leave the Swift task before AppKit enters its termination run loop.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        } catch {
            self.error = "Couldn’t reopen MovemberCam: \(error.localizedDescription) Open it from Applications to continue."
            isMoving = false
        }
    }
}
