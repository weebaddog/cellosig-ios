import CellosigCore
import CryptoKit
import Foundation
import Security

/// Seals small secret files (identity keys, sessions, tokens) with AES-256-GCM
/// under a key that lives only in the Keychain, "this device only" and
/// available after first unlock (so the notification extension can read it
/// while the phone is locked). Copying the files off the phone, or restoring
/// them from a backup to another phone, gets nothing readable.
///
/// The iOS counterpart of the Android client's KeystoreVault.
final class Vault {
    static let shared = Vault()

    private let service = "com.cellosig.vault"
    private let account = "file-key.v1"
    private lazy var key: SymmetricKey = loadOrCreateKey()

    func seal(_ plaintext: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: key).combined!
    }

    func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    /// Atomic write (temp file + rename), so a crash mid-write never leaves a torn key file.
    func writeSealed(_ url: URL, _ plaintext: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try seal(plaintext).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readSealed(_ url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? open(raw)
    }

    /// For files older builds wrote unsealed (profile photos, wallpaper, stickers):
    /// read it either way, and seal a plain one in place so it's never plain again.
    func readMigrating(_ url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        if let plain = try? open(raw) { return plain }
        try? writeSealed(url, raw)
        return raw
    }

    /// Crypto-erase: without the key every sealed file is noise.
    func destroyKey() {
        SecItemDelete(baseQuery(shared: true) as CFDictionary)
        SecItemDelete(baseQuery(shared: false) as CFDictionary)
    }

    /// `shared`: in the keychain group the notification extension can read. Builds
    /// without that entitlement (simulator, sideloaded) keep the key app-private.
    private func baseQuery(shared: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, let group = Paths.keychainGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private func readKey(shared: Bool) -> SymmetricKey? {
        var q = baseQuery(shared: shared)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 else { return nil }
        return SymmetricKey(data: d)
    }

    private func loadOrCreateKey() -> SymmetricKey {
        // (Without the group entitlement, the shared lookup fails every time: the
        // key must then be found app-private, or each launch would make a new
        // one and nothing sealed before would open again.)
        if let k = readKey(shared: true) ?? readKey(shared: false) { return k }
        let fresh = Primitives.randomBytes(32)
        var add = baseQuery(shared: true)
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement || status == errSecNoSuchAttr, add[kSecAttrAccessGroup as String] != nil {
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        precondition(status == errSecSuccess, "keychain unavailable (\(status))")
        return SymmetricKey(data: fresh)
    }
}

/// The app and its notification extension are separate processes sharing one
/// set of keys and sessions. Every step that reads-modifies-writes them runs
/// under this lock (flock on a file in the App Group) and reads state fresh
/// from disk, so the two can never interleave a ratchet step.
enum CrossProcessLock {
    private static let fd: Int32 = open(Paths.root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
    private static var depth = 0   // re-entrant within this process (always used on the main actor)

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        if depth == 0 { flock(fd, LOCK_EX) }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 { flock(fd, LOCK_UN) }
        }
        return try body()
    }
}

/// Settings both processes read (read receipts, notification previews, push token).
enum Shared {
    static let defaults: UserDefaults = {
        let d = UserDefaults(suiteName: Paths.appGroup) ?? .standard
        // A sideloaded install that just gained its App Group (under another
        // name): bring the settings saved before, app-private, along.
        if Paths.appGroup != AppGroup.standard, AppGroup.container != nil, !d.bool(forKey: "settings_moved"),
           let old = UserDefaults.standard.persistentDomain(forName: AppGroup.standard) {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            d.set(true, forKey: "settings_moved")
        }
        return d
    }()
}

/// Where everything lives: the App Group container, shared with the extensions.
enum Paths {
    static var appGroup: String { AppGroup.id }
    /// Set from Info.plist (the team prefix is only known at signing time).
    static let keychainGroup: String? = Bundle.main.object(forInfoDictionaryKey: "CellosigKeychainGroup") as? String

    static let root: URL = {
        let fm = FileManager.default
        let private_ = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("cellosig", isDirectory: true)
        var dir = private_
        if let group = AppGroup.container {
            let shared = group.appendingPathComponent("cellosig", isDirectory: true)
            // Installed before without an App Group (sideloaded): everything is in
            // the app's private folder. Move it over once, or the account is lost.
            if fm.fileExists(atPath: private_.appendingPathComponent("cellosig.sqlite").path),
               !fm.fileExists(atPath: shared.appendingPathComponent("cellosig.sqlite").path) {
                try? fm.removeItem(at: shared)
                if (try? fm.moveItem(at: private_, to: shared)) != nil {
                    movedFrom = (private_.path, shared.path)
                    dir = shared
                }
                // (If it couldn't be moved, keep using it where it is.)
            } else if !fm.fileExists(atPath: private_.appendingPathComponent("cellosig.sqlite").path) {
                dir = shared
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // keys and sessions never go to iCloud
        var u = dir
        try? u.setResourceValues(values)
        return dir
    }()

    /// Set when this launch moved the data folder (old path, new path): stored file paths need rewriting.
    private(set) static var movedFrom: (old: String, new: String)?

    static var keys: URL { sub("keys") }
    static var sessions: URL { sub("keys/sessions") }
    static var attachments: URL { sub("attachments") }
    static var profiles: URL { sub("profiles") }
    static var database: URL { root.appendingPathComponent("cellosig.sqlite") }

    private static func sub(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return u
    }
}
