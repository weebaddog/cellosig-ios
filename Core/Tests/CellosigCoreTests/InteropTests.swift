import CellosigCore
import Foundation
import XCTest

/// Interop with the Node implementation (Interop/interop.mjs), which is the
/// same code the relay's test bot uses to talk to the Android app.
/// Needs CELLOSIG_INTEROP=<dir> holding vectors.json; writes swift-out.json there.
final class InteropTests: XCTestCase {
    struct KP: Codable { var priv: String; var pub: String
        var pair: KeyPair { KeyPair(privateKey: try! Primitives.unb64(priv), publicKey: try! Primitives.unb64(pub)) } }
    struct Vectors: Decodable {
        struct Bob: Decodable { var phone: String; var ik: KP; var ed: KP; var spk: KP; var opk: KP; var opkId: Int }
        struct Deliver: Decodable { var envelope: Envelope; var body: String }
        struct Sealed: Decodable { var box: SealedSender.Box; var sender: String; var body: String }
        struct Dave: Decodable { var phone: String; var bundle: ServedBundle }
        struct Carol: Decodable { var phone: String; var ik: KP }
        struct File: Decodable { var key: String; var blob: String; var sha256: String }
        struct Safety: Decodable { var a: String; var aKey: String; var b: String; var bKey: String; var expected: String }
        struct Hkdf: Decodable { var ikm: String; var salt: String; var info: String; var out: String }
        var server: KP; var bob: Bob; var deliver: [Deliver]; var sealed: Sealed; var dave: Dave; var carol: Carol
        var file: File; var safety: Safety; var hkdf: Hkdf
    }
    struct Out: Encodable {
        struct Msg: Encodable { var envelope: Envelope; var body: String }
        struct SealedOut: Encodable { var box: SealedSender.Box; var body: String }
        struct FileOut: Encodable { var key: String; var blob: String; var sha256: String; var size: Int }
        var replies: [Msg]; var toDave: [Msg]; var sealedToDave: SealedOut; var file: FileOut; var bundle: PublicBundle
    }

