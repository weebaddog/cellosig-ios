import CellosigCore
import Foundation

struct Message: Identifiable, Equatable {
    var id: Int64
    var conv: String
    var outgoing: Bool
    var body: String
    var ts: Int64
    var status: String          // sending | sent | delivered | read | failed | unregistered | received | read(incoming)
    var msgId: String
    var sender: String?
    var fileName: String?
    var fileMime: String?
    var fileSize: Int64?
    var fileKey: String?
    var fileBlob: String?
    var filePath: String?
    var fileState: String?      // ready | downloading | tap | failed
    var fileKind: String?
    var pollJson: String?
    var expiresInSec: Int
    var expiresAt: Int64?
    var editedAt: Int64?
    var deleted: Bool
    var transcript: String?

    var isSystem: Bool { msgId.hasPrefix(Messenger.systemPrefix) }
    var isImage: Bool { fileMime?.hasPrefix("image/") == true }
    var poll: PollDto? { pollJson.flatMap { try? JSONDecoder().decode(PollDto.self, from: Data($0.utf8)) } }

    init(row r: Row) {
        id = r.int("id") ?? 0
        conv = r.str("conv") ?? ""
        outgoing = r.bool("outgoing")
        body = r.str("body") ?? ""
        ts = r.int("ts") ?? 0
        status = r.str("status") ?? ""
        msgId = r.str("msgId") ?? ""
        sender = r.str("sender")
        fileName = r.str("fileName"); fileMime = r.str("fileMime"); fileSize = r.int("fileSize")
        fileKey = r.str("fileKey"); fileBlob = r.str("fileBlob"); filePath = r.str("filePath")
        fileState = r.str("fileState"); fileKind = r.str("fileKind")
        pollJson = r.str("pollJson")
        expiresInSec = Int(r.int("expiresInSec") ?? 0)
        expiresAt = r.int("expiresAt")
        editedAt = r.int("editedAt")
        deleted = r.bool("deleted")
        transcript = r.str("transcript")
    }
}

struct Conversation: Identifiable, Equatable {
    var id: String
    var lastText: String
    var lastTs: Int64
    var unread: Int
    var request: Bool
    var pinnedAt: Int64?
    var timerSec: Int

    var isGroup: Bool { id.hasPrefix(Messenger.groupPrefix) }

    init(row r: Row) {
        id = r.str("id") ?? ""
        lastText = r.str("lastText") ?? ""
        lastTs = r.int("lastTs") ?? 0
        unread = Int(r.int("unread") ?? 0)
        request = r.bool("request")
        pinnedAt = r.int("pinnedAt")
        timerSec = Int(r.int("timerSec") ?? 0)
    }
}

struct ChatGroup: Equatable {
    var id: String
    var name: String
    var members: [String]
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// When a disappearing message with this timer runs out, if it starts now (nil: no timer).
func expiryFor(_ seconds: Int) -> Int64? { seconds > 0 ? nowMs() + Int64(seconds) * 1000 : nil }
