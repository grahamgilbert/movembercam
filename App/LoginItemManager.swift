import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy, enabled != isEnabled else { return }
        isBusy = true
        error = nil
        Task { @MainActor in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = error.localizedDescription }
            refresh()
            isBusy = false
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct LoginItemControls: View {
    @ObservedObject var manager: LoginItemManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at Login", isOn: Binding(get: { manager.isEnabled }, set: manager.setEnabled))
                .disabled(manager.isBusy)
            Text("Opens MovemberCam in the menu bar. Your camera stays off until you start it.")
                .font(.caption).foregroundStyle(.secondary)
            if manager.status == .requiresApproval {
                Text("Approve MovemberCam in Login Items to finish enabling automatic startup.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items Settings", action: manager.openSettings)
            }
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: manager.refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in manager.refresh() }
    }
}
