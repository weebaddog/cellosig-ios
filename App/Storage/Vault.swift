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

    /// Crypto-erase: without the key every sealed file is noise.
    func destroyKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = Paths.keychainGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private func loadOrCreateKey() -> SymmetricKey {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 {
            return SymmetricKey(data: d)
        }
        let fresh = Primitives.randomBytes(32)
        var add = baseQuery()
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement || status == errSecNoSuchAttr, add[kSecAttrAccessGroup as String] != nil {
            // Unsigned/simulator builds have no shared keychain group.
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        precondition(status == errSecSuccess || status == errSecDuplicateItem, "keychain unavailable (\(status))")
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
    static let defaults = UserDefaults(suiteName: Paths.appGroup) ?? .standard
}

/// Where everything lives: the App Group container, shared with the notification extension.
enum Paths {
    static let appGroup = "group.com.cellosig.app"
    /// Set from Info.plist (the team prefix is only known at signing time).
    static let keychainGroup: String? = Bundle.main.object(forInfoDictionaryKey: "CellosigKeychainGroup") as? String

    static let root: URL = {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("cellosig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // keys and sessions never go to iCloud
        var u = dir
        try? u.setResourceValues(values)
        return dir
    }()

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
