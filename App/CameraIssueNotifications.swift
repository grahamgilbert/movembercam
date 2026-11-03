import Foundation
import UserNotifications

@MainActor
protocol CameraIssueNotifying: AnyObject {
    var onOpenSettings: (() -> Void)? { get set }
    var shouldPresent: ((CameraAttentionIssue.Kind) -> Bool)? { get set }
    func authorize() async -> Bool
    func deliver(_ issue: CameraAttentionIssue) async throws
    func clear()
}

@MainActor
final class CameraIssueNotifications: NSObject, CameraIssueNotifying, UNUserNotificationCenterDelegate {
    private static let identifier = "MovemberCam.cameraAttention"
    private static let category = "MovemberCam.cameraRecovery"
    private static let openAction = "MovemberCam.openCameraSettings"
    private let center: UNUserNotificationCenter
    var onOpenSettings: (() -> Void)?
    var shouldPresent: ((CameraAttentionIssue.Kind) -> Bool)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.openAction, title: "Open MovemberCam", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category,
            actions: [action], intentIdentifiers: [], options: [])])
    }

    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return settings.alertSetting == .enabled
        case .notDetermined, .provisional:
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return false }
            return await center.notificationSettings().alertSetting == .enabled
        default: return false
        }
    }

    func deliver(_ issue: CameraAttentionIssue) async throws {
        let content = UNMutableNotificationContent()
        content.title = issue.title
        content.body = issue.message
        content.categoryIdentifier = Self.category
        content.userInfo = ["cameraIssue": issue.kind.rawValue]
        try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clear() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard identifier == Self.identifier,
                  action == UNNotificationDefaultActionIdentifier || action == Self.openAction else { return }
            self?.onOpenSettings?()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let rawKind = notification.request.content.userInfo["cameraIssue"] as? String
        Task { @MainActor [weak self] in
            let kind = rawKind.flatMap(CameraAttentionIssue.Kind.init(rawValue:))
            completionHandler(kind.map { self?.shouldPresent?($0) == true } == true ? [.banner, .list] : [])
        }
    }
}
