import Foundation

/// What a backup holds, read (and checked end to end) before anything is replaced.
public struct BackupInfo: Equatable {
    public let phone: String
    public let made: Date
    public let app: String
    public let counts: [String: Int]
    public let files: Set<String>   // "attachments/<name>", "profiles/<name>", "profile/<name>", "stickers/<name>"
    public var messages: Int { counts["messages"] ?? 0 }
    public var chats: Int { counts["conversations"] ?? 0 }
}

/// Writes a backup in the order every cellosig app expects (see `BackupFormat`).
public final class BackupWriter {
    public static let dirs = ["attachments", "profiles", "profile", "stickers"]
    private let sealer: ChunkedAead.Sealer
    private let zip: StoredZipWriter
    private var counts: [String: Int] = ["messages": 0]
    private var pages = 0
    private var files = 0
    private var bytes: Int64 = 0

    public init(passphrase: String, phone: String, app: String, iterations: Int = BackupFormat.iterations,
                sink: @escaping (Data) throws -> Void) throws {
        let sealer = try BackupFormat.seal(passphrase: passphrase, iterations: iterations, sink: sink)
        self.sealer = sealer
        zip = StoredZipWriter { try sealer.write($0) }
        let manifest: [String: Any] = ["kind": BackupFormat.kind, "v": 1, "made": Int64(Date().timeIntervalSince1970 * 1000),
                                       "phone": phone, "app": app, "db": 12]
        try zip.add("backup.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
    }

    /// One page of messages (this app's rows), up to 500; call in order.
    public func messages(_ rows: [[String: Any]]) throws {
        guard !rows.isEmpty else { return }
        pages += 1
        try zip.add("db/messages-" + String(format: "%05ld", pages) + ".jsonl", try lines(BackupRows.messages, rows))
        counts["messages", default: 0] += rows.count
    }

    /// A whole other table (after all the messages).
    public func table(_ t: BackupRows.Table, _ rows: [[String: Any]]) throws {
        try zip.add("db/\(t.backup).jsonl", try lines(t, rows))
        counts[t.backup] = rows.count
    }

    private func lines(_ t: BackupRows.Table, _ rows: [[String: Any]]) throws -> Data {
        var out = Data()
        for r in rows { out += try BackupRows.line(t, r); out.append(UInt8(ascii: "\n")) }
        return out
    }

    /// A file (plain bytes as they should come back: attachments still encrypted, pictures as pictures).
    public func file(dir: String, name: String, data: Data) throws {
        precondition(Self.dirs.contains(dir))
        try zip.add("files/\(dir)/\(name)", data)
        files += 1
        bytes += Int64(data.count)
    }

    /// A big file from disk, in pieces (read twice: once for its checksum).
    public func file(dir: String, name: String, url: URL) throws {
        precondition(Self.dirs.contains(dir))
        var crc = CRC32()
        var size = 0
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        while let d = try h.read(upToCount: 256 * 1024), !d.isEmpty { crc.update(d); size += d.count }
        try h.seek(toOffset: 0)
        try zip.begin("files/\(dir)/\(name)", size: size, crc: crc.value)
        var left = size
        while left > 0, let d = try h.read(upToCount: min(left, 256 * 1024)), !d.isEmpty { try zip.write(d); left -= d.count }
        guard left == 0 else { throw BackupFormat.Failure.unreadable("\(name) changed while it was being backed up") }
        files += 1
        bytes += Int64(size)
    }

    /// Ends the backup; returns (messages, files, bytes).
    @discardableResult
    public func finish() throws -> (messages: Int, files: Int, bytes: Int64) {
        let end: [String: Any] = ["counts": counts, "files": files, "bytes": bytes]
        try zip.add("end.json", try JSONSerialization.data(withJSONObject: end, options: [.sortedKeys]))
        try zip.finish()
        try sealer.finish()
        return (counts["messages"] ?? 0, files, bytes)
    }
}

/// Reads backups made by any cellosig app.
public enum BackupReader {
    static let fileName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$")
    static let ownProfileFiles: Set<String> = ["name.txt", "me.jpg", "set"]

