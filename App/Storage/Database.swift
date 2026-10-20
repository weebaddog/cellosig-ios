import CellosigCore
import Foundation
import SQLCipher

/// Message storage: SQLite ENCRYPTED with SQLCipher (AES-256; the same engine
/// as the Android client) under a random key that only exists sealed by the
/// Vault — whose own key never leaves this iPhone's Keychain. On top of that,
/// iOS Data Protection and no backups. A database from an older build (plain
/// SQLite) is converted on first launch, and only replaced once the encrypted
/// copy is verified complete; if anything goes wrong the old one stays in use
/// (Settings → About says which).
final class Database {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Whether the open database is encrypted (shown in Settings → About), and why not.
    private(set) static var encrypted = false
    private(set) static var notEncryptedReason: String?

    init(url: URL = Paths.database) throws {
        let key = try DatabaseKey.load()
        // An older build's plain database: convert it (or, if that fails, keep using it as it is).
        var stillPlain = false
        do { stillPlain = try Self.encryptIfPlain(url, key) }
        catch { stillPlain = true; Self.notEncryptedReason = "conversion failed: " + Self.describe(error) }
        try open(url, key: stillPlain ? nil : key)
    }

    /// A database at `url` opened with `key` (nil: an old plain one kept in use), schema up to date.
    private init(opening url: URL, key: String) throws {
        try open(url, key: key)
    }

    private func open(_ url: URL, key: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { throw DBError.open }
        if let key {
            try Self.applyKey(db, key)
            if (try? scalarInt("SELECT count(*) FROM sqlite_master")) == nil {
                // The key doesn't open it (the Vault's own key was lost, e.g. restored to
                // another phone): nothing in it can be read again. Set it aside, start fresh.
                sqlite3_close(db); db = nil
                try? FileManager.default.moveItem(atPath: url.path, toPath: url.path + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) }
                guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { throw DBError.open }
                try Self.applyKey(db, key)
            }
        }
        Self.encrypted = key != nil
        Self.protect(url)
        sqlite3_busy_timeout(db, 5000)  // the notification extension may be writing at the same moment
        try exec("PRAGMA journal_mode=WAL")
        // With WAL this is still crash-safe (a power cut can lose at most the last
        // moments, never corrupt the file), and writes no longer wait on a disk flush each.
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    enum DBError: Error { case open, prepare(String), step(String), verify(String) }

    private static func describe(_ error: Error) -> String {
        switch error as? DBError {
        case .open?: return "couldn't open the database file"
        case .prepare(let m)?, .step(let m)?, .verify(let m)?: return m
        case nil: return error.localizedDescription
        }
    }

    // MARK: Encryption

    /// A raw 256-bit key (`x'<64 hex>'`): random, so no passphrase stretching needed.
    private static func applyKey(_ db: OpaquePointer?, _ keyHex: String) throws {
        guard sqlite3_exec(db, "PRAGMA key = \"x'\(keyHex.prefix(64))'\"", nil, nil, nil) == SQLITE_OK else { throw DBError.step("setting the key failed") }
    }

