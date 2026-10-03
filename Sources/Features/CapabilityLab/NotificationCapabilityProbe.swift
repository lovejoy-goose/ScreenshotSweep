import UserNotifications

/// Local notifications adapter. No remote push/APNs. The test notification has neutral
/// text and no user or device data.
struct SystemNotificationAccess: NotificationSystem {
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

    func requestAuthorization() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ request: TestNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: request.delay, repeats: false)
        do {
            try await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
        } catch {
            throw CapabilityProbeError.systemError
        }
    }
}
