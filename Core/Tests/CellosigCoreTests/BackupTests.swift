@testable import CellosigCore
import Foundation
import XCTest

/// Chat backups: the format, and files made by the Android app (Interop/fixtures/android.cellobackup,
/// written by its ChatBackupTest) — plus one made here for the Android tests to restore
/// (written to $CELLOSIG_BACKUP_OUT/ios.cellobackup when that's set).
final class BackupTests: XCTestCase {
    let code = BackupFormat.newPassphrase()
    let fast = 1_000

    private func reader(_ d: Data) -> (Int) throws -> Data {
        var pos = 0
        return { n in
            let end = min(pos + n, d.count)
            defer { pos = end }
            return d.subdata(in: pos..<end)
        }
    }

    private func sealed(_ plain: Data, finish: Bool = true) throws -> Data {
        var out = Data()
        let s = try BackupFormat.seal(passphrase: code, iterations: fast) { out += $0 }
        try s.write(plain)
        if finish { try s.finish() }
        return out
    }

    private func opened(_ blob: Data, _ pass: String? = nil) throws -> Data {
        let o = try BackupFormat.open(passphrase: pass ?? code, read: reader(blob))
        var out = Data()
        while true { let d = try o.read(10_000); if d.isEmpty { return out }; out += d }
    }

    func testPassphrases() {
        XCTAssertEqual(code.count, 30)
        XCTAssertEqual(BackupFormat.normalize(BackupFormat.pretty(code)), code)
        XCTAssertNil(BackupFormat.normalize(String(code.dropLast())))
        XCTAssertNil(BackupFormat.normalize(code + "x"))
    }

    func testStreamsMatchTheAttachmentFormat() throws {
        let key = Primitives.randomBytes(32), c = ChunkedAead.chunk
        for n in [0, 1, c - 1, c, c + 1, 3 * c, 3 * c + 5] {
            let pt = Primitives.randomBytes(n)
            var a = Data()
            let s = try ChunkedAead.Sealer(key: key) { a += $0 }
            try s.write(pt.prefix(n / 2)); try s.write(pt.suffix(from: n / 2)); try s.finish()
            XCTAssertEqual(try ChunkedAead.decrypt(a, key: key), pt, "n=\(n)")
            let b = try ChunkedAead.encrypt(pt, key: key)
            let o = try ChunkedAead.Opener(key: key, source: reader(b))
            var got = Data()
            while true { let d = try o.read(7_777); if d.isEmpty { break }; got += d }
            XCTAssertEqual(got, pt, "n=\(n)")
        }
    }

    func testRejectsWrongCodeTamperingAndCutShortFiles() throws {
        let c = ChunkedAead.chunk
        let pt = Primitives.randomBytes(5 * c + 99)
        let blob = try sealed(pt)
        XCTAssertEqual(try opened(blob), pt)
        XCTAssertThrowsError(try opened(blob, BackupFormat.newPassphrase())) { XCTAssertEqual($0 as? BackupFormat.Failure, .wrongPassphrase) }
        XCTAssertThrowsError(try opened(Data("hello, not a backup at all".utf8))) { XCTAssertEqual($0 as? BackupFormat.Failure, .notABackup) }
        var t = blob; let i = 29 + 16 + 2 * (c + 16) + 7; t[i] ^= 1
        XCTAssertThrowsError(try opened(t))
        XCTAssertThrowsError(try opened(blob.prefix(29 + 16 + 3 * (c + 16))))
        XCTAssertThrowsError(try opened(blob.prefix(blob.count - 3)))
        XCTAssertThrowsError(try opened(try sealed(pt, finish: false)))
        var weak = blob; weak[9] = 0; weak[10] = 0; weak[11] = 0; weak[12] = 1
        XCTAssertThrowsError(try opened(weak)) { XCTAssertEqual($0 as? BackupFormat.Failure, .badHeader) }
    }

