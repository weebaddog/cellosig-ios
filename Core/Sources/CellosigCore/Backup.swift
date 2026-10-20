import CommonCrypto
import CryptoKit
import Foundation

/// Chat backup files (".cellobackup"), the same as the Android app's (data/BackupFormat.kt there),
/// so a backup made on either can be restored on either:
///
///   "CELLOBAK" || version (1 byte, = 1) || iterations (u32 BE) || salt (16 bytes)
///   || a ChunkedAead ("CSv2") stream to the end of the file, keyed with
///      PBKDF2-HMAC-SHA256(the 30 digits as ASCII, salt, iterations, 32 bytes).
///
/// Inside: a zip whose entries are all STORED (size and CRC-32 in each local header), in order:
///   backup.json, db/messages-NNNNN.jsonl (500 a piece), db/<table>.jsonl, files/<dir>/<name>, end.json.
/// Rows use the Android app's column names ([BackupRows] maps them to this app's tables).
public enum BackupFormat {
    public static let magic = Data("CELLOBAK".utf8)
    public static let version: UInt8 = 1
    public static let iterations = 200_000
    public static let digits = 30
    public static let kind = "cellosig-backup"

    public enum Failure: Error, LocalizedError, Equatable {
        case wrongPassphrase, notABackup, newer, badHeader, damaged, incomplete, unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .wrongPassphrase: return "That isn't this backup's code."
            case .notABackup: return "This isn't a cellosig backup."
            case .newer: return "This backup was made by a newer cellosig. Update the app first."
            case .badHeader: return "This backup's header is damaged."
            case .damaged: return "The backup file was changed or is damaged."
            case .incomplete: return "This backup is incomplete (it stopped part-way)."
            case .unreadable(let why): return why
            }
        }
    }

    /// 30 random digits (about 100 bits).
    public static func newPassphrase() -> String {
        var rng = SystemRandomNumberGenerator()   // (the system's secure generator)
        return String((0..<digits).map { _ in Character(String(Int.random(in: 0...9, using: &rng))) })
    }

    /// The digits typed, ignoring spaces and dashes; nil unless exactly 30.
    public static func normalize(_ typed: String) -> String? {
        guard typed.allSatisfy({ ("0"..."9").contains($0) || $0 == " " || $0 == "-" }) else { return nil }
        let d = typed.filter { ("0"..."9").contains($0) }
        return d.count == digits ? d : nil
    }

    /// "12345 67890 …" for writing down.
    public static func pretty(_ passphrase: String) -> String {
        var groups: [String] = []
        var s = Substring(passphrase)
        while !s.isEmpty { groups.append(String(s.prefix(5))); s = s.dropFirst(5) }
        return groups.joined(separator: " ")
    }

    /// Writes the header to `sink` and returns where to write the zip; call `finish()` at the end.
    public static func seal(passphrase: String, iterations: Int = iterations, sink: @escaping (Data) throws -> Void) throws -> ChunkedAead.Sealer {
        let salt = Primitives.randomBytes(16)
        try sink(magic + Data([version]) + Data.u32(iterations) + salt)
        return try ChunkedAead.Sealer(key: try key(passphrase, salt, iterations), sink: sink)
    }

    /// The zip inside a backup; `read(n)` gives up to n bytes of the file (empty at its end).
    /// Throws `.wrongPassphrase` / `.notABackup` straight away.
    public static func open(passphrase: String, read: @escaping (Int) throws -> Data) throws -> ChunkedAead.Opener {
        var head = Data()
        while head.count < 29 {
            let d = try read(29 - head.count)
            if d.isEmpty { throw head.count < magic.count ? Failure.notABackup : Failure.badHeader }
            head += d
        }
        let b = [UInt8](head)
        guard Data(b[0..<8]) == magic else { throw Failure.notABackup }
        guard b[8] == version else { throw Failure.newer }
        let iterations = Int(b[9]) << 24 | Int(b[10]) << 16 | Int(b[11]) << 8 | Int(b[12])
        // (A crafted file can't make the phone spin for hours, or skip the stretching.)
        guard (1_000...5_000_000).contains(iterations) else { throw Failure.badHeader }
        do {
            return try ChunkedAead.Opener(key: try key(passphrase, Data(b[13..<29]), iterations), source: read)
        } catch is CryptoKitError {
            throw Failure.wrongPassphrase
        }
    }

    static func key(_ passphrase: String, _ salt: Data, _ iterations: Int) throws -> Data {
        let pass = [Int8](passphrase.utf8.map { Int8(bitPattern: $0) })
        let saltBytes = [UInt8](salt)
        guard !pass.isEmpty else { throw Failure.wrongPassphrase }
        var out = [UInt8](repeating: 0, count: 32)
        let rc: Int32 = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, pass.count, saltBytes, saltBytes.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        guard rc == Int32(kCCSuccess) else { throw Failure.unreadable("key derivation failed") }
        return Data(out)
    }
}

