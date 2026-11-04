// Inert services for the opt-in native Settings lifecycle check.
import AppKit
import SwiftUI
@MainActor final class AppUpdater: ObservableObject {
    @Published var automaticallyChecksForUpdates = true
    @Published var includePrereleases = true
    @Published var canCheckForUpdates = true
    @Published var lastUpdateCheckDate: Date? = nil
    func checkForUpdates() {}
}
@MainActor final class AppLocationManager: ObservableObject {
    @Published var isOfferingMove = false
    @Published var isMoving = false
    @Published var error: String? = nil
    let isInApplications = true
    let replacesExistingCopy = false
    func checkLocation() {}
    func moveAndRestart() {}
    @discardableResult func restart() -> Bool { false }
    @discardableResult func restart(showSettings: Bool, activates: Bool, cameraRecovery: Bool) -> Bool { false }
}
@MainActor final class QuietNotifications: CameraIssueNotifying {
    var onOpenSettings: (() -> Void)?
    var onRecover: ((CameraAttentionIssue.Kind) -> Void)?
    var shouldPresent: ((CameraAttentionIssue.Kind) -> Bool)?
    func authorize() async -> Bool { false }
    func deliver(_ issue: CameraAttentionIssue) async throws {}
    func clear() {}
}
struct UpdateControls: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatically check for updates every hour", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Install prerelease versions", isOn: $updater.includePrereleases)
            HStack {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                if let date = updater.lastUpdateCheckDate {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
}
