import CellosigCore
import Foundation

/// What Cindy (the user's assistant on their PC) can do in cellosig while she's switched on (Settings > Cindy).
/// Messages are end-to-end encrypted, so she works through this app's own messenger, never the relay.
enum CindyActions {
    @MainActor static func install() {
        Cindy.shared.configure(id: "cellosig", name: "cellosig", actions: all())
    }

    @MainActor private static func messenger() throws -> Messenger {
        if AppModel.shared.locked { throw CindyError("cellosig is locked (App lock). Unlock it on the iPhone first") }
        guard let m = AppModel.shared.messenger else { throw CindyError("cellosig isn't signed in (or is locked) on this iPhone") }
        return m
    }

    private static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    /// A chat by its name or a phone number; nil if none matches (several matches: an error that names them).
    @MainActor private static func chat(_ m: Messenger, _ who: String) throws -> String? {
        let q = who.trimmingCharacters(in: .whitespaces)
        let convs = m.conversations() + m.conversations(requests: true)
        if let p = phone(m, q), let c = convs.first(where: { $0.id == p }) { return c.id }
        if let c = convs.first(where: { m.title($0.id).caseInsensitiveCompare(q) == .orderedSame }) { return c.id }
        let partial = convs.filter { m.title($0.id).localizedCaseInsensitiveContains(q) }
        if partial.count > 1 { throw CindyError("Several chats match \(q): \(partial.prefix(6).map { m.title($0.id) }.joined(separator: ", "))") }
        return partial.first?.id
    }

    @MainActor private static func phone(_ m: Messenger, _ text: String) -> String? {
        guard text.contains(where: \.isNumber), text.allSatisfy({ $0.isNumber || "+()-. ".contains($0) }) else { return nil }
        return PhoneNumbers.normalize(text, countryCode: m.me.hasPrefix("+1") ? "1" : "")
    }

    @MainActor private static func describe(_ m: Messenger, _ msg: Message) -> String {
        let who = msg.outgoing ? "Me" : msg.sender.map { m.groupMemberName($0) } ?? m.title(msg.conv)
        let what = msg.deleted ? "(deleted)" : msg.fileName.map { "[\($0)] \(msg.body)" } ?? msg.body
        return "\(time(msg.ts))  \(who): \(what)"
    }

    @MainActor static func all() -> [Cindy.Action] {
        [
            Cindy.Action(name: "list_chats", desc: "Recent chats with unread counts and the last message",
                         params: ["limit": "how many, default 15"]) { a in
                let m = try messenger()
                return m.conversations().prefix(min(max(a.int("limit", 15), 1), 50)).map { c in
                    "\(m.title(c.id))\(c.unread > 0 ? " (\(c.unread) unread)" : "")  \(time(c.lastTs)): \(c.lastText.prefix(80))"
                }.joined(separator: "\n").ifEmpty("No chats yet")
            },
            Cindy.Action(name: "read_chat", desc: "Read the latest messages in a chat (marks them read)",
                         params: ["chat": "contact or group name, or phone number", "limit": "how many, default 20"]) { a in
                let m = try messenger()
                guard let conv = try chat(m, a.text("chat")) else { throw CindyError("No chat with \(a.text("chat"))") }
                let msgs = m.messages(conv, limit: min(max(a.int("limit", 20), 1), 100)).filter { !$0.isSystem }
                await m.markRead(conv)
                return "Chat with \(m.title(conv)):\n" + msgs.map { describe(m, $0) }.joined(separator: "\n").ifEmpty("(no messages)")
            },
            Cindy.Action(name: "send_message", desc: "Send a cellosig message",
                         params: ["to": "contact or group name, or phone number", "text": "the message"], risky: true) { a in
                let m = try messenger()
                let text = a.text("text").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { throw CindyError("The message is empty") }
                var conv = try chat(m, a.text("to"))
                if conv == nil, let p = phone(m, a.text("to")) {
                    guard await m.lookup([p]).contains(p) else { throw CindyError("\(PhoneNumbers.pretty(p)) isn't on cellosig") }
                    m.startChat(p)
                    conv = p
                }
                guard let conv else { throw CindyError("No chat with \(a.text("to"))") }
                await m.sendText(conv, text)
                return "Sent to \(m.title(conv))"
            },
            Cindy.Action(name: "search_messages", desc: "Find messages containing some words", params: ["query": "words to look for"]) { a in
                let m = try messenger()
                return m.search(a.text("query"), limit: 25).map { describe(m, $0.msg) + "  (in \(m.title($0.msg.conv)))" }
                    .joined(separator: "\n").ifEmpty("No messages match")
            },
            Cindy.Action(name: "unread", desc: "Chats with unread messages, and what they say") { _ in
                let m = try messenger()
                let chats = m.conversations().filter { $0.unread > 0 }
                if chats.isEmpty { return "Nothing unread" }
                return chats.map { c in
                    "\(m.title(c.id)) (\(c.unread)):\n" + m.messages(c.id, limit: min(c.unread, 10)).filter { !$0.isSystem && !$0.outgoing }
                        .map { "  " + describe(m, $0) }.joined(separator: "\n")
                }.joined(separator: "\n")
            },
            Cindy.Action(name: "connection", desc: "Whether cellosig is connected to its relay") { _ in
                try messenger().connected ? "Connected to the relay" : "Not connected to the relay right now"
            },
        ]
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