// MARK: - Streaming chunks

extension ChunkedAead {
    /// The same format as `encrypt`, for writers that push bytes. Only `finish()` writes the
    /// final chunk, so output that stopped part-way never passes for a whole file.
    public final class Sealer {
        private let sink: (Data) throws -> Void
        private let key: Data
        private let prefix = Primitives.randomBytes(8)
        private var buf = Data()
        private var index = 0
        private var finished = false

        public init(key: Data, sink: @escaping (Data) throws -> Void) throws {
            self.key = key
            self.sink = sink
            try sink(ChunkedAead.magic + Data.u32(ChunkedAead.chunk) + prefix)
        }

        public func write(_ data: Data) throws {
            precondition(!finished, "already finished")
            var rest = data[...]
            while !rest.isEmpty {
                // A full chunk is only sealed once more data shows it isn't the last.
                if buf.count == ChunkedAead.chunk {
                    try sink(try ChunkedAead.seal(key, prefix, index, false, buf))
                    index += 1
                    buf.removeAll(keepingCapacity: true)
                }
                let take = min(rest.count, ChunkedAead.chunk - buf.count)
                buf.append(contentsOf: rest.prefix(take))
                rest = rest.dropFirst(take)
            }
        }

        public func finish() throws {
            guard !finished else { return }
            finished = true
            try sink(try ChunkedAead.seal(key, prefix, index, true, buf))
        }
    }

    /// Reads what `Sealer` / `encrypt` wrote. Every byte handed out is authenticated, and the
    /// stream only ends where the writer's last chunk says it ends. A wrong key fails in `init`.
    public final class Opener {
        private let source: (Int) throws -> Data
        private let key: Data
        private var size = 0
        private var prefix = Data()
        private var index = 0
        private var cur = Data()
        private var plain = Data()
        private var pos = 0
        private var done = false

        public init(key: Data, source: @escaping (Int) throws -> Data) throws {
            self.key = key
            self.source = source
            let header = try full(16)
            guard header.count == 16 else { throw Failure.truncated }
            guard header.prefix(4) == ChunkedAead.magic else { throw Failure.notChunked }
            let b = [UInt8](header)
            size = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
            guard size > 0, size <= ChunkedAead.maxChunk else { throw Failure.badChunkSize }
            prefix = Data(b[8..<16])
            cur = try full(size + ChunkedAead.tag)
            guard cur.count >= ChunkedAead.tag else { throw Failure.truncated }
            try openNext()
        }

        private func full(_ n: Int) throws -> Data {
            var out = Data()
            while out.count < n {
                let d = try source(n - out.count)
                if d.isEmpty { break }
                out += d
            }
            return out
        }

        private func openNext() throws {
            let next = cur.count == size + ChunkedAead.tag ? try full(size + ChunkedAead.tag) : Data()
            let final = next.isEmpty
            plain = Data(try ChunkedAead.open(key, prefix, index, final, cur))
            pos = 0
            if final { done = true; return }
            guard next.count >= ChunkedAead.tag else { throw Failure.truncated }
            cur = next
            index += 1
        }

        /// Up to `n` bytes; empty only at the true end.
        public func read(_ n: Int) throws -> Data {
            while pos == plain.count {
                if done { return Data() }
                do { try openNext() } catch { throw BackupFormat.Failure.damaged }
            }
            let take = min(n, plain.count - pos)
            defer { pos += take }
            return plain.subdata(in: pos..<(pos + take))
        }
    }
}

// MARK: - CRC-32 and stored zips

public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private var state: UInt32 = 0xFFFF_FFFF
    public init() {}
    public mutating func update(_ d: Data) {
        var c = state
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = Self.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        state = c
    }
    public var value: UInt32 { state ^ 0xFFFF_FFFF }
    public static func of(_ d: Data) -> UInt32 { var c = CRC32(); c.update(d); return c.value }
}

/// Writes a zip with every entry stored, sizes and CRC up front (what Java's ZipInputStream,
/// and so the Android app, reads front to back).
public final class StoredZipWriter {
    private let out: (Data) throws -> Void
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0

    public init(_ out: @escaping (Data) throws -> Void) { self.out = out }

    private func emit(_ d: Data) throws { try out(d); offset += UInt64(d.count) }

    public func add(_ name: String, _ data: Data) throws {
        try begin(name, size: data.count, crc: CRC32.of(data))
        try emit(data)
    }

