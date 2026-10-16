import Foundation

/// Double Ratchet, identical to the Android client's `crypto/DoubleRatchet.kt`:
///  - root step:  (RK, CK) = HKDF(dhOut, salt = RK, "cellosig/ratchet/rk", 64)
///  - chain step: MK = HMAC(CK, 0x01), CK' = HMAC(CK, 0x02)
///  - header = dhPub(32) || pn (u32 BE) || n (u32 BE); AAD = AD || header
///
/// A value type: `decrypt` mutates only on success when used as
/// `var s = state; let pt = try s.decrypt(...); state = s` (a forged or
/// garbled message must not advance the real session).
public struct DoubleRatchet: Codable, Equatable {
    static let maxSkip = 1000
    static let maxSkippedTotal = 2000
    static let infoRK = Data("cellosig/ratchet/rk".utf8)

    public enum Failure: Error { case noSendingChain, noReceivingChain, tooManySkipped }

    public var rootKey: Data
    public var dhsPriv: Data
    public var dhsPub: Data
    public var dhr: Data?
    public var cks: Data?
    public var ckr: Data?
    public var ns: Int
    public var nr: Int
    public var pn: Int
    /// "b64(dhr):n" -> message key, oldest first (trimmed from the front).
    public var skipped: [SkippedKey]

    public struct SkippedKey: Codable, Equatable {
        public var id: String
        public var mk: Data
    }

    public struct Header: Equatable {
        public var dhPub: Data
        public var pn: Int
        public var n: Int
        public init(dhPub: Data, pn: Int, n: Int) { self.dhPub = dhPub; self.pn = pn; self.n = n }
        public var bytes: Data { dhPub + Data.u32(pn) + Data.u32(n) }
    }

    // MARK: Init
    public static func initiator(sharedSecret: Data, remoteSignedPreKey: Data, ratchetKey: KeyPair? = nil) throws -> DoubleRatchet {
        let dhs = ratchetKey ?? Primitives.x25519KeyPair()
        let (rk, cks) = kdfRoot(sharedSecret, try Primitives.dh(dhs.privateKey, remoteSignedPreKey))
        return DoubleRatchet(rootKey: rk, dhsPriv: dhs.privateKey, dhsPub: dhs.publicKey, dhr: remoteSignedPreKey,
                             cks: cks, ckr: nil, ns: 0, nr: 0, pn: 0, skipped: [])
    }

    public static func responder(sharedSecret: Data, signedPreKey: KeyPair) -> DoubleRatchet {
        DoubleRatchet(rootKey: sharedSecret, dhsPriv: signedPreKey.privateKey, dhsPub: signedPreKey.publicKey,
                      dhr: nil, cks: nil, ckr: nil, ns: 0, nr: 0, pn: 0, skipped: [])
    }

    static func kdfRoot(_ rk: Data, _ dhOut: Data) -> (Data, Data) {
        let out = Primitives.hkdf(dhOut, salt: rk, info: infoRK, length: 64)
        return (Data(out.prefix(32)), Data(out.suffix(32)))
    }

    static func kdfChain(_ ck: Data) -> (next: Data, mk: Data) {
        (Primitives.hmacSha256(ck, Data([0x02])), Primitives.hmacSha256(ck, Data([0x01])))
    }

    // MARK: Encrypt / decrypt
    public mutating func encrypt(_ plaintext: Data, ad: Data) throws -> (Header, Data) {
        guard let ck = cks else { throw Failure.noSendingChain }
        let step = Self.kdfChain(ck)
        cks = step.next
        let header = Header(dhPub: dhsPub, pn: pn, n: ns)
        ns += 1
        let ct = try Primitives.aesGcmSeal(step.mk, plaintext, aad: ad + header.bytes)
        return (header, ct)
    }

    public mutating func decrypt(_ header: Header, _ ciphertext: Data, ad: Data) throws -> Data {
        let sk = Self.skipId(header.dhPub, header.n)
        if let i = skipped.firstIndex(where: { $0.id == sk }) {
            let pt = try Primitives.aesGcmOpen(skipped[i].mk, ciphertext, aad: ad + header.bytes)
            skipped.remove(at: i)
            return pt
        }
        if dhr == nil || header.dhPub != dhr {
            try skipMessageKeys(until: header.pn)
            try dhRatchet(header)
        }
        try skipMessageKeys(until: header.n)
        guard let ck = ckr else { throw Failure.noReceivingChain }
        let step = Self.kdfChain(ck)
        ckr = step.next
        nr += 1
        return try Primitives.aesGcmOpen(step.mk, ciphertext, aad: ad + header.bytes)
    }

    private mutating func skipMessageKeys(until: Int) throws {
        guard var chain = ckr else { return }
        if nr + Self.maxSkip < until { throw Failure.tooManySkipped }
        while nr < until {
            let step = Self.kdfChain(chain)
            skipped.append(SkippedKey(id: Self.skipId(dhr!, nr), mk: step.mk))
            chain = step.next
            nr += 1
        }
        ckr = chain
        if skipped.count > Self.maxSkippedTotal { skipped.removeFirst(skipped.count - Self.maxSkippedTotal) }
    }

    private mutating func dhRatchet(_ header: Header) throws {
        pn = ns
        ns = 0
        nr = 0
        dhr = header.dhPub
        let recv = Self.kdfRoot(rootKey, try Primitives.dh(dhsPriv, header.dhPub))
        rootKey = recv.0
        ckr = recv.1
        let fresh = Primitives.x25519KeyPair()
        dhsPriv = fresh.privateKey
        dhsPub = fresh.publicKey
        let send = Self.kdfRoot(rootKey, try Primitives.dh(dhsPriv, header.dhPub))
        rootKey = send.0
        cks = send.1
    }

    static func skipId(_ dhPub: Data, _ n: Int) -> String { "\(Primitives.b64(dhPub)):\(n)" }
}

/// One peer's session: the ratchet plus AD = IK_initiator || IK_responder.
public struct Session: Codable, Equatable {
    public var ratchet: DoubleRatchet
    public var ad: Data

    public init(ratchet: DoubleRatchet, ad: Data) { self.ratchet = ratchet; self.ad = ad }

    /// The peer's identity key bound into this session.
    public func peerIdentityKey(myIdentityPublic: Data) -> Data? {
        guard ad.count == 64 else { return nil }
        let first = ad.prefix(32), second = ad.suffix(32)
        return Data(first) == myIdentityPublic ? Data(second) : Data(first)
    }
}
