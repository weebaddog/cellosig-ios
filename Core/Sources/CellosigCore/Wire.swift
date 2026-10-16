import Foundation

// Wire types shared with the relay and the Android client (`net/Protocol.kt`,
// `net/Payload.kt`). JSON field names must not change.

public struct OneTimePreKey: Codable, Equatable {
    public var id: Int
    public var key: String
    public init(id: Int, key: String) { self.id = id; self.key = key }
}

public struct PublicBundle: Codable, Equatable {
    public var identityKey: String
    public var signingKey: String
    public var signedPreKey: String
    public var signedPreKeySig: String
    public var oneTimePreKeys: [OneTimePreKey]
    public init(identityKey: String, signingKey: String, signedPreKey: String, signedPreKeySig: String, oneTimePreKeys: [OneTimePreKey]) {
        self.identityKey = identityKey; self.signingKey = signingKey; self.signedPreKey = signedPreKey
        self.signedPreKeySig = signedPreKeySig; self.oneTimePreKeys = oneTimePreKeys
    }
}

/// One peer's bundle as the relay serves it, with at most one OPK.
public struct ServedBundle: Codable, Equatable {
    public var username: String
    public var identityKey: String
    public var signingKey: String
    public var signedPreKey: String
    public var signedPreKeySig: String
    public var oneTimePreKey: OneTimePreKey?
}

/// The end-to-end encrypted envelope (opaque to the relay).
public struct Envelope: Codable, Equatable {
    public var kind: String          // "prekey" | "normal"
    public var dhPub: String
    public var pn: Int
    public var n: Int
    public var ct: String
    public var ikPub: String?
    public var ekPub: String?
    public var opkId: Int?
    public init(kind: String, dhPub: String, pn: Int, n: Int, ct: String, ikPub: String? = nil, ekPub: String? = nil, opkId: Int? = nil) {
        self.kind = kind; self.dhPub = dhPub; self.pn = pn; self.n = n; self.ct = ct
        self.ikPub = ikPub; self.ekPub = ekPub; self.opkId = opkId
    }
}

public struct IceServer: Codable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    enum CodingKeys: String, CodingKey { case urls, username, credential }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let one = try? c.decode(String.self, forKey: .urls) { urls = [one] } else { urls = try c.decode([String].self, forKey: .urls) }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

public struct CallSignal: Codable, Equatable {
    public var id: String
    public var kind: String      // offer | answer | ringing | hangup | busy | progress
    public var sdp: String?
    public var reason: String?
    public init(id: String, kind: String, sdp: String? = nil, reason: String? = nil) {
        self.id = id; self.kind = kind; self.sdp = sdp; self.reason = reason
    }
}

/// Anything the relay sends. Parsed leniently: every field optional except `type`.
public struct InboundFrame: Decodable {
    public var type: String
    public var username: String?
    public var bundle: ServedBundle?
    public var from: String?
    public var to: String?
    public var envelope: Envelope?
    public var ts: Int64?
    public var id: String?
    public var reason: String?
    public var count: Int?
    public var phone: String?
    public var token: String?
    public var registered: [String]?
    public var iceServers: [IceServer]?
    public var age: Int64?
    public var mid: Int64?
    public var sealed: SealedSender.Box?
    public var cert: SealedSender.Certificate?
    public var serverKey: String?
    public var onion: String?
    public var pstn: Bool?
    public var call: CallSignal?
    public var callerName: String?
    public var error: String?

    public static func parse(_ text: String) -> InboundFrame? {
        try? JSONDecoder().decode(InboundFrame.self, from: Data(text.utf8))
    }
}

// MARK: - Payload (inside the encryption)

public struct FileRef: Codable, Equatable {
    public var blob: String
    public var key: String
    public var name: String
    public var mime: String
    public var size: Int64
    public var kind: String?
    public init(blob: String, key: String, name: String, mime: String, size: Int64, kind: String? = nil) {
        self.blob = blob; self.key = key; self.name = name; self.mime = mime; self.size = size; self.kind = kind
    }
}

public struct ProfileDto: Codable, Equatable {
    public var name: String?
    public var photo: String?
    public init(name: String?, photo: String?) { self.name = name; self.photo = photo }
}

public struct PollDto: Codable, Equatable {
    public var options: [String]
    public var multi: Bool
    public init(options: [String], multi: Bool) { self.options = options; self.multi = multi }
    enum CodingKeys: String, CodingKey { case options, multi }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        options = try c.decode([String].self, forKey: .options)
        multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
    }
}

public struct GroupRef: Codable, Equatable {
    public var id: String
    public var name: String?
    public var members: [String]?
    public init(id: String, name: String? = nil, members: [String]? = nil) { self.id = id; self.name = name; self.members = members }
}

/// What travels inside the end-to-end encryption. Kinds (`t`): text, file,
/// receipt, group, timer, poll, vote, reaction, call, profile, reset.
public struct Payload: Codable, Equatable {
    public var t: String
    public var id: String?
    public var body: String?
    public var receipt: String?
    public var ids: [String]?
    public var file: FileRef?
    public var group: GroupRef?
    public var call: CallSignal?
    public var expire: Int?
    public var ak: String?
    public var target: String?
    public var emoji: String?
    public var choices: [Int]?
    public var poll: PollDto?
    public var profile: ProfileDto?

    public init(t: String, id: String? = nil, body: String? = nil, receipt: String? = nil, ids: [String]? = nil,
                file: FileRef? = nil, group: GroupRef? = nil, call: CallSignal? = nil, expire: Int? = nil,
                ak: String? = nil, target: String? = nil, emoji: String? = nil, choices: [Int]? = nil,
                poll: PollDto? = nil, profile: ProfileDto? = nil) {
        self.t = t; self.id = id; self.body = body; self.receipt = receipt; self.ids = ids; self.file = file
        self.group = group; self.call = call; self.expire = expire; self.ak = ak; self.target = target
        self.emoji = emoji; self.choices = choices; self.poll = poll; self.profile = profile
    }

    static let padBlock = 256

    /// JSON padded with spaces to a multiple of 256 bytes (hides message length).
    public func encode() throws -> Data {
        var raw = try Wire.encoder.encode(self)
        let padded = max(1, (raw.count + Self.padBlock - 1) / Self.padBlock) * Self.padBlock
        raw.append(Data(repeating: 0x20, count: padded - raw.count))
        return raw
    }

    /// Older builds sent bare UTF-8 text; anything that isn't a payload is that.
    public static func decode(_ bytes: Data) -> Payload {
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{"), let p = try? JSONDecoder().decode(Payload.self, from: Data(s.utf8)) { return p }
        return Payload(t: "text", body: s)
    }
}

public enum Wire {
    /// No "\/" escaping, so our JSON looks like the Android/Node clients' (both parse either way).
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static func json<T: Encodable>(_ v: T) -> String {
        String(decoding: (try? encoder.encode(v)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
