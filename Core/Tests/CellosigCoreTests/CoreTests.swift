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

    func testTimeParser() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday 14 October 2026, 10:00.
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10, minute: 0, second: 30))!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        func find(_ s: String) -> TimeParser.Suggestion? { TimeParser.find(s, now: now, calendar: cal) }

        XCTAssertEqual(find("see you tomorrow at 5"), .init(at: at(15, 17), label: "Tomorrow 5:00 PM"))
        XCTAssertEqual(find("call me in 2 hours")?.at, at(14, 12))
        XCTAssertEqual(find("back in half an hour")?.at, at(14, 10, 30))
        XCTAssertEqual(find("dinner friday 7pm"), .init(at: at(16, 19), label: "Friday 7:00 PM"))
        XCTAssertEqual(find("meet at 9am wednesday"), .init(at: at(21, 9), label: "Oct 21 9:00 AM"), "today's 9am has passed: next week")
        XCTAssertEqual(find("lunch at noon"), .init(at: at(14, 12), label: "Today 12:00 PM"))
        XCTAssertEqual(find("ok 8:15 am")?.at, at(15, 8, 15), "a bare time that's passed means tomorrow")
        XCTAssertEqual(find("party tonight")?.at, at(14, 20))
        XCTAssertNil(find("no time in here"))
        XCTAssertNil(find("in 0 minutes"), "not in the future")
    }

    func testProfileNames() {
        XCTAssertEqual(Profiles.cleanName("  Al\u{202E}ex \n  Smith "), "Alex Smith")
        XCTAssertNil(Profiles.cleanName("\u{200B}\u{200B}"))
        XCTAssertEqual(Profiles.cleanName(String(repeating: "a", count: 60))?.count, 40)
    }
}
