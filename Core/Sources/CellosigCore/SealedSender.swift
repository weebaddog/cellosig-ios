import Foundation

/// Sealed sender, identical to the Android client's `crypto/SealedSender.kt`:
///
///   e = fresh X25519
///   chain1, k1 = HKDF(DH(e, IK_r), salt = e_pub || IK_r, "cellosig/sealed/v1/eph", 64)
///   encIk = AES-GCM(k1, IK_s, aad = e_pub)
///   k2 = HKDF(DH(IK_s, IK_r), salt = chain1 || encIk, "cellosig/sealed/v1/static", 32)
///   ct = AES-GCM(k2, {"cert":…,"env":"<envelope JSON>"}, aad = e_pub || encIk)
public enum SealedSender {
    static let infoEph = Data("cellosig/sealed/v1/eph".utf8)
    static let infoStatic = Data("cellosig/sealed/v1/static".utf8)

    public enum Failure: Error { case badCertificate, expired, wrongIdentity }

    public struct Box: Codable, Equatable {
        public var eph: String
        public var ik: String
        public var ct: String
    }

    /// Relay-signed "this identity key belongs to this number until exp".
    public struct Certificate: Codable, Equatable {
        public var data: String
        public var sig: String
        public init(data: String, sig: String) { self.data = data; self.sig = sig }

        /// Expiry in ms since 1970 (0 if unreadable).
        public var expiry: Int64 { (try? JSONDecoder().decode(CertData.self, from: Data(data.utf8)).exp) ?? 0 }
    }

    struct CertData: Codable { var phone: String; var ik: String; var exp: Int64 }
    struct Content: Codable { var cert: Certificate; var env: String }

    public struct Opened {
        public let sender: String
        public let senderIk: Data
        public let envelopeJson: String
    }

    public static func seal(sender: KeyPair, recipientIk: Data, cert: Certificate, envelopeJson: String) throws -> Box {
        let e = Primitives.x25519KeyPair()
        let okm1 = Primitives.hkdf(try Primitives.dh(e.privateKey, recipientIk), salt: e.publicKey + recipientIk, info: infoEph, length: 64)
        let chain1 = okm1.prefix(32), k1 = okm1.suffix(32)
        let encIk = try Primitives.aesGcmSeal(Data(k1), sender.publicKey, aad: e.publicKey)
        let k2 = Primitives.hkdf(try Primitives.dh(sender.privateKey, recipientIk), salt: Data(chain1) + encIk, info: infoStatic, length: 32)
        let content = try JSONEncoder().encode(Content(cert: cert, env: envelopeJson))
        let ct = try Primitives.aesGcmSeal(k2, content, aad: e.publicKey + encIk)
        return Box(eph: Primitives.b64(e.publicKey), ik: Primitives.b64(encIk), ct: Primitives.b64(ct))
    }

    /// Open a box addressed to `recipient` and check the certificate inside.
    public static func open(recipient: KeyPair, box: Box, serverKey: Data, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Opened {
        let ePub = try Primitives.unb64(box.eph)
        let encIk = try Primitives.unb64(box.ik)
        let okm1 = Primitives.hkdf(try Primitives.dh(recipient.privateKey, ePub), salt: ePub + recipient.publicKey, info: infoEph, length: 64)
        let senderIk = try Primitives.aesGcmOpen(Data(okm1.suffix(32)), encIk, aad: ePub)
        let k2 = Primitives.hkdf(try Primitives.dh(recipient.privateKey, senderIk), salt: Data(okm1.prefix(32)) + encIk, info: infoStatic, length: 32)
        let plain = try Primitives.aesGcmOpen(k2, try Primitives.unb64(box.ct), aad: ePub + encIk)
        let content = try JSONDecoder().decode(Content.self, from: plain)
        guard Primitives.verify(serverKey, try Primitives.unb64(content.cert.sig), Data(content.cert.data.utf8)) else {
            throw Failure.badCertificate
        }
        let data = try JSONDecoder().decode(CertData.self, from: Data(content.cert.data.utf8))
        guard data.exp > nowMs else { throw Failure.expired }
        guard try Primitives.unb64(data.ik) == senderIk else { throw Failure.wrongIdentity }
        return Opened(sender: data.phone, senderIk: senderIk, envelopeJson: content.env)
    }
}
