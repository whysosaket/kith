import Foundation
import UserNotifications

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let openSession: @Sendable (String) -> Void

    init(openSession: @escaping @Sendable (String) -> Void) {
        self.openSession = openSession
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let key = response.notification.request.content.userInfo["sessionKey"] as? String {
            openSession(key)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
