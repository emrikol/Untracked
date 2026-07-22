import UserNotifications

internal enum Notifier {
    internal static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Fire-and-forget: a denied prompt just means the one-time health
            // warning stays silent. Nothing else depends on the result.
        }
    }

    /// Reusing the same `id` replaces any prior copy, so warnings don't stack.
    internal static func post(
        id: String,
        title: String,
        body: String,
        completion: @escaping @Sendable (Error?) -> Void = { _ in /* caller doesn't care */ }
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil),
            withCompletionHandler: completion
        )
    }
}
