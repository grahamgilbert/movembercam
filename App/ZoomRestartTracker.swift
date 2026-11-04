import AppKit
import Combine
import os

@MainActor
final class ZoomRestartTracker: ObservableObject {
    private static let key = "MovemberCam.zoomCameraRestart.v1"
    private static let logger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "VideoAppRestart")
    @Published private(set) var state: VideoAppRestartState
    @Published private(set) var isLoading = false
    @Published private(set) var isRestarting = false
    @Published private(set) var error: String?
    private var needsOpen = false
    private var seeded = false
    private var stopped = false
    private var metadataGeneration = 0
    private let defaults: UserDefaults
    private let running: @MainActor () -> VideoAppProcess?
    private let providerStarted: @Sendable () -> Date?
    private let now: () -> Date
    private let restart: () async throws -> Void

    init(defaults: UserDefaults = .standard,
         running: @escaping @MainActor () -> VideoAppProcess? = ZoomRestartTracker.runningZoom,
         providerStarted: @escaping @Sendable () -> Date? = { ZoomRestartTracker.providerStartDate() },
         now: @escaping () -> Date = Date.init,
         restart: @escaping () async throws -> Void = ZoomRestartTracker.restartZoom) {
        self.defaults = defaults
        self.running = running
        self.providerStarted = providerStarted
        self.now = now
        self.restart = restart
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(VideoAppRestartState.self, from: $0) } ?? VideoAppRestartState()
    }

    var issue: CameraAttentionIssue? {
        guard state.pending != nil || needsOpen || isRestarting else { return nil }
        return CameraAttentionIssue(kind: .videoAppRestart,
            title: isRestarting ? "Restarting Zoom…" : "Restart Zoom to find MovemberCam",
            message: error ?? "Zoom was open during camera setup and may still have its old camera list. Finish any call, then restart Zoom.",
            recovery: isRestarting ? .showSettings : .restartZoom)
    }

    func cameraWillChange() {
        metadataGeneration += 1
        change { $0.cameraWillChange() }
        Self.logger.notice("Camera registration is changing; tracking existing Zoom processes")
    }

    func refresh(cameraReady: Bool) {
        guard !stopped else { return }
        let current = running()
        change { $0.reconcile(running: current) }
        if current != nil, state.pending == nil, !isRestarting {
            needsOpen = false
            if error != nil { error = nil }
        }
        guard cameraReady else { return }
        if state.awaitingCamera {
            change { $0.cameraBecameAvailable(at: now(), running: current) }
        }
        guard !seeded, !isLoading else { return }
        seeded = true
        isLoading = true
        let read = providerStarted
        let generation = metadataGeneration
        Task {
            let date = await Task.detached { read() }.value
            guard !stopped, generation == metadataGeneration else { isLoading = false; return }
            if let date {
                let current = running()
                Self.logger.notice("Compared camera setup with Zoom: running=\(current != nil, privacy: .public) predatesCamera=\(current.map { $0.launchedAt <= date } ?? false, privacy: .public)")
                change { $0.cameraBecameAvailable(at: date, running: current) }
            }
            else { Self.logger.warning("Could not establish the current camera provider start time") }
            isLoading = false
        }
    }

    func acknowledge() {
        change { $0.acknowledge() }
        needsOpen = false
        error = nil
        Self.logger.notice("User confirmed MovemberCam is listed in Zoom")
    }

    func restartZoomForUser() {
        change { $0.reconcile(running: running()) }
        guard !isRestarting, issue != nil else { return }
        isRestarting = true
        error = nil
        Self.logger.notice("User requested Zoom restart")
        Task {
            do {
                try await restart()
                needsOpen = false
                Self.logger.notice("Zoom reopened successfully")
            } catch {
                self.error = "Zoom could not reopen. Finish any call, close Zoom’s dialogs, then try Restart Zoom again."
                needsOpen = running() == nil
                Self.logger.error("Zoom restart failed code=\((error as NSError).code, privacy: .public)")
            }
            isRestarting = false
            refresh(cameraReady: true)
        }
    }

    func cameraRemoved() {
        metadataGeneration += 1
        change { $0.cameraRemoved() }; needsOpen = false
        if error != nil { error = nil }
    }
    func stop() { stopped = true }

    private func change(_ update: (inout VideoAppRestartState) -> Void) {
        var next = state
        update(&next)
        guard next != state else { return }
        let wasPending = state.pending != nil
        state = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.key)
        if wasPending != (next.pending != nil) {
            Self.logger.notice("Zoom restart needed=\(next.pending != nil, privacy: .public)")
        }
    }

    static func runningZoom() -> VideoAppProcess? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first.flatMap {
            guard let date = $0.launchDate else { return nil }
            return VideoAppProcess(pid: $0.processIdentifier, launchedAt: date)
        }
    }

    /// Read only the matching provider's start time; never retain or log other process metadata.
    nonisolated static func providerStartDate() -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "lstart=,comm="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let suffix = "/\(VideoFormat.extensionIdentifier).systemextension/Contents/MacOS/\(VideoFormat.extensionIdentifier)"
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(suffix) }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: String(line.prefix(24)).trimmingCharacters(in: .whitespaces))
    }

    static func restartZoom() async throws {
        try await restartApplication(bundleIdentifier: "us.zoom.xos", fallbackURL: URL(fileURLWithPath: "/Applications/zoom.us.app"))
    }

    static func restartApplication(bundleIdentifier: String, fallbackURL: URL) async throws {
        let original = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let url = original.first?.bundleURL ?? fallbackURL
        for app in original {
            guard app.terminate() else { throw CocoaError(.userCancelled) }
        }
        let deadline = Date().addingTimeInterval(30)
        // Re-query process identities: a cached NSRunningApplication.isTerminated
        // did not update reliably in the diagnostic CLI. Never force-quit a call.
        while NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains(where: { candidate in original.contains { $0.processIdentifier == candidate.processIdentifier && $0.launchDate == candidate.launchDate } }) {
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