    func testStoredZip() throws {
        var out = Data()
        let w = StoredZipWriter { out += $0 }
        try w.add("a.txt", Data("hello".utf8))
        try w.add("empty", Data())
        try w.finish()
        let r = StoredZipReader(reader(out))
        XCTAssertEqual(try r.next()?.name, "a.txt"); XCTAssertEqual(try r.readAll(), Data("hello".utf8))
        XCTAssertEqual(try r.next()?.name, "empty"); XCTAssertEqual(try r.readAll(), Data())
        XCTAssertNil(try r.next())
        // A changed byte fails its checksum.
        var bad = out; bad[30 + 5] ^= 1
        let r2 = StoredZipReader(reader(bad))
        _ = try r2.next()
        XCTAssertThrowsError(try r2.readAll())
    }

    // MARK: Between platforms

    /// The sample in this app's columns (the Android test has the same one in its own).
    private func writeSample(_ w: BackupWriter) throws {
        let att = "/var/mobile/x/attachments/A1"
        try w.messages([
            ["id": Int64(1), "conv": "+15550001", "outgoing": Int64(0), "body": "hello", "ts": Int64(1000), "status": "read", "msgId": "m1",
             "fileName": "a.jpg", "fileMime": "image/jpeg", "fileSize": Int64(16), "filePath": att, "fileKey": "a2V5", "fileState": "ready",
             "expiresInSec": Int64(0), "deleted": Int64(0)],
            ["id": Int64(2), "conv": "+15550001", "outgoing": Int64(1), "body": "how are you", "ts": Int64(2000), "status": "read", "msgId": "m2",
             "editedAt": Int64(2500), "expiresInSec": Int64(0), "deleted": Int64(0)],
        ])
        try w.messages([
            ["id": Int64(3), "conv": "g:grp1", "outgoing": Int64(0), "body": "group hi", "ts": Int64(3000), "status": "read", "msgId": "m3",
             "sender": "+15550002", "expiresInSec": Int64(0), "deleted": Int64(0)],
        ])
        let rows: [String: [[String: Any]]] = [
            "conversations": [["id": "+15550001", "lastText": "how are you", "lastTs": Int64(2000), "unread": Int64(0), "request": Int64(0), "pinnedAt": Int64(9), "timerSec": Int64(0), "shield": Int64(0)],
                              ["id": "g:grp1", "lastText": "group hi", "lastTs": Int64(3000), "unread": Int64(0), "request": Int64(0), "timerSec": Int64(0), "shield": Int64(1)]],
            "chat_groups": [["id": "grp1", "name": "Friends", "members": "+15550001,+15550002,+15551234"]],
            "receipts": [["msgId": "m2", "member": "+15550001", "kind": "read"]],
            "reactions": [["msgId": "m1", "member": "+15550002", "emoji": "👍", "ts": Int64(1500)]],
            "votes": [["msgId": "m3", "member": "+15550001", "choices": "0,2"]],
            "reminders": [["id": "reminder:abc", "conv": "+15550001", "msgRow": Int64(1), "text": "hello", "at": Int64(4_102_444_800_000)]],
            "profiles": [["phone": "+15550001", "name": "Ann", "photo": "/var/mobile/x/profiles/p1.img"]],
            "blocked": [["phone": "+15559999", "at": Int64(1300)]],
        ]
        for t in BackupRows.tables { try w.table(t, rows[t.backup] ?? []) }
        try w.file(dir: "attachments", name: "A1", data: Data("attachment-bytes".utf8))
        try w.file(dir: "profiles", name: "p1.img", data: Data("face".utf8))
        try w.file(dir: "profile", name: "name.txt", data: Data("Me".utf8))
        try w.file(dir: "profile", name: "set", data: Data("1".utf8))
        try w.file(dir: "stickers", name: "s1.png", data: Data("png".utf8))
        try w.finish()
    }

