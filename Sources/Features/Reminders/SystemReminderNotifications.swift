import UserNotifications

/// Local notifications for reminders created from Katana drafts. Local only (no push/APNs).
/// Touches only identifiers with `ReminderNotificationID.prefix` that it is given — never other
/// notifications of the app (e.g. Capability Lab test notifications).
struct SystemReminderNotifications: ReminderNotificationSystem {
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    func schedule(_ request: ReminderNotificationRequest) async throws {
        guard request.identifier.hasPrefix(ReminderNotificationID.prefix + ".") else { throw CapabilityProbeError.systemError }
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let body = request.body { content.body = body }
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
        } catch {
            throw CapabilityProbeError.systemError
        }
    }

    func removePending(identifier: String) async {
        guard identifier.hasPrefix(ReminderNotificationID.prefix + ".") else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
