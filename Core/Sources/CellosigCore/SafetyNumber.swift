import CryptoKit
import Foundation

/// 60-digit safety number, identical to the Android client's `crypto/SafetyNumber.kt`
/// (Signal's NumericFingerprintGenerator shape: 5200 rounds of SHA-512 per party).
public enum SafetyNumber {
    static let iterations = 5200

    public static func generate(localId: String, localIdentity: Data, remoteId: String, remoteIdentity: Data) -> String {
        let local = display(fingerprint(Data(localId.utf8), localIdentity))
        let remote = display(fingerprint(Data(remoteId.utf8), remoteIdentity))
        return local <= remote ? local + remote : remote + local
    }

    /// "12345 67890 …"
    public static func formatted(_ number: String) -> String {
        stride(from: 0, to: number.count, by: 5).map { i -> String in
            let s = number.index(number.startIndex, offsetBy: i)
            let e = number.index(s, offsetBy: min(5, number.count - i))
            return String(number[s..<e])
        }.joined(separator: " ")
    }

    static func fingerprint(_ stableId: Data, _ identityPub: Data) -> Data {
        let publicKey = Data([0x05]) + identityPub
        var hash = Data([0, 0]) + publicKey + stableId   // version 0 as a big-endian short
        for _ in 0..<iterations {
            var h = SHA512()
            h.update(data: hash)
            h.update(data: publicKey)
            hash = Data(h.finalize())
        }
        return hash
    }

    static func display(_ hash: Data) -> String {
        let b = [UInt8](hash)
        return stride(from: 0, to: 30, by: 5).map { o -> String in
            let v = (UInt64(b[o]) << 32) | (UInt64(b[o + 1]) << 24) | (UInt64(b[o + 2]) << 16) |
                (UInt64(b[o + 3]) << 8) | UInt64(b[o + 4])
            return String(format: "%05llu", v % 100_000)
        }.joined()
    }
}