    /// "files/attachments/x" -> ("attachments", "x"), or nil if a backup may not hold it.
    public static func checkedFile(_ entry: String) -> (dir: String, name: String)? {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "files", BackupWriter.dirs.contains(parts[1]) else { return nil }
        let name = parts[2]
        guard fileName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { return nil }
        if parts[1] == "profile", !ownProfileFiles.contains(name) { return nil }
        return (parts[1], name)
    }

    private static func manifest(_ d: Data) throws -> (phone: String, made: Date, app: String) {
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], o["kind"] as? String == BackupFormat.kind,
              let phone = o["phone"] as? String else { throw BackupFormat.Failure.notABackup }
        if ((o["v"] as? NSNumber)?.intValue ?? 1) > 1 || ((o["db"] as? NSNumber)?.intValue ?? 12) > 12 { throw BackupFormat.Failure.newer }
        let made = Date(timeIntervalSince1970: ((o["made"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        return (phone, made, o["app"] as? String ?? "")
    }

    /// Read a whole backup and check every byte (and the code) without changing anything.
    public static func inspect(passphrase: String, read: @escaping (Int) throws -> Data) throws -> BackupInfo {
        let plain = try BackupFormat.open(passphrase: passphrase, read: read)
        let zip = StoredZipReader { try plain.read($0) }
        var m: (phone: String, made: Date, app: String)?
        var counts: [String: Int]?
        var files = Set<String>()
        var first = true
        while let e = try zip.next() {
            if counts != nil { throw BackupFormat.Failure.unreadable("The backup has something after its end.") }
            if e.name == "backup.json" { m = try manifest(try zip.readAll()) }
            else if first { throw BackupFormat.Failure.notABackup }
            else if e.name == "end.json" {
                let o = try JSONSerialization.jsonObject(with: try zip.readAll()) as? [String: Any]
                counts = ((o?["counts"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
            } else {
                if e.name.hasPrefix("files/") {
                    guard let f = checkedFile(e.name) else { throw BackupFormat.Failure.unreadable("Unexpected file in the backup: \(e.name)") }
                    files.insert("\(f.dir)/\(f.name)")
                }
                while !(try zip.read(256 * 1024)).isEmpty {}
            }
            first = false
        }
        // On to the very end, so the last chunk (which says it's the last) is checked too.
        while !(try plain.read(256 * 1024)).isEmpty {}
        guard let m else { throw BackupFormat.Failure.notABackup }
        guard let counts else { throw BackupFormat.Failure.incomplete }
        return BackupInfo(phone: m.phone, made: m.made, app: m.app, counts: counts, files: files)
    }

    /// Hand over a backup's contents in order: rows table by table (this app's columns, up to
    /// 500 at a time), then each file (read its bytes from the reader passed). Check it with
    /// `inspect` first: this doesn't stop to verify before handing things over.
    public static func read(passphrase: String, read: @escaping (Int) throws -> Data,
                            rows: (BackupRows.Table, [[String: Any?]]) throws -> Void,
                            file: (_ dir: String, _ name: String, _ content: StoredZipReader) throws -> Void) throws {
        let plain = try BackupFormat.open(passphrase: passphrase, read: read)
        let zip = StoredZipReader { try plain.read($0) }
        while let e = try zip.next() {
            if e.name.hasPrefix("db/"), e.name.hasSuffix(".jsonl") {
                let t: BackupRows.Table?
                if e.name.hasPrefix("db/messages") { t = BackupRows.messages }
                else { t = BackupRows.tables.first { "db/\($0.backup).jsonl" == e.name } }
                guard let t else { continue }   // a table this build doesn't know
                var batch: [[String: Any?]] = []
                for line in BackupRows.lines(try zip.readAll()) {
                    batch.append(try BackupRows.row(t, line))
                    if batch.count == 500 { try rows(t, batch); batch.removeAll() }
                }
                if !batch.isEmpty { try rows(t, batch) }
            } else if let f = checkedFile(e.name) {
                try file(f.dir, f.name, zip)
            }
        }
    }
}
