import Foundation

/// X3DH key agreement, identical to the Android client's `crypto/X3DH.kt`:
/// SK = HKDF(0xFF*32 || DH1 || DH2 || DH3 [|| DH4], salt = 0*32, "cellosig/x3dh/v1").
public enum X3DH {
    static let F = Data(repeating: 0xFF, count: 32)
    static let info = Data("cellosig/x3dh/v1".utf8)
    static let salt = Data(count: 32)

    public enum Failure: Error { case badSignedPreKey }

    public struct PreKeyBundle {
        public var identityKey: Data
        public var signingKey: Data
        public var signedPreKey: Data
        public var signedPreKeySig: Data
        public var oneTimePreKeyId: Int?
        public var oneTimePreKey: Data?
        public init(identityKey: Data, signingKey: Data, signedPreKey: Data, signedPreKeySig: Data,
                    oneTimePreKeyId: Int?, oneTimePreKey: Data?) {
            self.identityKey = identityKey; self.signingKey = signingKey
            self.signedPreKey = signedPreKey; self.signedPreKeySig = signedPreKeySig
            self.oneTimePreKeyId = oneTimePreKeyId; self.oneTimePreKey = oneTimePreKey
        }
    }

    public struct InitiatorResult {
        public let sharedSecret: Data
        public let ephemeralPublic: Data
        public let usedOneTimePreKeyId: Int?
        public let associatedData: Data   // IK_A || IK_B
    }

    /// Alice: verify Bob's signed prekey, then derive SK. `ephemeral` is for tests only.
    public static func initiator(myIdentity: KeyPair, bundle: PreKeyBundle, ephemeral: KeyPair? = nil) throws -> InitiatorResult {
        guard Primitives.verify(bundle.signingKey, bundle.signedPreKeySig, bundle.signedPreKey) else {
            throw Failure.badSignedPreKey
        }
        let ek = ephemeral ?? Primitives.x25519KeyPair()
        var ikm = F
        ikm += try Primitives.dh(myIdentity.privateKey, bundle.signedPreKey)
        ikm += try Primitives.dh(ek.privateKey, bundle.identityKey)
        ikm += try Primitives.dh(ek.privateKey, bundle.signedPreKey)
        if let opk = bundle.oneTimePreKey { ikm += try Primitives.dh(ek.privateKey, opk) }
        return InitiatorResult(
            sharedSecret: Primitives.hkdf(ikm, salt: salt, info: info, length: 32),
            ephemeralPublic: ek.publicKey,
            usedOneTimePreKeyId: bundle.oneTimePreKey == nil ? nil : bundle.oneTimePreKeyId,
            associatedData: myIdentity.publicKey + bundle.identityKey
        )
    }

    /// Bob: the same SK from his private keys and Alice's public ones.
    public static func responder(myIdentity: KeyPair, mySignedPreKey: KeyPair, oneTimePreKey: KeyPair?,
                                 initiatorIdentityPublic: Data, initiatorEphemeralPublic: Data) throws -> Data {
        var ikm = F
        ikm += try Primitives.dh(mySignedPreKey.privateKey, initiatorIdentityPublic)
        ikm += try Primitives.dh(myIdentity.privateKey, initiatorEphemeralPublic)
        ikm += try Primitives.dh(mySignedPreKey.privateKey, initiatorEphemeralPublic)
        if let opk = oneTimePreKey { ikm += try Primitives.dh(opk.privateKey, initiatorEphemeralPublic) }
        return Primitives.hkdf(ikm, salt: salt, info: info, length: 32)
    }

    public static func associatedData(initiator: Data, responder: Data) -> Data { initiator + responder }
}
