import CellosigCore
import Foundation
import UserNotifications

/// Chat backups: chats, attachments, groups, contacts' profiles, your own profile and stickers in
/// one file locked with a 30-digit code only you have, into a folder you choose (Files: On My
/// iPhone, iCloud Drive, a USB drive…). The same files as the Android app's, so a backup from
/// either restores on either (see CellosigCore/Backup.swift). Off until turned on in Settings;
/// then once a day while cellosig is running, keeping the newest 2.
@MainActor
final class ChatBackups: ObservableObject {
    static let shared = ChatBackups()
    static let keep = 2
    private static let every: TimeInterval = 24 * 3600
    nonisolated private static let ours = try! NSRegularExpression(pattern: "^cellosig-\\d{4}-\\d\\d-\\d\\d-\\d{6}\\.cellobackup$")

    @Published private(set) var busy: String?
    @Published var status: String?

    private let d = UserDefaults.standard
    private var started = false

    struct Failure: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    // MARK: Settings
    var isOn: Bool { d.bool(forKey: "backup_auto") }
    var lastAt: Date? { let t = d.double(forKey: "backup_last"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
    var lastError: String? { d.string(forKey: "backup_error") }
    nonisolated private static var codeFile: URL { Paths.keys.appendingPathComponent("backup.key") }
    /// The code backups are locked with (sealed by the Vault, like the database key).
    var passphrase: String? { Vault.shared.readSealed(Self.codeFile).map { String(decoding: $0, as: UTF8.self) } }

    var folder: URL? {
        guard let bm = d.data(forKey: "backup_folder") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            if let fresh = try? url.bookmarkData() { d.set(fresh, forKey: "backup_folder") }
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    /// `folder` comes from the folder picker (security-scoped).
    func turnOn(code: String, folder: URL) throws {
        try setFolder(folder)
        try Vault.shared.writeSealed(Self.codeFile, Data(code.utf8))
        d.set(true, forKey: "backup_auto")
        d.removeObject(forKey: "backup_error")
        objectWillChange.send()
    }

    func turnOff() {
        try? FileManager.default.removeItem(at: Self.codeFile)
        d.set(false, forKey: "backup_auto")
        d.removeObject(forKey: "backup_error")
        status = nil
        objectWillChange.send()
    }

    func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        d.set(try url.bookmarkData(), forKey: "backup_folder")
        objectWillChange.send()
    }

    // MARK: Backing up

    /// Checks hourly (and whenever cellosig comes to the front) whether a backup is due.
    func start(_ messenger: @escaping @MainActor () -> Messenger?) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            while true {
                if let m = messenger() { backUpIfDue(m) }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    func backUpIfDue(_ m: Messenger) {
        guard isOn, busy == nil, Date().timeIntervalSince(lastAt ?? .distantPast) > Self.every else { return }
        Task { await backUpNow(m) }
    }

    func backUpNow(_ m: Messenger) async {
        guard busy == nil else { return }
        busy = "Backing up…"
        defer { busy = nil }
        do {
            guard let code = passphrase else { throw Failure("Turn chat backups on first.") }
            guard let folder else { throw Failure("Choose a folder first.") }
            let db = m.db, phone = m.me
            let own = OwnSnapshot(set: m.ownProfile.dto != nil, name: m.ownProfile.name, photo: m.ownProfile.photo)
            let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let r = try await Task.detached(priority: .utility) {
                try Self.write(db: db, phone: phone, own: own, app: app, code: code, folder: folder)
            }.value
            d.set(Date().timeIntervalSince1970, forKey: "backup_last")
            d.removeObject(forKey: "backup_error")
            status = "Backed up \(r.messages) messages and \(r.files) files (\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)))."
        } catch {
            let why = "Backup failed: \(error.localizedDescription)"
            d.set(why, forKey: "backup_error")
            status = why
        }
    }

    struct OwnSnapshot: Sendable { let set: Bool; let name: String?; let photo: Data? }

    nonisolated private static func write(db: Database, phone: String, own: OwnSnapshot, app: String, code: String, folder: URL)
        throws -> (messages: Int, files: Int, bytes: Int64) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let stamp = { () -> String in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
            return f.string(from: Date())
        }()
        let target = folder.appendingPathComponent("cellosig-\(stamp).cellobackup")
        let tmp = folder.appendingPathComponent(".cellosig-\(stamp).partial")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw Failure("cellosig can't write to the backup folder anymore. Choose it again.")
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            let w = try BackupWriter(passphrase: code, phone: phone, app: app) { try h.write(contentsOf: $0) }
            let attachmentsDir = Paths.attachments.standardizedFileURL.path
            var attachments: [String] = []
            var after: Int64 = 0
            // Messages a page at a time; disappearing ones are never put in a backup.
            while true {
                let rows = try db.query("SELECT * FROM messages WHERE id > ? AND expiresInSec = 0 ORDER BY id LIMIT 500", after)
                guard let last = rows.last?.int("id") else { break }
                try w.messages(rows.map(\.values))
                for r in rows {
                    guard let p = r.str("filePath") else { continue }
                    let u = URL(fileURLWithPath: p)
                    if u.deletingLastPathComponent().standardizedFileURL.path == attachmentsDir, fm.fileExists(atPath: u.path) {
                        attachments.append(u.lastPathComponent)
                    }
                }
                after = last
            }
            for t in BackupRows.tables { try w.table(t, try db.query("SELECT * FROM \(t.ios)").map(\.values)) }
            for name in attachments where BackupReader.checkedFile("files/attachments/\(name)") != nil {
                try w.file(dir: "attachments", name: name, url: Paths.attachments.appendingPathComponent(name))
            }
            // Contacts' photos and your stickers are sealed on this iPhone; the backup has the pictures.
            let profilesDir = Paths.profiles.standardizedFileURL.path
            for r in try db.query("SELECT photo FROM profiles WHERE photo IS NOT NULL") {
                guard let p = r.str("photo") else { continue }
                let u = URL(fileURLWithPath: p)
                guard u.deletingLastPathComponent().standardizedFileURL.path == profilesDir,
                      BackupReader.checkedFile("files/profiles/\(u.lastPathComponent)") != nil,
                      let data = Vault.shared.readMigrating(u) else { continue }
                try w.file(dir: "profiles", name: u.lastPathComponent, data: data)
            }
            if own.set {
                if let n = own.name { try w.file(dir: "profile", name: "name.txt", data: Data(n.utf8)) }
                if let p = own.photo { try w.file(dir: "profile", name: "me.jpg", data: p) }
                try w.file(dir: "profile", name: "set", data: Data("1".utf8))
            }
            for u in MyStickers.all() where BackupReader.checkedFile("files/stickers/\(u.lastPathComponent)") != nil {
                if let png = Vault.shared.readMigrating(u) { try w.file(dir: "stickers", name: u.lastPathComponent, data: png) }
            }
            let result = try w.finish()
            try h.synchronize()
            try fm.moveItem(at: tmp, to: target)
            prune(folder)
            return result
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Keep the newest `keep` backups in the folder; older ones cellosig made are deleted.
    nonisolated private static func prune(_ folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            ours.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        for n in names.sorted(by: >).dropFirst(keep) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(n)) }
    }

    // MARK: Restoring

    nonisolated private static func withFile<T>(_ url: URL, _ body: (@escaping (Int) throws -> Data) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return try body { n in try h.read(upToCount: n) ?? Data() }
    }

    /// Read the whole backup at `url` and check it (and the code) without changing anything.
    func check(_ url: URL, code: String) async throws -> BackupInfo {
        busy = "Checking the backup…"
        defer { busy = nil }
        return try await Task.detached(priority: .userInitiated) {
            try Self.withFile(url) { try BackupReader.inspect(passphrase: code, read: $0) }
        }.value
    }

    /// Replace this iPhone's chats with a backup already `check`ed as `info`.
    func restore(_ url: URL, code: String, info: BackupInfo, m: Messenger) async throws -> String {
        guard info.phone == m.me else {
            throw Failure("This backup is for \(PhoneNumbers.pretty(info.phone)). Sign in with that number to restore it.")
        }
        busy = "Restoring…"
        defer { busy = nil }
        let db = m.db
        let r = try await Task.detached(priority: .userInitiated) { try Self.apply(db: db, url: url, code: code, info: info) }.value
        if r.ownSet { try? m.ownProfile.set(name: r.ownName, photo: r.ownPhoto, removePhoto: r.ownPhoto == nil) }
        await schedule(r.reminders)
        m.touch()
        return "Restored \(info.messages) messages in \(info.chats) chats."
    }

    struct Restored: Sendable {
        var ownSet = false
        var ownName: String?
        var ownPhoto: Data?
        var reminders: [(id: String, conv: String, at: Int64)] = []
    }

    /// Database rows in one transaction (they all come before the files), then the files.
    nonisolated private static func apply(db: Database, url: URL, code: String, info: BackupInfo) throws -> Restored {
        let fm = FileManager.default
        var out = Restored()
        let old = (try db.query("SELECT filePath AS p FROM messages WHERE filePath IS NOT NULL UNION SELECT photo AS p FROM profiles WHERE photo IS NOT NULL"))
            .compactMap { $0.str("p") }
        let mine = [Paths.attachments, Paths.profiles].map { $0.standardizedFileURL.path }
        var committed = false
        func commit() throws {
            guard !committed else { return }
            try db.exec("COMMIT")
            committed = true
            // The old chats' files go (the backup's replace them).
            for p in old where mine.contains(URL(fileURLWithPath: p).deletingLastPathComponent().standardizedFileURL.path) {
                try? fm.removeItem(atPath: p)
            }
        }
        try db.exec("BEGIN IMMEDIATE")
        do {
            for t in [BackupRows.messages] + BackupRows.tables { try db.exec("DELETE FROM \(t.ios)") }
            try withFile(url) { read in
                try BackupReader.read(passphrase: code, read: read, rows: { t, rows in
                    let cols = t.columns.compactMap(\.ios)
                    let sql = "INSERT OR REPLACE INTO \(t.ios) (\(cols.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))"
                    for var r in rows {
                        fix(t, &r, info, &out)
                        try db.run(sql, args: cols.map { r[$0] ?? nil })
                    }
                }, file: { dir, name, z in
                    try commit()
                    switch dir {
                    case "attachments":
                        let dest = Paths.attachments.appendingPathComponent(name)
                        let tmp = Paths.attachments.appendingPathComponent(".\(name).restore")
                        fm.createFile(atPath: tmp.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                        let h = try FileHandle(forWritingTo: tmp)
                        do {
                            while true { let d = try z.read(256 * 1024); if d.isEmpty { break }; try h.write(contentsOf: d) }
                            try h.close()
                        } catch { try? h.close(); try? fm.removeItem(at: tmp); throw error }
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: tmp, to: dest)
                    case "profiles": try Vault.shared.writeSealed(Paths.profiles.appendingPathComponent(name), try z.readAll())
                    case "stickers": try Vault.shared.writeSealed(MyStickers.dir.appendingPathComponent(name), try z.readAll())
                    case "profile":
                        let data = try z.readAll()
                        out.ownSet = true
                        if name == "name.txt" { out.ownName = String(decoding: data, as: UTF8.self) }
                        if name == "me.jpg" { out.ownPhoto = data }
                    default: break
                    }
                })
            }
            try commit()
        } catch {
            if !committed { try? db.exec("ROLLBACK") }
            throw error
        }
        return out
    }

    /// Paths moved to this iPhone's folders; what can't work here is marked so.
    nonisolated private static func fix(_ t: BackupRows.Table, _ r: inout [String: Any?], _ info: BackupInfo, _ out: inout Restored) {
        func name(_ k: String) -> String? { ((r[k] ?? nil) as? String).map { ($0 as NSString).lastPathComponent } }
        switch t.ios {
        case "messages":
            let n = name("filePath")
            let have = n.map { info.files.contains("attachments/\($0)") } ?? false
            r["filePath"] = .some(have ? Paths.attachments.appendingPathComponent(n!).path : nil)
            // A file that isn't in the backup can't be opened; one being fetched never finished.
            if !have, let s = (r["fileState"] ?? nil) as? String, s == "ready" || s == "downloading" { r["fileState"] = .some("failed") }
            if ((r["outgoing"] ?? nil) as? Int64) == 1, ((r["status"] ?? nil) as? String) == "sending" { r["status"] = .some("failed") }
        case "profiles":
            let n = name("photo")
            r["photo"] = .some(n.flatMap { info.files.contains("profiles/\($0)") ? Paths.profiles.appendingPathComponent($0).path : nil })
        case "reminders":
            let id = "reminder:" + UUID().uuidString.lowercased()
            r["id"] = .some(id)
            if let at = (r["at"] ?? nil) as? Int64, let conv = (r["conv"] ?? nil) as? String { out.reminders.append((id, conv, at)) }
        default: break
        }
    }

    /// Restored reminders still to come go back on the calendar (with the private wording).
    private func schedule(_ reminders: [(id: String, conv: String, at: Int64)]) async {
        let soon = reminders.filter { $0.at > nowMs() }
        guard !soon.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        for r in soon {
            let c = UNMutableNotificationContent()
            c.title = "Reminder"
            c.body = "You asked to be reminded about a message."
            c.sound = .default
            c.threadIdentifier = r.conv
            c.userInfo = ["conv": r.conv]
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: Double(r.at) / 1000))
            try? await center.add(UNNotificationRequest(identifier: r.id, content: c, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }
}
