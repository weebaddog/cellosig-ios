import Foundation
import SQLite3

/// Message storage: plain SQLite (system library, no dependencies) in the
/// App Group container, protected by iOS Data Protection (unreadable until
/// the phone is unlocked once after boot) and excluded from backups.
/// Keys and sessions are separately vault-sealed (see Vault).
final class Database {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = Paths.database) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { throw DBError.open }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    enum DBError: Error { case open, prepare(String), step(String) }

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
    func run(_ sql: String, _ args: Any?...) throws -> Int64 {
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

struct Row {
    var values: [String: Any] = [:]
    func str(_ k: String) -> String? { values[k] as? String }
    func int(_ k: String) -> Int64? { values[k] as? Int64 }
    func bool(_ k: String) -> Bool { (values[k] as? Int64 ?? 0) != 0 }
}
