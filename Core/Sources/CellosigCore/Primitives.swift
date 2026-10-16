import CryptoKit
import Foundation

/// Thin wrappers over CryptoKit, matching the Android client's
/// `crypto/Primitives.kt` byte for byte:
///  - X25519 keys are raw 32 bytes, Ed25519 private keys are the 32-byte seed;
///  - AES-256-GCM output is iv(12) || ciphertext || tag(16);
///  - HKDF-SHA256 and HMAC-SHA256 as usual.
///
/// No elliptic-curve or AEAD code of our own: CryptoKit does the math.
public enum Primitives {
    public enum Failure: Error { case badKey, tooShort }

    public static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(status == errSecSuccess, "system RNG failed")
        return Data(b)
    }

    // MARK: X25519
    public static func x25519KeyPair() -> KeyPair {
        let k = Curve25519.KeyAgreement.PrivateKey()
        return KeyPair(privateKey: k.rawRepresentation, publicKey: k.publicKey.rawRepresentation)
    }

    /// Raw X25519 shared secret (32 bytes).
    public static func dh(_ ownPrivate: Data, _ peerPublic: Data) throws -> Data {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ownPrivate)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        return try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
    }

    // MARK: Ed25519
    public static func ed25519KeyPair() -> KeyPair {
        let k = Curve25519.Signing.PrivateKey()
        return KeyPair(privateKey: k.rawRepresentation, publicKey: k.publicKey.rawRepresentation)
    }

    public static func sign(_ privateKey: Data, _ message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: message)
    }

    public static func verify(_ publicKey: Data, _ signature: Data, _ message: Data) -> Bool {
        guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return k.isValidSignature(signature, for: message)
    }

    // MARK: Hashes / KDFs
    public static func hkdf(_ ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length
        ).withUnsafeBytes { Data($0) }
    }

    public static func hmacSha256(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func sha256Hex(_ data: Data) -> String { sha256(data).hex }
    public static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }

    // MARK: AES-256-GCM
    /// iv(12) || ciphertext || tag. `aad` is authenticated, not encrypted.
    public static func aesGcmSeal(_ key: Data, _ plaintext: Data, aad: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.badKey }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(), authenticating: aad)
        return box.combined!  // non-nil for the default 12-byte nonce
    }

    /// Throws on authentication failure.
    public static func aesGcmOpen(_ key: Data, _ ivAndCiphertext: Data, aad: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.badKey }
        guard ivAndCiphertext.count > 12 + 16 - 1 else { throw Failure.tooShort }
        let box = try AES.GCM.SealedBox(combined: ivAndCiphertext)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    // MARK: Encoding
    public static func b64(_ d: Data) -> String { d.base64EncodedString() }
    public static func unb64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad base64")) }
        return d
    }
}

/// A raw-bytes key pair (32-byte keys for X25519 and Ed25519).
public struct KeyPair: Equatable, Codable {
    public let privateKey: Data
    public let publicKey: Data
    public init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Big-endian 32-bit encoding (the ratchet header and attachment chunk index use it).
    static func u32(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)])
    }
}
