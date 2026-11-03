import Foundation
import UserNotifications
import os

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
    private static let logger = Logger(subsystem: "com.grahamgilbert.MovemberCam", category: "Notifications")
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
        Self.logger.notice("Notification authorization=\(settings.authorizationStatus.rawValue, privacy: .public) alerts=\(settings.alertSetting.rawValue, privacy: .public)")
        switch settings.authorizationStatus {
        case .authorized: return settings.alertSetting == .enabled
        case .notDetermined, .provisional:
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return false }
            return await center.notificationSettings().alertSetting == .enabled
        default: return false
        }
    }

    static func content(for issue: CameraAttentionIssue) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = issue.notificationCopy.title
        content.body = issue.notificationCopy.body
        content.categoryIdentifier = Self.category
        content.userInfo = ["cameraIssue": issue.kind.rawValue]
        return content
    }

    func deliver(_ issue: CameraAttentionIssue) async throws {
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: Self.content(for: issue), trigger: nil))
            Self.logger.notice("Notification submitted kind=\(issue.kind.rawValue, privacy: .public)")
        } catch {
            let failure = error as NSError
            Self.logger.error("Notification failed kind=\(issue.kind.rawValue, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
            throw error
        }
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
            Self.logger.notice("Notification opened action=\(action, privacy: .public)")
            self?.onOpenSettings?()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let rawKind = notification.request.content.userInfo["cameraIssue"] as? String
        Task { @MainActor [weak self] in
            let kind = rawKind.flatMap(CameraAttentionIssue.Kind.init(rawValue:))
            let show = kind.map { self?.shouldPresent?($0) == true } == true
            Self.logger.notice("Notification foreground presentation kind=\(rawKind ?? "unknown", privacy: .public) allowed=\(show, privacy: .public)")
            completionHandler(show ? [.banner, .list] : [])
        }
    }
}
