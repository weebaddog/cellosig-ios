import CellosigCore
import Foundation
import XCTest

/// Self-contained checks (no Node needed).
final class CoreTests: XCTestCase {
    func testRatchetRoundTripAndOutOfOrder() throws {
        let aliceIk = Primitives.x25519KeyPair(), bobIk = Primitives.x25519KeyPair()
        let bobEd = Primitives.ed25519KeyPair(), bobSpk = Primitives.x25519KeyPair(), bobOpk = Primitives.x25519KeyPair()
        let x3 = try X3DH.initiator(myIdentity: aliceIk, bundle: .init(
            identityKey: bobIk.publicKey, signingKey: bobEd.publicKey, signedPreKey: bobSpk.publicKey,
            signedPreKeySig: try Primitives.sign(bobEd.privateKey, bobSpk.publicKey), oneTimePreKeyId: 1, oneTimePreKey: bobOpk.publicKey))
        var a = Session(ratchet: try .initiator(sharedSecret: x3.sharedSecret, remoteSignedPreKey: bobSpk.publicKey), ad: x3.associatedData)
        let skB = try X3DH.responder(myIdentity: bobIk, mySignedPreKey: bobSpk, oneTimePreKey: bobOpk,
                                     initiatorIdentityPublic: aliceIk.publicKey, initiatorEphemeralPublic: x3.ephemeralPublic)
        XCTAssertEqual(skB, x3.sharedSecret)
        var b = Session(ratchet: .responder(sharedSecret: skB, signedPreKey: bobSpk), ad: X3DH.associatedData(initiator: aliceIk.publicKey, responder: bobIk.publicKey))

        let m = try (0..<5).map { try a.ratchet.encrypt(Data("a\($0)".utf8), ad: a.ad) }
        for i in [0, 3, 1, 4, 2] {
            XCTAssertEqual(String(decoding: try b.ratchet.decrypt(m[i].0, m[i].1, ad: b.ad), as: UTF8.self), "a\(i)")
        }
        let r = try b.ratchet.encrypt(Data("back".utf8), ad: b.ad)
        XCTAssertEqual(String(decoding: try a.ratchet.decrypt(r.0, r.1, ad: a.ad), as: UTF8.self), "back")
        // Survives a Codable round trip (how sessions are stored).
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(restored, a)
    }

    func testBadSignedPreKeyRejected() {
        let ed = Primitives.ed25519KeyPair(), spk = Primitives.x25519KeyPair()
        XCTAssertThrowsError(try X3DH.initiator(myIdentity: Primitives.x25519KeyPair(), bundle: .init(
            identityKey: Primitives.x25519KeyPair().publicKey, signingKey: ed.publicKey, signedPreKey: spk.publicKey,
            signedPreKeySig: Primitives.randomBytes(64), oneTimePreKeyId: nil, oneTimePreKey: nil)))
    }

    func testPayloadPaddingAndLegacyText() throws {
        let enc = try Payload(t: "text", id: "x", body: "hi").encode()
        XCTAssertEqual(enc.count, 256)
        XCTAssertEqual(Payload.decode(enc).body, "hi")
        XCTAssertEqual(Payload.decode(Data("plain old text".utf8)).t, "text")
        XCTAssertFalse(String(decoding: enc, as: UTF8.self).contains("null"), "absent fields are omitted, like Android")
    }

    func testPhoneNumbers() {
        XCTAssertEqual(PhoneNumbers.normalize("(555) 234-0049", countryCode: "1"), "+15552340049")
        XCTAssertEqual(PhoneNumbers.normalize("011 44 7911 123456", countryCode: "1"), "+447911123456")
        XCTAssertEqual(PhoneNumbers.normalize("07911 123456", countryCode: "44"), "+447911123456")
        XCTAssertNil(PhoneNumbers.normalize("12345", countryCode: "1"))
        XCTAssertEqual(PhoneNumbers.pretty("+15551234567"), "+1 555-123-4567")
        XCTAssertEqual(PhoneNumbers.mask("+15552340049"), "+1••••••••49")
    }

    func testProfileNames() {
        XCTAssertEqual(Profiles.cleanName("  Al\u{202E}ex \n  Smith "), "Alex Smith")
        XCTAssertNil(Profiles.cleanName("\u{200B}\u{200B}"))
        XCTAssertEqual(Profiles.cleanName(String(repeating: "a", count: 60))?.count, 40)
    }
}