    func testInterop() throws {
        guard let dir = ProcessInfo.processInfo.environment["CELLOSIG_INTEROP"] else {
            throw XCTSkip("set CELLOSIG_INTEROP to run the Node interop check")
        }
        let dirURL = URL(fileURLWithPath: dir)
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: dirURL.appendingPathComponent("vectors.json")))

        // HKDF and the safety number match Node exactly.
        XCTAssertEqual(Primitives.b64(Primitives.hkdf(try Primitives.unb64(v.hkdf.ikm), salt: try Primitives.unb64(v.hkdf.salt),
                                                       info: Data(v.hkdf.info.utf8), length: 64)), v.hkdf.out)
        XCTAssertEqual(SafetyNumber.generate(localId: v.safety.a, localIdentity: try Primitives.unb64(v.safety.aKey),
                                             remoteId: v.safety.b, remoteIdentity: try Primitives.unb64(v.safety.bKey)), v.safety.expected)
        XCTAssertEqual(SafetyNumber.generate(localId: v.safety.b, localIdentity: try Primitives.unb64(v.safety.bKey),
                                             remoteId: v.safety.a, remoteIdentity: try Primitives.unb64(v.safety.aKey)), v.safety.expected)

        // 1. We are bob: accept node alice's session (with a one-time prekey) and read out-of-order messages.
        let bob = v.bob
        var session: Session?
        for d in v.deliver {
            let e = d.envelope
            if e.kind == "prekey" {
                XCTAssertEqual(e.opkId, bob.opkId)
                let sk = try X3DH.responder(myIdentity: bob.ik.pair, mySignedPreKey: bob.spk.pair, oneTimePreKey: bob.opk.pair,
                                            initiatorIdentityPublic: try Primitives.unb64(e.ikPub!), initiatorEphemeralPublic: try Primitives.unb64(e.ekPub!))
                session = Session(ratchet: .responder(sharedSecret: sk, signedPreKey: bob.spk.pair),
                                  ad: X3DH.associatedData(initiator: try Primitives.unb64(e.ikPub!), responder: bob.ik.pair.publicKey))
            }
            let pt = try session!.ratchet.decrypt(.init(dhPub: try Primitives.unb64(e.dhPub), pn: e.pn, n: e.n), try Primitives.unb64(e.ct), ad: session!.ad)
            XCTAssertEqual(pt.count % 256, 0, "payloads are padded to 256-byte blocks")
            let p = Payload.decode(pt)
            XCTAssertEqual(p.body, d.body)
            XCTAssertNotNil(p.ak)
        }

        // A forged message must not disturb the session.
        let before = session!
        var forged = session!.ratchet
        XCTAssertThrowsError(try forged.decrypt(.init(dhPub: Primitives.x25519KeyPair().publicKey, pn: 0, n: 0), Primitives.randomBytes(60), ad: session!.ad))
        XCTAssertEqual(session, before)

        // 2. A sealed message from alice.
        let opened = try SealedSender.open(recipient: bob.ik.pair, box: v.sealed.box, serverKey: v.server.pair.publicKey)
        XCTAssertEqual(opened.sender, v.sealed.sender)
        let env5 = try JSONDecoder().decode(Envelope.self, from: Data(opened.envelopeJson.utf8))
        let pt5 = try session!.ratchet.decrypt(.init(dhPub: try Primitives.unb64(env5.dhPub), pn: env5.pn, n: env5.n), try Primitives.unb64(env5.ct), ad: session!.ad)
        XCTAssertEqual(Payload.decode(pt5).body, v.sealed.body)
        // Tampered: wrong server key -> rejected.
        XCTAssertThrowsError(try SealedSender.open(recipient: bob.ik.pair, box: v.sealed.box, serverKey: Primitives.ed25519KeyPair().publicKey))

        // Replies (forces a DH ratchet step on both sides).
        var replies: [Out.Msg] = []
        for body in ["reply from swift", "another reply ✅"] {
            let (h, ct) = try session!.ratchet.encrypt(try Payload(t: "text", id: UUID().uuidString, body: body).encode(), ad: session!.ad)
            replies.append(.init(envelope: Envelope(kind: "normal", dhPub: Primitives.b64(h.dhPub), pn: h.pn, n: h.n, ct: Primitives.b64(ct)), body: body))
        }

        // 3. We are carol: start a session with node dave from his served bundle.
        let carol = v.carol.ik.pair
        let b = v.dave.bundle
        let x3 = try X3DH.initiator(myIdentity: carol, bundle: X3DH.PreKeyBundle(
            identityKey: try Primitives.unb64(b.identityKey), signingKey: try Primitives.unb64(b.signingKey),
            signedPreKey: try Primitives.unb64(b.signedPreKey), signedPreKeySig: try Primitives.unb64(b.signedPreKeySig),
            oneTimePreKeyId: b.oneTimePreKey?.id, oneTimePreKey: try b.oneTimePreKey.map { try Primitives.unb64($0.key) }))
        var toDave = Session(ratchet: try .initiator(sharedSecret: x3.sharedSecret, remoteSignedPreKey: try Primitives.unb64(b.signedPreKey)), ad: x3.associatedData)
        var daveMsgs: [Out.Msg] = []
        for (i, body) in ["hi dave, swift here", "second to dave"].enumerated() {
            let (h, ct) = try toDave.ratchet.encrypt(try Payload(t: "text", id: "c\(i)", body: body).encode(), ad: toDave.ad)
            var env = Envelope(kind: "normal", dhPub: Primitives.b64(h.dhPub), pn: h.pn, n: h.n, ct: Primitives.b64(ct))
            if i == 0 { env.kind = "prekey"; env.ikPub = Primitives.b64(carol.publicKey); env.ekPub = Primitives.b64(x3.ephemeralPublic); env.opkId = x3.usedOneTimePreKeyId }
            daveMsgs.append(.init(envelope: env, body: body))
        }
        // Sealed to dave, with a certificate "the relay" (test server key) signed.
        let certData = Wire.json(["phone": AnyEncodable(v.carol.phone), "ik": AnyEncodable(Primitives.b64(carol.publicKey)),
                                  "exp": AnyEncodable(Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000)])
        let cert = SealedSender.Certificate(data: certData, sig: Primitives.b64(try Primitives.sign(v.server.pair.privateKey, Data(certData.utf8))))
        let (hs, cts) = try toDave.ratchet.encrypt(try Payload(t: "text", id: "c-sealed", body: "sealed to dave").encode(), ad: toDave.ad)
        let box = try SealedSender.seal(sender: carol, recipientIk: try Primitives.unb64(b.identityKey), cert: cert,
                                        envelopeJson: Wire.json(Envelope(kind: "normal", dhPub: Primitives.b64(hs.dhPub), pn: hs.pn, n: hs.n, ct: Primitives.b64(cts))))

        // 4. Attachments both ways.
        let nodeFile = try ChunkedAead.decrypt(try Primitives.unb64(v.file.blob), key: try Primitives.unb64(v.file.key))
        XCTAssertEqual(Primitives.sha256Hex(nodeFile), v.file.sha256)
        let mine = Primitives.randomBytes(200_000), mineKey = Primitives.randomBytes(32)
        let mineBlob = try ChunkedAead.encrypt(mine, key: mineKey)
        XCTAssertEqual(try ChunkedAead.decrypt(mineBlob, key: mineKey), mine)
        var cut = mineBlob; cut.removeLast(70_000)  // truncated after a non-final chunk
        XCTAssertThrowsError(try ChunkedAead.decrypt(cut, key: mineKey))

        // 5. A signed prekey signature for node to verify.
        let ed = Primitives.ed25519KeyPair(), spk = Primitives.x25519KeyPair()
        let bundle = PublicBundle(identityKey: Primitives.b64(carol.publicKey), signingKey: Primitives.b64(ed.publicKey),
                                  signedPreKey: Primitives.b64(spk.publicKey), signedPreKeySig: Primitives.b64(try Primitives.sign(ed.privateKey, spk.publicKey)),
                                  oneTimePreKeys: [])

        let out = Out(replies: replies, toDave: daveMsgs, sealedToDave: .init(box: box, body: "sealed to dave"),
                      file: .init(key: Primitives.b64(mineKey), blob: Primitives.b64(mineBlob), sha256: Primitives.sha256Hex(mine), size: mine.count),
                      bundle: bundle)
        try Wire.encoder.encode(out).write(to: dirURL.appendingPathComponent("swift-out.json"))
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to e: Encoder) throws { try value.encode(to: e) }
}