    /// Convert an older build's plain database into an encrypted one. Returns true if
    /// the plain one is still in use (only by throwing: then nothing was changed).
    ///
    /// Plain standard SQL, step by step: a fresh encrypted database is made with the
    /// current schema, every table is copied in column by column from the plain one
    /// (attached unencrypted), each table's row count is checked, and only then are the
    /// files swapped — the old one renamed aside first and deleted last, so a failure
    /// at any point leaves your messages where they were.
    private static func encryptIfPlain(_ url: URL, _ keyHex: String) throws -> Bool {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 0 else { return false }
        // Readable without any key = plain; otherwise it's already encrypted.
        var probe: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &probe, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
        let plain = opened && isPlainReadable(probe)
        sqlite3_close(probe)
        guard plain else { return false }

        let tmp = URL(fileURLWithPath: url.path + ".encrypting")
        func removeTmp() { for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + s) } }
        removeTmp()
        do {
            let enc = try Database(opening: tmp, key: keyHex)   // fresh, encrypted, current schema
            try enc.exec("ATTACH DATABASE '\(url.path)' AS plain KEY ''")   // KEY '': attached unencrypted
            let tables = try enc.query("SELECT name FROM plain.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                .compactMap { $0.str("name") }
            for t in tables {
                let have = Set(try enc.query("PRAGMA main.table_info(\"\(t)\")").compactMap { $0.str("name") })
                guard !have.isEmpty else { continue }   // a table this build no longer has
                let cols = try enc.query("PRAGMA plain.table_info(\"\(t)\")").compactMap { $0.str("name") }.filter(have.contains)
                let list = cols.map { "\"\($0)\"" }.joined(separator: ", ")
                try enc.exec("INSERT INTO main.\"\(t)\" (\(list)) SELECT \(list) FROM plain.\"\(t)\"")
                let a = try enc.scalarInt("SELECT COUNT(*) FROM plain.\"\(t)\"") ?? -1
                let b = try enc.scalarInt("SELECT COUNT(*) FROM main.\"\(t)\"") ?? -2
                guard a == b else { throw DBError.verify("\(t): \(a) rows, copied \(b)") }
            }
            // Keep message numbering going where it was.
            if (try enc.scalarInt("SELECT 1 FROM plain.sqlite_master WHERE name = 'sqlite_sequence'")) != nil {
                try enc.exec("INSERT OR REPLACE INTO main.sqlite_sequence(name, seq) SELECT name, seq FROM plain.sqlite_sequence")
            }
            try enc.exec("DETACH DATABASE plain")
            _ = try enc.query("PRAGMA wal_checkpoint(TRUNCATE)")   // everything into the main file before moving it
            enc.close()
        } catch {
            removeTmp()
            throw error
        }

        // Swap: old aside first, new in, old deleted last.
        let old = url.path + ".plain-old"
        for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: old + s) }
        for s in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + s) { try fm.moveItem(atPath: url.path + s, toPath: old + s) }
        do {
            for s in ["", "-wal", "-shm"] where fm.fileExists(atPath: tmp.path + s) { try fm.moveItem(atPath: tmp.path + s, toPath: url.path + s) }
        } catch {
            for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: url.path + s) }
            for s in ["", "-wal", "-shm"] where fm.fileExists(atPath: old + s) { try? fm.moveItem(atPath: old + s, toPath: url.path + s) }
            removeTmp()
            throw error
        }
        for s in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: old + s) }
        return false
    }

    /// Opens and answers without a key: a plain (unencrypted) SQLite file.
    private static func isPlainReadable(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK
    }

    /// iOS Data Protection on the files too (unreadable until the phone's first unlock after a restart).
    private static func protect(_ url: URL) {
        for s in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + s) {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: url.path + s)
        }
    }

    // MARK: Schema
    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS conversations(
              id TEXT PRIMARY KEY, lastText TEXT NOT NULL DEFAULT '', lastTs INTEGER NOT NULL DEFAULT 0,
              unread INTEGER NOT NULL DEFAULT 0, request INTEGER NOT NULL DEFAULT 0, pinnedAt INTEGER,
              timerSec INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS messages(
              id INTEGER PRIMARY KEY AUTOINCREMENT, conv TEXT NOT NULL, outgoing INTEGER NOT NULL, body TEXT NOT NULL DEFAULT '',
              ts INTEGER NOT NULL, status TEXT NOT NULL, msgId TEXT NOT NULL DEFAULT '', sender TEXT,
              fileName TEXT, fileMime TEXT, fileSize INTEGER, fileKey TEXT, fileBlob TEXT, filePath TEXT, fileState TEXT, fileKind TEXT,
              pollJson TEXT, expiresInSec INTEGER NOT NULL DEFAULT 0, expiresAt INTEGER, readAt INTEGER);
            CREATE INDEX IF NOT EXISTS messages_conv ON messages(conv, ts);
            CREATE INDEX IF NOT EXISTS messages_msgid ON messages(msgId);
            CREATE TABLE IF NOT EXISTS receipts(msgId TEXT NOT NULL, member TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(msgId, member));
            CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY, name TEXT NOT NULL, members TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS reactions(msgId TEXT NOT NULL, member TEXT NOT NULL, emoji TEXT NOT NULL, ts INTEGER NOT NULL, PRIMARY KEY(msgId, member));
            CREATE TABLE IF NOT EXISTS votes(msgId TEXT NOT NULL, member TEXT NOT NULL, choices TEXT NOT NULL, PRIMARY KEY(msgId, member));
            CREATE TABLE IF NOT EXISTS seen_frames(mid INTEGER PRIMARY KEY, at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS blocked(phone TEXT PRIMARY KEY, at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS profiles(phone TEXT PRIMARY KEY, name TEXT, photo TEXT);
            CREATE TABLE IF NOT EXISTS verified(phone TEXT PRIMARY KEY, safety TEXT NOT NULL);
            PRAGMA user_version = 1;
            """)
        }
        if version < 2 {
            // Message reminders (the notification itself is scheduled with iOS under the same id).
            try exec("""
            CREATE TABLE IF NOT EXISTS reminders(id TEXT PRIMARY KEY, conv TEXT NOT NULL, msgRow INTEGER, text TEXT NOT NULL, at INTEGER NOT NULL);
            PRAGMA user_version = 2;
            """)
        }
        if version < 3 {
            // Edited / deleted-for-everyone messages (same columns as the Android client).
            try exec("""
            ALTER TABLE messages ADD COLUMN editedAt INTEGER;
            ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
            PRAGMA user_version = 3;
            """)
        }
        if version < 4 {
            // Voice-note transcripts (made on the phone, never sent).
            try exec("""
            ALTER TABLE messages ADD COLUMN transcript TEXT;
            PRAGMA user_version = 4;
            """)
        }
        if version < 5 {
            // "Block screenshots" for a chat (set by anyone in it, for everyone in it).
            try exec("""
            ALTER TABLE conversations ADD COLUMN shield INTEGER NOT NULL DEFAULT 0;
            PRAGMA user_version = 5;
            """)
        }
        // The data folder just moved into the App Group: files stored by full path moved with it.
        if let moved = Paths.movedFrom {
            let (old, new) = moved
            try run("UPDATE messages SET filePath = ? || substr(filePath, length(?) + 1) WHERE substr(filePath, 1, length(?)) = ?", new, old, old, old)
            try run("UPDATE profiles SET photo = ? || substr(photo, length(?) + 1) WHERE substr(photo, 1, length(?)) = ?", new, old, old, old)
        }
    }

    // MARK: Primitives
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw DBError.step(msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: Any?...) throws -> Int64 { try run(sql, args: args) }

    @discardableResult
    func run(_ sql: String, args: [Any?]) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
        return sqlite3_last_insert_rowid(db)
    }

    func changes() -> Int { Int(sqlite3_changes(db)) }

    func query(_ sql: String, _ args: Any?...) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var r = Row()
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: r.values[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: r.values[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: if let t = sqlite3_column_text(stmt, i) { r.values[name] = String(cString: t) }
                default: break
                }
            }
            rows.append(r)
        }
        return rows
    }

    func scalarInt(_ sql: String, _ args: Any?...) throws -> Int64? {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError.prepare(String(cString: sqlite3_errmsg(db))) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    func close() { sqlite3_close(db); db = nil }
}

/// The database's encryption key: 32 random bytes of key + 16 of salt, kept
/// only sealed by the Vault (whose key never leaves this iPhone's Keychain).
enum DatabaseKey {
    private static var file: URL { Paths.keys.appendingPathComponent("database.key") }

    /// As hex for SQLCipher's raw-key form. Made once; a key that can't be saved
    /// is never used (the database would be unreadable after a restart).
    static func load() throws -> String {
        if let d = Vault.shared.readSealed(file), d.count == 48 { return hex(d) }
        let fresh = Primitives.randomBytes(48)
        try Vault.shared.writeSealed(file, fresh)
        guard Vault.shared.readSealed(file) == fresh else { throw Database.DBError.verify("database key didn't save") }
        return hex(fresh)
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }
}

struct Row {
    var values: [String: Any] = [:]
    func str(_ k: String) -> String? { values[k] as? String }
    func int(_ k: String) -> Int64? { values[k] as? Int64 }
    func bool(_ k: String) -> Bool { (values[k] as? Int64 ?? 0) != 0 }
}