    /// Start an entry whose `size` bytes then come through `write` (a large file, in pieces).
    public func begin(_ name: String, size: Int, crc: UInt32) throws {
        precondition(size < 0xFFFF_FFFF)
        let n = Data(name.utf8)
        var common = Data()
        common.le16(0x0800)              // flags: name is UTF-8
        common.le16(0)                   // stored
        common.le16(0); common.le16(0x21) // 1980-01-01 00:00
        common.le32(crc); common.le32(UInt32(size)); common.le32(UInt32(size))
        common.le16(UInt16(n.count)); common.le16(0)
        var local = Data(); local.le32(0x0403_4B50); local.le16(10)
        try emit(local + common + n)
        var c = Data(); c.le32(0x0201_4B50); c.le16(20); c.le16(10)
        c += common
        c.le16(0); c.le16(0); c.le16(0); c.le32(0)
        c.le32(UInt32(clamping: offset - UInt64(30 + n.count)))
        central += c + n
        count += 1
    }

    public func write(_ d: Data) throws { try emit(d) }

    public func finish() throws {
        let start = offset
        try emit(central)
        var e = Data(); e.le32(0x0605_4B50); e.le16(0); e.le16(0)
        e.le16(UInt16(clamping: count)); e.le16(UInt16(clamping: count))
        e.le32(UInt32(clamping: central.count)); e.le32(UInt32(clamping: start)); e.le16(0)
        try emit(e)
    }
}

/// Reads a stored-entries zip front to back (each entry's CRC is checked as it's read).
public final class StoredZipReader {
    public struct Entry { public let name: String; public let size: Int }
    private let source: (Int) throws -> Data
    private var remaining = 0
    private var crc = CRC32()
    private var expected: UInt32 = 0

    public init(_ source: @escaping (Int) throws -> Data) { self.source = source }

