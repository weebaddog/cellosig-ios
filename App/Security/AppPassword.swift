import CellosigCore
import CommonCrypto
import Foundation

/// The optional cellosig password for the app lock (the iOS port of the
/// Android client's app password). Only a PBKDF2-HMAC-SHA256 hash over a random
/// salt is kept, sealed by the Vault like the keys, and compared in constant
/// time. It gates the screen; the data itself is protected by the Vault and iOS
/// Data Protection.
///
/// With "Erase after 10 wrong passwords" on, the tenth wrong guess in a row
/// wipes cellosig from the phone.
enum AppPassword {
    static let maxFails = 10
    static let minLength = 4
    private static let iterations: UInt32 = 120_000

    private struct Stored: Codable {
        var salt: Data
        var hash: Data
        var fails: Int
    }

    private static var file: URL { Paths.keys.appendingPathComponent("app_password.bin") }

    private static func load() -> Stored? {
        Vault.shared.readSealed(file).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    private static func store(_ s: Stored) {
        try? Vault.shared.writeSealed(file, JSONEncoder().encode(s))
    }

    static var isSet: Bool { load() != nil }

    /// Wrong guesses since the last right one.
    static var fails: Int { load()?.fails ?? 0 }

    static func set(_ password: String) {
        let salt = Primitives.randomBytes(16)
        store(Stored(salt: salt, hash: derive(password, salt), fails: 0))
    }

    static func remove() { try? FileManager.default.removeItem(at: file) }

    enum Outcome: Equatable {
        case ok
        case wrong(triesLeft: Int?)   // nil: no limit (erasing is off)
        case erase
    }

    static func check(_ password: String, eraseOnFails: Bool) -> Outcome {
        guard var s = load() else { return .ok }
        if equal(derive(password, s.salt), s.hash) {
            if s.fails != 0 { s.fails = 0; store(s) }
            return .ok
        }
        s.fails += 1
        store(s)
        guard eraseOnFails else { return .wrong(triesLeft: nil) }
        return s.fails >= maxFails ? .erase : .wrong(triesLeft: maxFails - s.fails)
    }

    private static func derive(_ password: String, _ salt: Data) -> Data {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        _ = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &out, out.count)
            }
        }
        return Data(out)
    }

    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var r: UInt8 = 0
        for (x, y) in zip(a, b) { r |= x ^ y }
        return r == 0
    }
}
