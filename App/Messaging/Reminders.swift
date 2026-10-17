import CellosigCore
import Foundation
import UserNotifications

/// "Remind me about this message": a local notification at the chosen time.
/// Nothing leaves the phone. What the notification says follows the
/// "Show sender and message in notifications" setting.
struct Reminder: Identifiable, Equatable {
    var id: String
    var conv: String
    var msgRow: Int64?
    var text: String
    var at: Date
}

extension Messenger {
    func addReminder(for msg: Message, at: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        let id = "reminder:" + UUID().uuidString.lowercased()
        let text = msg.body.isEmpty ? Self.preview("", msg.fileMime) : msg.body
        let c = UNMutableNotificationContent()
        c.sound = .default
        c.threadIdentifier = msg.conv
        c.userInfo = ["conv": msg.conv]
        if Shared.defaults.bool(forKey: "notify_preview") && msg.expiresInSec == 0 {
            c.title = "Reminder · \(title(msg.conv))"
            c.body = String(text.prefix(140))
        } else {
            c.title = "Reminder"
            c.body = "You asked to be reminded about a message."
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let req = UNNotificationRequest(identifier: id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        guard (try? await center.add(req)) != nil else { return false }
        try? db.run("INSERT INTO reminders(id, conv, msgRow, text, at) VALUES(?, ?, ?, ?, ?)",
                    id, msg.conv, msg.id, String(text.prefix(200)), Int64(at.timeIntervalSince1970 * 1000))
        touch()
        return true
    }

    /// Upcoming reminders (ones that already went off are cleared out).
    func reminders(conv: String? = nil) -> [Reminder] {
        try? db.run("DELETE FROM reminders WHERE at < ?", nowMs() - 60_000)
        let rows = (conv.map { try? db.query("SELECT * FROM reminders WHERE conv = ? ORDER BY at", $0) }
                    ?? (try? db.query("SELECT * FROM reminders ORDER BY at"))) ?? []
        return rows.map {
            Reminder(id: $0.str("id") ?? "", conv: $0.str("conv") ?? "", msgRow: $0.int("msgRow"), text: $0.str("text") ?? "",
                     at: Date(timeIntervalSince1970: Double($0.int("at") ?? 0) / 1000))
        }
    }

    func cancelReminder(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        try? db.run("DELETE FROM reminders WHERE id = ?", id)
        touch()
    }

    func cancelReminders(conv: String) {
        let ids = reminders(conv: conv).map(\.id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        try? db.run("DELETE FROM reminders WHERE conv = ?", conv)
    }
}
