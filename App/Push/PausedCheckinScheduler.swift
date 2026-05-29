// Paused-too-long nudge. Background idle can't be observed server-side, so
// the client pre-schedules a local notification ~14 min after a pause and
// cancels it on resume/finish. (The cap is coordinated with the server via
// send-paused-checkin when online — a follow-up call.)

import Foundation
import UserNotifications

enum PausedCheckinScheduler {
    static let identifier = "unstuck.paused.checkin"
    private static let delay: TimeInterval = 14 * 60

    static func schedule(taskName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Still on it?"
        content.body = taskName.isEmpty
            ? "Your focus session is paused — resume, or wrap it up?"
            : "\"\(taskName)\" is paused — resume, or wrap it up?"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
