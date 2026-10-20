// Cindy inside the user's apps (master copy: C:\MyReverseProjects\celloai\cindylink\ios\Cindy;
// celloai\cindylink\sync-ios.ps1 copies it into each iPhone app). Edit the master, then sync.

import CryptoKit
import Foundation

struct CindyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// End-to-end layer inside the WebSocket, so the Cloudflare tunnel (which ends TLS) only relays sealed bytes.
/// Handshake: a fresh P-256 ECDH per connection, HKDF-SHA256 salted with this app's secret (SHA-256 of the
/// pairing token, which the PC stores); the token itself never travels. Frames: AES-256-GCM, one key per
/// direction, counter nonces, so dropped, replayed or reordered frames fail. Mirrors E2E in the PC's bridge.py.
final class CindyE2E {
    private let tx: SymmetricKey
    private let rx: SymmetricKey
    private var nOut: UInt64 = 0
    private var nIn: UInt64 = 0

    /// DER SubjectPublicKeyInfo header for an uncompressed P-256 point (the PC sends and expects SPKI DER).
    static let spkiHeader = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    private init(tx: SymmetricKey, rx: SymmetricKey) {
        self.tx = tx
        self.rx = rx
    }

    private static func nonce(_ n: UInt64) -> AES.GCM.Nonce {
        var d = Data(count: 4)
        withUnsafeBytes(of: n.bigEndian) { d.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: d)
    }

    /// kind 0 = JSON, 1 = audio. The frame is ciphertext + tag (the nonce is the counter, never sent).
    func seal(_ kind: UInt8, _ body: Data) throws -> Data {
        let box = try AES.GCM.seal(Data([kind]) + body, using: tx, nonce: Self.nonce(nOut))
        nOut += 1
        return box.ciphertext + box.tag
    }

    /// Throws if the frame wasn't sealed by the paired PC (or arrived out of order).
    func open(_ frame: Data) throws -> (UInt8, Data) {
        guard frame.count > 16 else { throw CindyError("short frame") }
        let box = try AES.GCM.SealedBox(nonce: Self.nonce(nIn), ciphertext: frame.dropLast(16), tag: frame.suffix(16))
        let plain = try AES.GCM.open(box, using: rx)
        nIn += 1
        guard let kind = plain.first else { throw CindyError("empty frame") }
        return (kind, Data(plain.dropFirst()))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// This app's half of the handshake: send `id` and `pub` in hello2, then finish() with the PC's reply.
    struct Handshake {
        private let secret: Data
        private let key = P256.KeyAgreement.PrivateKey()
        private let myDER: Data
        let id: String
        let pub: String

        init(token: String) {
            secret = Data(SHA256.hash(data: Data(token.utf8)))
            myDER = CindyE2E.spkiHeader + key.publicKey.x963Representation
            id = String(CindyE2E.hex(SHA256.hash(data: Data("cindy-id".utf8) + secret)).prefix(32))
            pub = myDER.base64EncodedString()
        }

        func finish(pcPub: String) throws -> CindyE2E {
            guard let der = Data(base64Encoded: pcPub), der.count == 91, der.prefix(26) == CindyE2E.spkiHeader else {
                throw CindyError("bad key from the PC")
            }
            let pcKey = try P256.KeyAgreement.PublicKey(x963Representation: der.suffix(65))
            let shared = try key.sharedSecretFromKeyAgreement(with: pcKey)
            let keys = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret,
                                                     sharedInfo: Data("cindy e2e v1".utf8) + myDER + der, outputByteCount: 64)
            let raw = keys.withUnsafeBytes { Data($0) }
            return CindyE2E(tx: SymmetricKey(data: raw.prefix(32)), rx: SymmetricKey(data: raw.suffix(32)))
        }
    }
}
