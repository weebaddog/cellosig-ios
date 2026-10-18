import CellosigCore
import Foundation

/// The signed-in account: number, relay token, relay address. Vault-sealed.
struct Account: Codable, Equatable {
    var phone: String
    // (relayURL may be moved by a signed address from the relay; see RelayAddress)
    var token: String
    var relayURL: String

    private static var file: URL { Paths.keys.appendingPathComponent("account.bin") }

    static func load() -> Account? {
        Vault.shared.readSealed(file).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    func save() throws { try Vault.shared.writeSealed(Self.file, JSONEncoder().encode(self)) }

    static func clear() { try? FileManager.default.removeItem(at: file) }
}

/// Long-lived keys: identity (X25519 + Ed25519), signed prekey, one-time prekeys.
/// Same fields as the Android client's IdentityStore.
final class IdentityStore {
    struct Stored: Codable {
        var ikPriv: String, ikPub: String
        var ikSignPriv: String, ikSignPub: String
        var spkPriv: String, spkPub: String
        var spkSig: String
        var oneTimePreKeys: [Otpk] = []
        var nextOtpkId: Int = 0
    }
    struct Otpk: Codable { var id: Int; var priv: String; var pub: String }

    private var data: Stored
    private let file: URL

    private init(file: URL, data: Stored) { self.file = file; self.data = data }

    static func loadOrCreate(phone: String) throws -> IdentityStore {
        let file = Paths.keys.appendingPathComponent("identity_\(phone).bin")
        if let raw = Vault.shared.readSealed(file), let stored = try? JSONDecoder().decode(Stored.self, from: raw) {
            return IdentityStore(file: file, data: stored)
        }
        let ik = Primitives.x25519KeyPair(), iks = Primitives.ed25519KeyPair(), spk = Primitives.x25519KeyPair()
        let s = IdentityStore(file: file, data: Stored(
            ikPriv: Primitives.b64(ik.privateKey), ikPub: Primitives.b64(ik.publicKey),
            ikSignPriv: Primitives.b64(iks.privateKey), ikSignPub: Primitives.b64(iks.publicKey),
            spkPriv: Primitives.b64(spk.privateKey), spkPub: Primitives.b64(spk.publicKey),
            spkSig: Primitives.b64(try Primitives.sign(iks.privateKey, spk.publicKey))))
        try s.persist()
        return s
    }

    var identity: KeyPair { kp(data.ikPriv, data.ikPub) }
    var signedPreKey: KeyPair { kp(data.spkPriv, data.spkPub) }

    /// Re-read from disk (the other process may have used or added one-time prekeys).
    func reload() {
        if let raw = Vault.shared.readSealed(file), let stored = try? JSONDecoder().decode(Stored.self, from: raw) { data = stored }
    }

    func publicBundle(otpkCount: Int) throws -> PublicBundle {
        try CrossProcessLock.run {
            reload()
            if data.oneTimePreKeys.isEmpty { _ = try generateOneTimePreKeys(otpkCount) }
            return PublicBundle(identityKey: data.ikPub, signingKey: data.ikSignPub, signedPreKey: data.spkPub,
                                signedPreKeySig: data.spkSig, oneTimePreKeys: data.oneTimePreKeys.map { .init(id: $0.id, key: $0.pub) })
        }
    }

    func generateOneTimePreKeys(_ n: Int) throws -> [OneTimePreKey] {
        try CrossProcessLock.run { reload(); return try generateLocked(n) }
    }

    private func generateLocked(_ n: Int) throws -> [OneTimePreKey] {
        var made: [OneTimePreKey] = []
        for _ in 0..<n {
            let k = Primitives.x25519KeyPair()
            let id = data.nextOtpkId
            data.nextOtpkId += 1
            data.oneTimePreKeys.append(Otpk(id: id, priv: Primitives.b64(k.privateKey), pub: Primitives.b64(k.publicKey)))
            made.append(.init(id: id, key: Primitives.b64(k.publicKey)))
        }
        try persist()
        return made
    }

    func oneTimePreKey(_ id: Int?) -> KeyPair? {
        guard let id else { return nil }
        reload()
        guard let o = data.oneTimePreKeys.first(where: { $0.id == id }) else { return nil }
        return kp(o.priv, o.pub)
    }

    func consumeOneTimePreKey(_ id: Int?) {
        guard let id else { return }
        CrossProcessLock.run {
            reload()
            let before = data.oneTimePreKeys.count
            data.oneTimePreKeys.removeAll { $0.id == id }
            if data.oneTimePreKeys.count != before { try? persist() }
        }
    }

    private func persist() throws { try Vault.shared.writeSealed(file, JSONEncoder().encode(data)) }

