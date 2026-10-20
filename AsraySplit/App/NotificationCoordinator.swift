import Foundation
import UIKit
import UserNotifications

/// Push registration, local reminders, and notification-tap routing.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    var onOpen: ((DeepLink) -> Void)?
    var onToken: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()

    static let reminderPrefix = "daily-reminder-"

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Asks for permission in context (e.g. after creating a first trip), never at launch.
    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await refreshAuthorization()
        return granted
    }

    func didRegister(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        onToken?(hex)
    }

    // MARK: Local reminders

    /// Schedules one "log today's spending" reminder per remaining day of each active trip, at 8pm
    /// in the trip's time zone. Replaces previously scheduled reminders.
    func scheduleDailyReminders(for trips: [Trip], enabled: Bool, now: Date = .now) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled else { return }
        var scheduled = 0
        for trip in trips where !trip.isArchived {
            guard let start = trip.startDate, let end = trip.endDate else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: trip.timezone) ?? .current
            var day = max(calendar.startOfDay(for: start), calendar.startOfDay(for: now))
            while day <= end, scheduled < 60 { // iOS keeps at most 64 pending requests.
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = 20
                components.timeZone = calendar.timeZone
                if let fire = calendar.date(from: components), fire > now {
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "Anything to split today?")
                    content.body = String(localized: "Add today’s \(trip.name) expenses while they’re fresh.")
                    content.sound = .default
                    content.userInfo = ["trip_id": trip.id.uuidString, "kind": "reminder"]
                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    try? await center.add(UNNotificationRequest(identifier: "\(Self.reminderPrefix)\(trip.id.sortKey)-\(Int(fire.timeIntervalSince1970))", content: content, trigger: trigger))
                    scheduled += 1
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
    }

    func cancelAllLocal() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let link = DeepLink.fromNotification(userInfo)
        await MainActor.run {
            if let link { self.onOpen?(link) }
        }
    }
}

/// Bridges UIKit app-delegate callbacks that SwiftUI doesn't expose.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onToken: ((Data) -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.push.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }
}
