// Paused-too-long check-in (B2, spec 10 §1.6). Background idle can't be
// observed server-side, so the client pre-schedules a local notification
// ~14 min after a pause and cancels it on resume/finish; the server cap
// (send-paused-checkin) is coordinated by AppModel.requestPausedCheckin,
// which cancels this when the daily cap / mute / preference disallows.
// Carries the Resume / Snooze / End actions; Snooze re-arms the same
// 14-min check. Gated off entirely on the Calm level.

import Foundation
import UserNotifications

enum PausedCheckinScheduler {
    static let identifier = "unstuck.paused.checkin"
    private static let delay: TimeInterval = 14 * 60

    static func schedule(taskName: String) {
        // Calm disables paused check-ins (NotificationLevel.pausedCheckin).
        guard NotificationPrefs.level.pausedCheckin else { return }
        let content = UNMutableNotificationContent()
        content.title = "Did you step away?"
        content.body = taskName.isEmpty ? "Your focus session is paused." : taskName
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = NotificationCategories.Thread.paused
        content.categoryIdentifier = NotificationCategories.paused
        content.userInfo = [
            "kind": "paused_checkin",
            "deepLink": "unstuck://today",
            "taskName": taskName,
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