    private func kp(_ priv: String, _ pub: String) -> KeyPair {
        KeyPair(privateKey: (try? Primitives.unb64(priv)) ?? Data(), publicKey: (try? Primitives.unb64(pub)) ?? Data())
    }
}

/// One Double Ratchet session per peer, vault-sealed. Always read from disk:
/// the notification extension may have advanced a session since we last looked.
/// Callers load-modify-save under CrossProcessLock.
final class SessionStore {
    private func file(_ peer: String) -> URL { Paths.sessions.appendingPathComponent("s_\(Primitives.sha256Hex(peer)).bin") }

    func has(_ peer: String) -> Bool { FileManager.default.fileExists(atPath: file(peer).path) }

    func load(_ peer: String) -> Session? {
        guard let raw = Vault.shared.readSealed(file(peer)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: raw)
    }

    func save(_ peer: String, _ s: Session) throws {
        try Vault.shared.writeSealed(file(peer), JSONEncoder().encode(s))
    }

    func drop(_ peer: String) {
        try? FileManager.default.removeItem(at: file(peer))
    }
}

/// Sealed-sender access keys: ours (relay holds its SHA-256) and the ones contacts gave us.
final class AccessKeys {
    private var ownFile: URL { Paths.keys.appendingPathComponent("access.bin") }
    private var peersFile: URL { Paths.keys.appendingPathComponent("peer_access.bin") }

    lazy var own: String = {
        if let d = Vault.shared.readSealed(ownFile), let s = String(data: d, encoding: .utf8) { return s }
        let s = Primitives.b64(Primitives.randomBytes(32))
        try? Vault.shared.writeSealed(ownFile, Data(s.utf8))
        return s
    }()

    var ownHash: String { Primitives.sha256Hex((try? Primitives.unb64(own)) ?? Data()) }

    func of(_ peer: String) -> String? { load()[peer] }

    func remember(_ peer: String, _ key: String) {
        CrossProcessLock.run {
            var m = load()
            guard m[peer] != key, (try? Primitives.unb64(key))?.count == 32 else { return }
            m[peer] = key
            save(m)
        }
    }

    func forget(_ peer: String) {
        CrossProcessLock.run {
            var m = load()
            if m.removeValue(forKey: peer) != nil { save(m) }
        }
    }

    private func load() -> [String: String] {
        Vault.shared.readSealed(peersFile).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ m: [String: String]) {
        try? Vault.shared.writeSealed(peersFile, JSONEncoder().encode(m))
    }
}

/// Session starts already accepted, so a replayed one can't roll a session back.
final class SeenSessionStarts {
    private let file = Paths.keys.appendingPathComponent("seen_session_starts")
    private var seen: [String] {
        (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init).filter { $0.count == 64 } ?? []
    }
    private static let max = 5000

    func contains(ik: Data, ek: Data) -> Bool { seen.contains(Primitives.sha256Hex(ik + ek)) }

    func add(ik: Data, ek: Data) {
        let fp = Primitives.sha256Hex(ik + ek)
        var seen = self.seen
        guard !seen.contains(fp) else { return }
        seen.append(fp)
        if seen.count > Self.max { seen.removeFirst(seen.count - Self.max) }
        try? (seen.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Your own profile (name + photo) and who already has its current version.
final class OwnProfile {
    private var dir: URL { Paths.keys.appendingPathComponent("profile", isDirectory: true) }
    private var nameFile: URL { dir.appendingPathComponent("name.txt") }
    private var photoFile: URL { dir.appendingPathComponent("me.jpg") }
    private var setFile: URL { dir.appendingPathComponent("set") }
    private var sentFile: URL { dir.appendingPathComponent("sent.txt") }

    // (All sealed by the Vault; files from older builds are sealed on first read.)
    var name: String? { Profiles.cleanName(Vault.shared.readMigrating(nameFile).map { String(decoding: $0, as: UTF8.self) }) }
    var photo: Data? { Vault.shared.readMigrating(photoFile) }

    var dto: ProfileDto? {
        guard FileManager.default.fileExists(atPath: setFile.path) else { return nil }
        return ProfileDto(name: name, photo: photo.map(Primitives.b64))
    }

    func set(name: String?, photo: Data?, removePhoto: Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let clean = Profiles.cleanName(name) { try Vault.shared.writeSealed(nameFile, Data(clean.utf8)) }
        else { try? FileManager.default.removeItem(at: nameFile) }
        if removePhoto { try? FileManager.default.removeItem(at: photoFile) }
        else if let photo {
            guard photo.count <= Profiles.maxPhotoBytes, Profiles.looksLikeImage(photo) else { throw CocoaError(.fileWriteInvalidFileName) }
            try Vault.shared.writeSealed(photoFile, photo)
        }
        try Data("1".utf8).write(to: setFile)
        try? FileManager.default.removeItem(at: sentFile)
    }

    /// Who already has your current profile (phone numbers: sealed too).
    private var sentList: String { Vault.shared.readMigrating(sentFile).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func alreadySent(to peer: String) -> Bool {
        sentList.split(separator: "\n").contains { $0 == peer }
    }

    func markSent(to peer: String) {
        try? Vault.shared.writeSealed(sentFile, Data((sentList + peer + "\n").utf8))
    }
}
