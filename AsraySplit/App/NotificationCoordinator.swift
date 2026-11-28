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
    /// Called with the push `kind` when a notification is tapped (used to pick the tab).
    var onOpenKind: ((String) -> Void)?
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

    // MARK: Trip alarm + wake-up reminders

    static let wakePrefix = "trip-wake-"

    /// One scheduled nudge, expressed in the trip's local wall clock (Puerto Rico = AST, no DST).
    struct WakeReminder: Sendable {
        let id: String
        let month, day, hour, minute: Int
        let title, body: String
    }

    /// Night-before "set your alarm" nudges plus morning wake-ups (and a second nudge 5 min later).
    /// These are ordinary notifications, not alarms: they can be silenced by Focus or a muted phone.
    static let puertoRicoWakeReminders: [WakeReminder] = [
        WakeReminder(id: "sat-set", month: 11, day: 27, hour: 21, minute: 0, title: "⏰ Set your alarm", body: "El Yunque day: first wake-up is 8:30 AM, breakfast 9:30, car leaves 10:15."),
        WakeReminder(id: "sat-wake", month: 11, day: 28, hour: 8, minute: 30, title: "☀️ Wake up!", body: "Everyone has to shower. Breakfast at 9:30, drive to El Yunque at 10:15."),
        WakeReminder(id: "sun-set", month: 11, day: 28, hour: 21, minute: 0, title: "⏰ Set your alarm", body: "Icacos day: wake up 8:15 AM. We must be in Fajardo by 11:55 AM."),
        WakeReminder(id: "sun-wake", month: 11, day: 29, hour: 8, minute: 15, title: "☀️ Wake up!", body: "Breakfast 9:30, leave 10:15 for Fajardo. Be there by 11:55 at the latest."),
        WakeReminder(id: "tue-set", month: 11, day: 30, hour: 20, minute: 30, title: "⏰ Set your alarms for tomorrow", body: "Asray, Arjun & Justin wake ~1:45 AM (leave 2:30 AM, flight 5:01). Anoop leaves 6:00 AM."),
        WakeReminder(id: "tue-wake-early", month: 12, day: 1, hour: 1, minute: 45, title: "☀️ Wake up — airport!", body: "Asray, Arjun & Justin: leave for SJU at 2:30 AM. Flight 5:01 AM."),
        WakeReminder(id: "tue-wake-anoop", month: 12, day: 1, hour: 5, minute: 15, title: "☀️ Wake up, Anoop", body: "Leave for the airport at 6:00 AM. Flight 8:30 AM."),
    ]

    /// Replaces all trip wake-up reminders. Pass `enabled: false` to just clear them.
    func scheduleWakeReminders(enabled: Bool, now: Date = .now) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.wakePrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled, authorization == .authorized || authorization == .provisional else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Puerto_Rico") ?? .current
        for reminder in Self.puertoRicoWakeReminders {
            let isWake = reminder.id.contains("wake")
            // Wake-ups repeat 5 minutes later in case the first one is slept through.
            for offset in isWake ? [0, 5] : [0] {
                var parts = DateComponents(year: 2026, month: reminder.month, day: reminder.day, hour: reminder.hour, minute: reminder.minute + offset)
                parts.timeZone = calendar.timeZone
                guard let fire = calendar.date(from: parts), fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = offset == 0 ? reminder.title : "Still asleep? " + reminder.title
                content.body = reminder.body
                content.sound = .default
                content.userInfo = ["kind": "wake_reminder"]
                let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents(in: calendar.timeZone, from: fire), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "\(Self.wakePrefix)\(reminder.id)-\(offset)", content: content, trigger: trigger))
            }
        }
    }

    func cancelAllLocal() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    // Completion-handler variants on purpose: with the `async` variants, iOS 18 runs the completion off the
    // main thread and UIKit aborts (crash in TestFlight build 6 when opening the app from a notification).

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .list, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let link = DeepLink.fromNotification(userInfo)
        let kind = userInfo["kind"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let kind { self.onOpenKind?(kind) }
                if let link, !["chat_message", "announcement", "chat_reaction", "photos_added"].contains(kind ?? "") { self.onOpen?(link) }
            }
            completionHandler()
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