    /// Restores `blob` into memory and checks it holds the sample (from whichever app made it).
    private func checkSample(_ blob: Data, _ pass: String) throws {
        let info = try BackupReader.inspect(passphrase: pass, read: reader(blob))
        XCTAssertEqual(info.phone, "+15551234")
        XCTAssertEqual(info.messages, 3)
        XCTAssertEqual(info.chats, 2)
        XCTAssertEqual(info.files, ["attachments/A1", "profiles/p1.img", "profile/name.txt", "profile/set", "stickers/s1.png"])
        var tables: [String: [[String: Any?]]] = [:]
        var files: [String: Data] = [:]
        try BackupReader.read(passphrase: pass, read: reader(blob),
                              rows: { t, r in tables[t.ios, default: []] += r },
                              file: { d, n, z in files["\(d)/\(n)"] = try z.readAll() })
        func v(_ r: [String: Any?], _ k: String) -> Any? { r[k] ?? nil }
        let msgs = (tables["messages"] ?? []).sorted { (v($0, "ts") as? Int64 ?? 0) < (v($1, "ts") as? Int64 ?? 0) }
        XCTAssertEqual(msgs.map { v($0, "body") as? String }, ["hello", "how are you", "group hi"])
        XCTAssertEqual(v(msgs[0], "conv") as? String, "+15550001")
        XCTAssertEqual(v(msgs[0], "outgoing") as? Int64, 0)
        XCTAssertEqual((v(msgs[0], "filePath") as? String).map { ($0 as NSString).lastPathComponent }, "A1")
        XCTAssertEqual(v(msgs[0], "fileKey") as? String, "a2V5")
        XCTAssertEqual(v(msgs[0], "fileSize") as? Int64, 16)
        XCTAssertEqual(v(msgs[1], "outgoing") as? Int64, 1)
        XCTAssertEqual(v(msgs[1], "editedAt") as? Int64, 2500)
        XCTAssertEqual(v(msgs[2], "sender") as? String, "+15550002")
        let convs = tables["conversations"] ?? []
        XCTAssertEqual(v(convs.first { v($0, "id") as? String == "+15550001" }!, "pinnedAt") as? Int64, 9)
        XCTAssertEqual(v(convs.first { v($0, "id") as? String == "g:grp1" }!, "shield") as? Int64, 1)
        XCTAssertEqual(v(tables["groups"]![0], "members") as? String, "+15550001,+15550002,+15551234")
        XCTAssertEqual(v(tables["receipts"]![0], "kind") as? String, "read")
        XCTAssertEqual(v(tables["reactions"]![0], "emoji") as? String, "👍")
        XCTAssertEqual(v(tables["votes"]![0], "choices") as? String, "0,2")
        XCTAssertEqual(v(tables["reminders"]![0], "at") as? Int64, 4_102_444_800_000)
        XCTAssertEqual(v(tables["reminders"]![0], "msgRow") as? Int64, 1)
        XCTAssertEqual(v(tables["profiles"]![0], "name") as? String, "Ann")
        XCTAssertEqual(v(tables["blocked"]![0], "at") as? Int64, 1300)
        XCTAssertEqual(files["attachments/A1"], Data("attachment-bytes".utf8))
        XCTAssertEqual(files["profiles/p1.img"], Data("face".utf8))
        XCTAssertEqual(files["profile/name.txt"], Data("Me".utf8))
        XCTAssertEqual(files["stickers/s1.png"], Data("png".utf8))
    }

    func testSampleRoundTripsAndIsWrittenForAndroid() throws {
        var blob = Data()
        try writeSample(try BackupWriter(passphrase: code, phone: "+15551234", app: "test", iterations: fast) { blob += $0 })
        try checkSample(blob, code)
        if let dir = ProcessInfo.processInfo.environment["CELLOSIG_BACKUP_OUT"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try blob.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios.cellobackup"))
            try Data(code.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios.code"))
        }
    }

    func testRestoresTheAndroidAppsBackup() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Interop/fixtures").standardized
        let blob = try Data(contentsOf: dir.appendingPathComponent("android.cellobackup"))
        let pass = String(decoding: try Data(contentsOf: dir.appendingPathComponent("android.code")), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try checkSample(blob, pass)
    }
}
