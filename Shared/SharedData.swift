import Foundation

/// What the app hands its widget and share extension. Neither extension can
/// open the message database or the keys: they only see these small files,
/// written by the app, in the App Group container.
///
/// - widget.json: unread count, and (only when notification previews are on
///   and App lock is off) the latest chats with their last message.
/// - share-targets.json: the chats you can share into.
/// - inbox/: things shared from other apps, waiting for the app to send them.
enum SharedFiles {
    /// Posted (Darwin notification) by the share extension when it queued something.
    static let inboxNotification = "com.cellosig.share-inbox"

    static var dir: URL? {
        guard let base = AppGroup.container else { return nil }
        let d = base.appendingPathComponent("cellosig-shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return d
    }

    static var widget: URL? { dir?.appendingPathComponent("widget.json") }
    static var shareTargets: URL? { dir?.appendingPathComponent("share-targets.json") }
    static var inbox: URL? {
        guard let d = dir?.appendingPathComponent("inbox", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// Writes only when the content changed. True if it did.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL?) -> Bool {
        guard let url, let d = try? JSONEncoder().encode(value) else { return false }
        if (try? Data(contentsOf: url)) == d { return false }
        return (try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }
}

struct WidgetData: Codable, Equatable {
    struct Chat: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var text: String
        var ts: Int64
        var unread: Int
    }
    var unread: Int
    /// Empty unless previews are allowed (Settings → notifications) and App lock is off.
    var chats: [Chat]
    var showContent: Bool
}

struct ShareTargets: Codable, Equatable {
    struct Target: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var group: Bool
    }
    var targets: [Target]
    /// App lock is on: the share sheet asks for Face ID / passcode first.
    var locked: Bool
}

/// One share, written by the extension as inbox/<job>/manifest.json (last, so
/// a half-written job is never picked up) next to its files.
struct ShareJob: Codable {
    struct File: Codable {
        var name: String
        var mime: String
        var path: String   // file name inside the job folder
    }
    var conv: String
    var text: String?
    var files: [File]
}

enum ShareLimits {
    static let maxFileBytes: Int64 = 90 * 1024 * 1024
    static let maxFiles = 10
}

/// Links the widget uses to open a chat: cellosig://chat/<conversation id>.
enum AppLinks {
    static func chat(_ conv: String) -> URL? {
        var c = URLComponents()
        c.scheme = "cellosig"
        c.host = "chat"
        c.queryItems = [URLQueryItem(name: "id", value: conv)]
        return c.url
    }

    static func conversation(from url: URL) -> String? {
        guard url.scheme == "cellosig", url.host == "chat" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
