import Foundation
import KithCore
import UserNotifications

enum KithNotification {
    static let openAction = "kith.open"

    static func category(for surface: AgentSurface) -> String { "kith.session.\(surface.rawValue)" }

    /// One category per surface so the button names where it opens, like "Open terminal".
    static var categories: Set<UNNotificationCategory> {
        Set(AgentSurface.allCases.map { surface in
            UNNotificationCategory(
                identifier: category(for: surface),
                actions: [UNNotificationAction(identifier: openAction,
                                               title: surface.openActionTitle,
                                               options: .foreground)],
                intentIdentifiers: [])
        })
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let openSession: @Sendable (String) -> Void

    init(openSession: @escaping @Sendable (String) -> Void) {
        self.openSession = openSession
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let opens = [UNNotificationDefaultActionIdentifier, KithNotification.openAction]
            .contains(response.actionIdentifier)
        if opens, let key = response.notification.request.content.userInfo["sessionKey"] as? String {
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
