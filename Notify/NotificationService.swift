import CellosigCore
import UserNotifications

/// Runs when the relay's push arrives ("New message", no content). Connects to
/// the relay as this account, collects and decrypts what's waiting (on the
/// phone; Apple only ever saw the content-free push), stores it, confirms it,
/// and turns the push into a real notification.
///
/// What the notification shows follows Settings → "Show sender and message
/// in notifications" (off: just "New message"). Disappearing messages never
/// put their text in a notification.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private var done = false

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        contentHandler = handler
        fallback = request.content.mutableCopy() as? UNMutableNotificationContent
        let info = request.content.userInfo
        Task { @MainActor in await self.fetch(info) }
    }

    /// iOS is about to kill us (about 30 s): show what we have.
    override func serviceExtensionTimeWillExpire() {
        DispatchQueue.main.async { self.finish(self.fallback) }
    }

    @MainActor
    private func fetch(_ info: [AnyHashable: Any]) async {
        _ = RelayAddress.accept(info["r"])   // the relay may have moved; the push says where it is now
        guard let account = Account.load(), let m = try? Messenger(account: account, extensionMode: true) else {
            finish(fallback); return
        }
        var arrived: [(conv: String, sender: String, preview: String)] = []
        m.onIncoming = { arrived.append(($0, $1, $2)) }
        m.start()
        await m.waitUntilQuiet(maxSeconds: 22)
        m.stop()

        let content = fallback ?? UNMutableNotificationContent()
        content.title = "cellosig"
        content.sound = .default
        if arrived.isEmpty {
            content.body = "New message"   // the app picked it up already, or it was a receipt/reaction
        } else {
            let preview = Shared.defaults.bool(forKey: "notify_preview")
            let last = arrived[arrived.count - 1]
            let convs = Set(arrived.map(\.conv))
            content.threadIdentifier = last.conv
            content.userInfo = ["conv": last.conv]
            if preview && convs.count == 1 {
                content.title = m.title(last.conv)
                let line = Messenger.isGroup(last.conv) ? "\(m.displayName(last.sender)): \(last.preview)" : last.preview
                content.body = arrived.count == 1 ? line : "\(line) (+\(arrived.count - 1) more)"
            } else if preview {
                content.body = "\(arrived.count) new messages in \(convs.count) chats"
            } else {
                content.body = arrived.count == 1 ? "New message" : "\(arrived.count) new messages"
            }
        }
        let unread = (try? m.db.scalarInt("SELECT COALESCE(SUM(unread), 0) FROM conversations WHERE request = 0")) ?? 0
        content.badge = NSNumber(value: unread)
        finish(content)
    }

    private func finish(_ content: UNNotificationContent?) {
        guard !done, let handler = contentHandler else { return }
        done = true
        handler(content ?? UNNotificationContent())
    }
}