    private func full(_ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            let d = try source(n - out.count)
            if d.isEmpty { break }
            out += d
        }
        return out
    }

    /// The next entry, or nil after the last one.
    public func next() throws -> Entry? {
        while remaining > 0 { _ = try read(64 * 1024) }
        let sig = try full(4)
        guard sig.count == 4, sig.le32(at: 0) == 0x0403_4B50 else { return nil }   // central directory: the end
        let h = try full(26)
        guard h.count == 26 else { throw BackupFormat.Failure.damaged }
        let flags = h.le16(at: 2), method = h.le16(at: 4)
        let crc = h.le32(at: 10), csize = h.le32(at: 14), usize = h.le32(at: 18)
        let name = String(decoding: try full(Int(h.le16(at: 22))), as: UTF8.self)
        _ = try full(Int(h.le16(at: 24)))
        guard method == 0, flags & 0x9 == 0 else {
            throw BackupFormat.Failure.unreadable("This backup was made by cellosig 0.6.0 for Android, which iPhones can't read. Make a new backup with the Android app (0.6.1 or newer).")
        }
        guard csize == usize, usize != 0xFFFF_FFFF else { throw BackupFormat.Failure.damaged }
        remaining = Int(usize)
        expected = crc
        self.crc = CRC32()
        return Entry(name: name, size: Int(usize))
    }

    /// Up to `n` bytes of the current entry; empty at its end (whose checksum is checked then).
    public func read(_ n: Int) throws -> Data {
        guard remaining > 0 else { return Data() }
        let d = try source(min(n, remaining))
        guard !d.isEmpty else { throw BackupFormat.Failure.incomplete }
        remaining -= d.count
        crc.update(d)
        if remaining == 0, crc.value != expected { throw BackupFormat.Failure.damaged }
        return d
    }

    public func readAll() throws -> Data {
        var out = Data()
        while true { let d = try read(64 * 1024); if d.isEmpty { return out }; out += d }
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    func le16(at i: Int) -> UInt16 { let b = [UInt8](self[(startIndex + i)..<(startIndex + i + 2)]); return UInt16(b[0]) | UInt16(b[1]) << 8 }
    func le32(at i: Int) -> UInt32 {
        let b = [UInt8](self[(startIndex + i)..<(startIndex + i + 4)])
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

// MARK: - Rows

/// The backup's tables (Android column names) and this app's, column by column.
public enum BackupRows {
    public enum Kind { case int, bool, text }
    public struct Column {
        public let backup: String
        public let ios: String?   // nil: not stored on iPhone (written as its default)
        public let kind: Kind
        public let fallback: Any? // value when the other side has none (nil = JSON null)
    }
    public struct Table {
        public let backup: String   // "messages" (in pages), "conversations", "chat_groups", …
        public let ios: String
        public let columns: [Column]
    }

    private static func c(_ b: String, _ i: String? = nil, _ k: Kind = .text, _ f: Any? = nil) -> Column {
        Column(backup: b, ios: i ?? b, kind: k, fallback: f)
    }
    private static func only(_ b: String, _ k: Kind, _ f: Any?) -> Column { Column(backup: b, ios: nil, kind: k, fallback: f) }

    public static let messages = Table(backup: "messages", ios: "messages", columns: [
        c("id", nil, .int, 0), c("peer", "conv"), c("outgoing", nil, .bool, false), c("body", nil, .text, ""), c("ts", nil, .int, 0),
        c("status", nil, .text, "read"), c("msgId", nil, .text, ""), c("sender"), c("fileName"), c("fileMime"), c("fileSize", nil, .int),
        c("filePath"), c("fileKey"), c("fileBlob"), c("fileState"), c("fileKind"), c("transcript"), c("pollJson"),
        c("expiresInSec", nil, .int, 0), c("expiresAt", nil, .int), c("editedAt", nil, .int), c("deleted", nil, .bool, false),
    ])

    /// Every other table, in the order they're written.
    public static let tables: [Table] = [
        Table(backup: "conversations", ios: "conversations", columns: [
            c("peer", "id"), c("lastMessage", "lastText", .text, ""), c("lastTs", nil, .int, 0), c("unread", nil, .int, 0),
            c("timerSec", nil, .int, 0), c("pinnedAt", nil, .int), c("request", nil, .bool, false), c("shield", nil, .bool, false),
        ]),
        Table(backup: "chat_groups", ios: "groups", columns: [c("id"), c("name", nil, .text, "Group"), c("members", nil, .text, "")]),
        Table(backup: "receipts", ios: "receipts", columns: [c("msgId"), c("member"), c("kind")]),
        Table(backup: "reactions", ios: "reactions", columns: [c("msgId"), c("member"), c("emoji"), c("ts", nil, .int, 0)]),
        Table(backup: "votes", ios: "votes", columns: [c("msgId"), c("member"), c("choices", nil, .text, "")]),
        Table(backup: "reminders", ios: "reminders", columns: [
            only("id", .int, 0), c("peer", "conv"), c("messageId", "msgRow", .int, 0), c("text", nil, .text, ""), c("at", nil, .int, 0),
            only("fired", .bool, false),
        ]),
        Table(backup: "profiles", ios: "profiles", columns: [c("peer", "phone"), c("name"), c("photoPath", "photo"), only("ts", .int, 0)]),
        Table(backup: "blocked", ios: "blocked", columns: [c("phone"), c("ts", "at", .int, 0)]),
    ]

    private static func json(_ v: Any?, _ k: Kind) -> Any {
        guard let v, !(v is NSNull) else { return NSNull() }
        switch k {
        case .int:
            if let n = v as? Int64 { return n }
            if let n = v as? NSNumber { return n.int64Value }
            return NSNull()
        case .bool:
            if let b = v as? Bool { return b }
            if let n = v as? Int64 { return n != 0 }
            if let n = v as? NSNumber { return n.int64Value != 0 }
            return false
        case .text:
            if let s = v as? String { return s }
            return NSNull()
        }
    }

    /// One of this app's rows (column → value) as a backup line.
    public static func line(_ t: Table, _ row: [String: Any]) throws -> Data {
        var o: [String: Any] = [:]
        for col in t.columns {
            if let name = col.ios, let v = row[name] { o[col.backup] = json(v, col.kind) }
            else if let f = col.fallback { o[col.backup] = json(f, col.kind) }
            else { o[col.backup] = NSNull() }
        }
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// A backup line as this app's columns (values ready to bind: Int64, String, or nil).
    public static func row(_ t: Table, _ line: Data) throws -> [String: Any?] {
        guard let o = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw BackupFormat.Failure.damaged }
        var r: [String: Any?] = [:]
        for col in t.columns {
            guard let name = col.ios else { continue }
            var v: Any? = o[col.backup]
            if v is NSNull { v = nil }
            if v == nil { v = col.fallback }
            guard let v else { r[name] = .some(nil); continue }
            switch col.kind {
            case .int:
                if let n = v as? NSNumber { r[name] = .some(n.int64Value) }
                else if let n = v as? Int { r[name] = .some(Int64(n)) }
                else { r[name] = .some(nil) }
            case .bool:
                var on = false
                if let b = v as? Bool { on = b } else if let n = v as? NSNumber { on = n.boolValue }
                r[name] = .some(Int64(on ? 1 : 0))
            case .text:
                if let s = v as? String { r[name] = .some(s) } else { r[name] = .some(nil) }
            }
        }
        return r
    }

    /// Splits an entry into its non-empty lines.
    public static func lines(_ d: Data) -> [Data] {
        d.split(separator: UInt8(ascii: "\n")).map { Data($0) }.filter { !$0.allSatisfy { $0 == 32 || $0 == 13 } }
    }
}
