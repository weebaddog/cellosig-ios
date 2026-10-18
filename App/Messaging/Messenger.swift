import CellosigCore
import Foundation
import os
import UniformTypeIdentifiers

/// The messaging engine (the iOS port of the Android client's MessagingService).
///
/// Everything runs on the main actor: encryption and decryption are short,
/// synchronous steps, so within this process each is atomic. The app's
/// notification extension is another process sharing the same keys, so each
/// such step also runs under CrossProcessLock and reads its session from disk.
/// Anything that waits on the relay (fetching a bundle, uploading a file)
/// suspends between steps, never in the middle of one.
@MainActor
final class Messenger: ObservableObject {
    static let groupPrefix = "g:"
    static let systemPrefix = "sys:"
    static let timerChoices = [0, 30, 5 * 60, 3600, 8 * 3600, 86_400, 7 * 86_400]

    private static let otpkTarget = 20
    private static let otpkLow = 5
    private static let resetMinIntervalMs: Int64 = 60_000
    private static let resendWindowMs: Int64 = 48 * 3600_000
    private static let autoRetryWindowMs: Int64 = 24 * 3600_000
    private static let certRefreshMs: Int64 = 12 * 3600_000
    private static let autoDownloadBytes: Int64 = 25 * 1024 * 1024
    static let maxFileBytes: Int64 = 90 * 1024 * 1024
    private static let groupIdPattern = #"^[A-Za-z0-9-]{8,64}$"#

    let log = Logger(subsystem: "com.cellosig.app", category: "cellosig")

    private(set) var account: Account
    var me: String { account.phone }
    /// Running inside the notification extension: fetch, decrypt, store, then quit.
    let isExtension: Bool

    #if DEBUG
    static let pushEnv = "sandbox"
    #else
    static let pushEnv = "production"
    #endif
    let db: Database
    let identity: IdentityStore
    private let sessions = SessionStore()
    let accessKeys = AccessKeys()
    private let seenStarts = SeenSessionStarts()
    let ownProfile = OwnProfile()
    private let relay: RelayClient
    private let sealedRelay: RelayClient
    private(set) var blobs: BlobClient

    /// Bumped on every change the UI shows; views re-read what they need.
    @Published private(set) var revision = 0
    @Published private(set) var connected = false
    @Published var authFailed = false
    @Published private(set) var pstnAvailable = false

    /// The chat on screen (its messages are read as they arrive).
    var activeChat: String?
    var readReceipts: Bool {
        get { Shared.defaults.object(forKey: "read_receipts") as? Bool ?? true }
        set { Shared.defaults.set(newValue, forKey: "read_receipts"); touch() }
    }
    /// New incoming message the user isn't looking at: (conversation, sender, preview).
    var onIncoming: ((String, String, String) -> Void)?
    var onCallSignal: ((String, CallSignal, Int64) -> Void)?
    /// Phone-call signalling from the relay's bridge: (number, signal, network caller name, refusal reason).
    var onPstnSignal: ((String, CallSignal, String?, String?) -> Void)?

    private var pendingBundles: [String: (ticket: UUID, waiters: [CheckedContinuation<ServedBundle, Error>])] = [:]
    private var pendingLookups: [(ticket: UUID, c: CheckedContinuation<[String], Never>)] = []
    private var pendingIce: [(ticket: UUID, c: CheckedContinuation<[IceServer], Never>)] = []
    private var pendingSealed: [String: (peer: String, row: Int64?)] = [:]
    private var lastResetRequest: [String: Int64] = [:]
    private var inFlight = Set<Int64>()
    private var senderCert: SealedSender.Certificate?
    private var certWaiters: [CheckedContinuation<Void, Never>] = []
    private var expiryTimer: Timer?

    enum SendError: Error { case notRegistered(String), timeout, toSelf, noSession, offline }

    init(account: Account, extensionMode: Bool = false) throws {
        self.account = account
        isExtension = extensionMode
        db = try Database()
        identity = try IdentityStore.loadOrCreate(phone: account.phone)
        let url = URL(string: account.relayURL)!
        relay = RelayClient(url: url)
        sealedRelay = RelayClient(url: url)
        blobs = BlobClient(relay: url, user: account.phone, token: account.token)
        relay.onFrame = { [weak self] in self?.handleInbound($0) }
        relay.onConnected = { [weak self] in self?.onConnected() }
        relay.onDisconnected = { [weak self] in self?.connected = false }
        sealedRelay.onFrame = { [weak self] in self?.handleSealedReply($0) }
    }

    func start() {
        relay.connect()
        if isExtension { return }
        sealedRelay.connect()
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireMessages() }
        }
        expireMessages()
    }

    func stop() {
        relay.close()
        sealedRelay.close()
        expiryTimer?.invalidate()
    }

    func foregrounded() {
        // The notification extension may have moved us to a new relay address meanwhile.
        if let a = Account.load(), a.relayURL != account.relayURL { moveRelay(to: a.relayURL) }
        relay.reconnectNow()
        sealedRelay.reconnectNow()
        touch()  // it may also have stored messages
    }

    /// The relay announced (signed) that it now lives at `url`.
    func moveRelay(to url: String) {
        guard let u = URL(string: url) else { return }
        account.relayURL = url
        log.info("relay moved; following it")
        blobs = BlobClient(relay: u, user: account.phone, token: account.token)
        relay.move(to: u)
        sealedRelay.move(to: u)
    }

    // MARK: - Push notifications

    private struct SetPush: Encodable { var type = "setPush"; var token: String; var env: String; var voip: String? }

    private func sendPushTokens() {
        guard relay.isConnected, let t = Shared.defaults.string(forKey: "apns_token") else { return }
        relay.send(SetPush(token: t, env: Self.pushEnv, voip: Shared.defaults.string(forKey: "voip_token")))
    }

    /// The APNs device token (hex) for this iPhone; the relay uses it to wake us.
    func setPushToken(_ hex: String) {
        Shared.defaults.set(hex, forKey: "apns_token")
        sendPushTokens()
    }

    /// The PushKit token: the relay rings us with it when a call comes in.
    func setVoipToken(_ hex: String) {
        Shared.defaults.set(hex, forKey: "voip_token")
        sendPushTokens()
    }

    /// A VoIP push woke us for a call: get a fresh connection (the old socket
    /// may have died while we were suspended) and collect what's waiting.
    func wakeForCall() {
        loggedIn = false
        lastActivity = Date()
        relay.close()
        relay.connect()
        sealedRelay.reconnectNow()
    }

    // For the extension: when has the relay finished handing us mail?
    private var loggedIn = false
    private var lastActivity = Date()
    private var pendingOps = 0

    /// Wait until signed in, everything queued is handled, and the relay has been quiet a moment.
    func waitUntilQuiet(maxSeconds: Double) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if loggedIn && inbound.isEmpty && !draining && pendingOps == 0 && Date().timeIntervalSince(lastActivity) > 1.5 { return }
        }
    }

    func touch() { revision &+= 1 }

    private func newId() -> String { UUID().uuidString.lowercased() }

    // MARK: - Connection

    private struct RegisterFrame: Encodable { var type = "register"; var username: String; var token: String; var bundle: PublicBundle; var accessKeyHash: String }
    private struct LoginFrame: Encodable { var type = "login"; var username: String; var token: String }
    private struct Simple: Encodable { var type: String }
    private struct AddPreKeys: Encodable { var type = "addPreKeys"; var oneTimePreKeys: [OneTimePreKey] }
    private struct Received: Encodable { var type = "received"; var mid: Int64 }
    private struct GetBundle: Encodable { var type = "getBundle"; var username: String }
    private struct Lookup: Encodable { var type = "lookup"; var phones: [String] }
    // call: a call offer, so the relay can ring an iPhone through VoIP push (it can't read the message).
    private struct SendFrame: Encodable { var type = "send"; var to: String; var envelope: Envelope; var id: String?; var eph: Bool?; var call: Bool? }
    private struct SendSealed: Encodable { var type = "sendSealed"; var to: String; var ak: String; var sealed: SealedSender.Box; var id: String; var eph: Bool?; var call: Bool? }

    private func onConnected() {
        connected = true
        lastActivity = Date()
        log.info("connected to relay")
        if isExtension {
            // Just collect mail; the app does the rest when it next opens.
            relay.send(LoginFrame(username: me, token: account.token))
            relay.send(Simple(type: "getSenderCert"))
            return
        }
        if let bundle = try? identity.publicBundle(otpkCount: Self.otpkTarget) {
            relay.send(RegisterFrame(username: me, token: account.token, bundle: bundle, accessKeyHash: accessKeys.ownHash))
        }
        relay.send(Simple(type: "getSenderCert"))
        relay.send(Simple(type: "getPreKeyCount"))
        sendPushTokens()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await retryUnsent()
            try? db.run("DELETE FROM seen_frames WHERE at < ?", nowMs() - 60 * 86_400_000)
        }
    }

    private func replenishPreKeys(_ serverCount: Int) {
        guard serverCount <= Self.otpkLow else { return }
        let n = Self.otpkTarget - serverCount
        guard n > 0, let fresh = try? identity.generateOneTimePreKeys(n) else { return }
        relay.send(AddPreKeys(oneTimePreKeys: fresh))
    }

    // MARK: - Inbound frames

    private func handleInbound(_ f: InboundFrame) {
        lastActivity = Date()
        switch f.type {
        case "bundle":
            if let b = f.bundle { resolveBundle(b.username, .success(b)) }
        case "message":
            // Strictly in arrival order: a session's first message must be read before the next.
            inbound.append(f)
            if !draining { draining = true; Task { await drainInbound() } }
        case "ack":
            if let row = f.id.flatMap({ Int64($0) }) { markSent(row) }
        case "preKeysLow", "preKeyCount":
            replenishPreKeys(f.count ?? 0)
        case "lookupResult":
            if !pendingLookups.isEmpty { pendingLookups.removeFirst().c.resume(returning: f.registered ?? []) }
        case "senderCert":
            if let cert = f.cert, let key = f.serverKey, let raw = try? Primitives.unb64(key), raw.count == 32 {
                senderCert = cert
                try? Vault.shared.writeSealed(Paths.keys.appendingPathComponent("relay_cert.bin"), raw)
                certWaiters.forEach { $0.resume() }
                certWaiters = []
            }
        case "accountDeleted":
            accountDeletedWaiter?.resume()
            accountDeletedWaiter = nil
        case "error":
            log.warning("relay error: \(f.reason ?? "?", privacy: .public)")
            if f.reason == "auth_failed" { authFailed = true }
            if f.reason == "unknown_user", let u = f.username { resolveBundle(u, .failure(SendError.notRegistered(u))) }
        case "registered", "logged_in":
            loggedIn = true
            pstnAvailable = f.pstn == true
        case "iceServers":
            if !pendingIce.isEmpty { pendingIce.removeFirst().c.resume(returning: f.iceServers ?? []) }
        case "pstn":
            // The relay's phone bridge: a call with an ordinary phone (number, signal, network caller name, refusal).
            if let call = f.call { onPstnSignal?(f.from ?? f.to ?? "", call, f.callerName, f.error) }
        default: break
        }
    }

    private var inbound: [InboundFrame] = []
    private var draining = false

    private func drainInbound() async {
        while !inbound.isEmpty {
            let f = inbound.removeFirst()
            if let mid = f.mid, (try? db.scalarInt("SELECT 1 FROM seen_frames WHERE mid = ?", mid)) != nil {
                relay.send(Received(mid: mid))   // handled before; our confirmation was lost
                continue
            }
            await handleMessage(f)
            // Confirm even if it couldn't be decrypted: re-delivery wouldn't help.
            if let mid = f.mid {
                try? db.run("INSERT OR IGNORE INTO seen_frames(mid, at) VALUES(?, ?)", mid, nowMs())
                relay.send(Received(mid: mid))
            }
        }
        draining = false
    }

    private func markSent(_ row: Int64) {
        try? db.run("UPDATE messages SET status = 'sent' WHERE id = ? AND status = 'sending'", row)
        touch()
    }

    private func handleSealedReply(_ f: InboundFrame) {
        guard let id = f.id, let pending = pendingSealed.removeValue(forKey: id) else { return }
        switch f.type {
        case "ack": if let r = pending.row { markSent(r) }
        case "error":
            log.warning("sealed send refused: \(f.reason ?? "?", privacy: .public)")
            if f.reason == "sealed_denied" { accessKeys.forget(pending.peer) }
            if let r = pending.row { try? db.run("UPDATE messages SET status = 'failed' WHERE id = ?", r); touch() }
        default: break
        }
    }

    // MARK: - Sending

    func sendText(_ conv: String, _ text: String) async {
        let msgId = newId(), timer = timerOf(conv)
        guard let row = try? db.run("""
            INSERT INTO messages(conv, outgoing, body, ts, status, msgId, expiresInSec, expiresAt) VALUES(?, 1, ?, ?, 'sending', ?, ?, ?)
            """, conv, text, nowMs(), msgId, timer, expiryFor(timer)) else { return }
        touchConversation(conv, text, incoming: false)
        Task { await shareProfile(conv) }
        let p = Payload(t: "text", id: msgId, body: text, group: groupRef(conv), expire: timer > 0 ? timer : nil)
        inFlight.insert(row)
        await deliverTracked(conv, p, row)
        inFlight.remove(row)
    }

    /// Encrypt a file under a fresh key (CSv2), upload the ciphertext, then send the key end to end.
    /// `kind`: "sticker" (shown without a bubble) or "voice" (a voice note); nil for photos and files.
    func sendFile(_ conv: String, data original: Data, name originalName: String, mime originalMime: String, caption: String = "", kind: String? = nil) async throws {
        // Photos and videos lose their hidden location, dates and camera details first.
        let (data, mime) = try await MediaScrub.clean(original, mime: originalMime)
        var name = originalName
        if mime != originalMime, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name = (originalName as NSString).deletingPathExtension + "." + ext
        }
        guard Int64(data.count) <= Self.maxFileBytes else { throw ChunkedAead.Failure.tooLarge(Self.maxFileBytes) }
        let key = Primitives.randomBytes(32)
        let path = Paths.attachments.appendingPathComponent(UUID().uuidString)
        try ChunkedAead.encrypt(data, key: key).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let msgId = newId(), timer = timerOf(conv), keyB64 = Primitives.b64(key)
        let row = try db.run("""
            INSERT INTO messages(conv, outgoing, body, ts, status, msgId, fileName, fileMime, fileSize, filePath, fileKey, fileState, fileKind, expiresInSec, expiresAt)
            VALUES(?, 1, ?, ?, 'sending', ?, ?, ?, ?, ?, ?, 'ready', ?, ?, ?)
            """, conv, caption, nowMs(), msgId, name, mime, Int64(data.count), path.path, keyB64, kind, timer, expiryFor(timer))
        touchConversation(conv, kind == "sticker" ? "Sticker" : kind == "voice" ? "🎤 Voice note" : Self.preview(caption, mime), incoming: false)
        Task { await shareProfile(conv) }
        inFlight.insert(row)
        defer { inFlight.remove(row) }
        let blob: String
        do {
            blob = try await blobs.upload(file: path)
            try db.run("UPDATE messages SET fileBlob = ? WHERE id = ?", blob, row)
        } catch {
            try? db.run("UPDATE messages SET status = 'failed' WHERE id = ?", row); touch()
            return
        }
        let p = Payload(t: "file", id: msgId, body: caption.isEmpty ? nil : caption,
                        file: FileRef(blob: blob, key: keyB64, name: name, mime: mime, size: Int64(data.count), kind: kind),
                        group: groupRef(conv), expire: timer > 0 ? timer : nil)
        await deliverTracked(conv, p, row)
    }

    func sendPoll(_ conv: String, question: String, options: [String], multi: Bool) async {
        let poll = PollDto(options: Array(options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(10)), multi: multi)
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, poll.options.count >= 2 else { return }
        let msgId = newId(), timer = timerOf(conv)
        guard let row = try? db.run("""
            INSERT INTO messages(conv, outgoing, body, ts, status, msgId, pollJson, expiresInSec, expiresAt) VALUES(?, 1, ?, ?, 'sending', ?, ?, ?, ?)
            """, conv, q, nowMs(), msgId, Wire.json(poll), timer, expiryFor(timer)) else { return }
        touchConversation(conv, "📊 \(q)", incoming: false)
        let p = Payload(t: "poll", id: msgId, body: q, group: groupRef(conv), expire: timer > 0 ? timer : nil, poll: poll)
        await deliverTracked(conv, p, row)
    }

    func vote(_ conv: String, pollMsgId: String, choices: [Int]) async {
        guard let msg = messageIn(conv, pollMsgId), let poll = msg.poll else { return }
        var valid = Array(Set(choices)).sorted().filter { poll.options.indices.contains($0) }
        if !poll.multi { valid = Array(valid.prefix(1)) }
        try? db.run("INSERT OR REPLACE INTO votes(msgId, member, choices) VALUES(?, ?, ?)", pollMsgId, me, valid.map(String.init).joined(separator: ","))
        touch()
        let p = Payload(t: "vote", group: groupRef(conv), target: pollMsgId, choices: valid)
        for r in recipients(conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    func react(_ conv: String, msgId: String, emoji: String?) async {
        if let emoji { try? db.run("INSERT OR REPLACE INTO reactions(msgId, member, emoji, ts) VALUES(?, ?, ?, ?)", msgId, me, emoji, nowMs()) }
        else { try? db.run("DELETE FROM reactions WHERE msgId = ? AND member = ?", msgId, me) }
        touch()
        let p = Payload(t: "reaction", group: groupRef(conv), target: msgId, emoji: emoji ?? "")
        for r in recipients(conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    func createGroup(name: String, members: [String]) async -> String {
        let id = newId()
        let all = Array(Set(members + [me])).sorted()
        try? db.run("INSERT OR REPLACE INTO groups(id, name, members) VALUES(?, ?, ?)", id, name, all.joined(separator: ","))
        let conv = Self.groupPrefix + id
        touchConversation(conv, "You created the group", incoming: false)
        let p = Payload(t: "group", id: newId(), group: GroupRef(id: id, name: name, members: all))
        for m in all where m != me { _ = try? await sendPayload(m, p, relayId: nil) }
        return conv
    }

    func setTimer(_ conv: String, seconds: Int) async {
        try? db.run("INSERT OR IGNORE INTO conversations(id) VALUES(?)", conv)
        try? db.run("UPDATE conversations SET timerSec = ? WHERE id = ?", seconds, conv)
        noteSystem(conv, "You \(Self.timerSentence(seconds))")
        let p = Payload(t: "timer", id: newId(), group: groupRef(conv), expire: seconds)
        for r in recipients(conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    /// "Block screenshots" in a chat: on for everyone in it (1:1 or group), like the timer.
    func setShield(_ conv: String, _ on: Bool) async {
        try? db.run("INSERT OR IGNORE INTO conversations(id) VALUES(?)", conv)
        try? db.run("UPDATE conversations SET shield = ? WHERE id = ?", on, conv)
        noteSystem(conv, "You \(Self.shieldSentence(on))")
        let p = Payload(t: "shield", id: newId(), body: on ? "on" : "off", group: groupRef(conv))
        for r in recipients(conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    func shieldOf(_ conv: String) -> Bool { ((try? db.scalarInt("SELECT shield FROM conversations WHERE id = ?", conv)) ?? 0) != 0 }

    static func shieldSentence(_ on: Bool) -> String {
        on ? "turned on Block screenshots — screenshots and recordings of this chat come out blank."
           : "turned off Block screenshots."
    }

    /// Send to every recipient; sending -> sent (relay ack) | failed | unregistered.
    private func deliverTracked(_ conv: String, _ p: Payload, _ row: Int64) async {
        var unregistered = false
        var results: [Bool] = []
        for r in recipients(conv) {
            do { results.append(try await sendPayload(r, p, relayId: String(row))) }
            catch SendError.notRegistered(_) { unregistered = true; results.append(false) }
            catch { results.append(false) }
        }
        if !results.isEmpty && results.allSatisfy({ $0 }) { return }
        let status = unregistered && !Self.isGroup(conv) ? "unregistered" : "failed"
        try? db.run("UPDATE messages SET status = ? WHERE id = ? AND status = 'sending'", status, row)
        touch()
    }

    /// Encrypt one payload for one peer and hand it to the relay (sealed when possible).
    @discardableResult
    private func sendPayload(_ peer: String, _ payload: Payload, relayId: String?, fresh: Bool = false) async throws -> Bool {
        guard peer != me else { throw SendError.toSelf }
        // Offline: fail now, before encrypting — every encryption advances the session,
        // and a message that never leaves would just leave a gap the other side must skip.
        guard relay.isConnected else { throw SendError.offline }
        pendingOps += 1
        defer { pendingOps -= 1; lastActivity = Date() }
        let bundle = (fresh || !sessions.has(peer)) ? try await fetchBundle(peer) : nil
        var withKey = payload
        withKey.ak = accessKeys.own
        let plaintext = try withKey.encode()
        let enc = try CrossProcessLock.run { try encrypt(for: peer, plaintext, bundle: bundle, fresh: fresh) }
        if enc.keysChanged { noteSafetyNumberChange(peer) }
        let eph = (payload.expire ?? 0) > 0 && payload.t != "timer"
        let call = payload.t == "call" && payload.call?.kind == "offer"
        if trySendSealed(peer, enc, relayId: relayId, eph: eph, call: call) { return true }
        return relay.send(SendFrame(to: peer, envelope: enc.envelope, id: relayId, eph: eph ? true : nil, call: call ? true : nil))
    }

    private struct Encrypted { var envelope: Envelope; var keysChanged: Bool; var peerIk: Data? }

    private func encrypt(for peer: String, _ plaintext: Data, bundle: ServedBundle?, fresh: Bool) throws -> Encrypted {
        let mine = identity.identity
        let existing = sessions.load(peer)
        if var s = existing, !fresh {
            let (h, ct) = try s.ratchet.encrypt(plaintext, ad: s.ad)
            try sessions.save(peer, s)
            return Encrypted(envelope: Envelope(kind: "normal", dhPub: Primitives.b64(h.dhPub), pn: h.pn, n: h.n, ct: Primitives.b64(ct)),
                             keysChanged: false, peerIk: s.peerIdentityKey(myIdentityPublic: mine.publicKey))
        }
        guard let b = bundle else { throw SendError.noSession }
        let theirIk = try Primitives.unb64(b.identityKey)
        let keysChanged = existing?.peerIdentityKey(myIdentityPublic: mine.publicKey).map { $0 != theirIk } ?? false
        let x3 = try X3DH.initiator(myIdentity: mine, bundle: .init(
            identityKey: theirIk, signingKey: try Primitives.unb64(b.signingKey),
            signedPreKey: try Primitives.unb64(b.signedPreKey), signedPreKeySig: try Primitives.unb64(b.signedPreKeySig),
            oneTimePreKeyId: b.oneTimePreKey?.id, oneTimePreKey: try b.oneTimePreKey.map { try Primitives.unb64($0.key) }))
        var s = Session(ratchet: try .initiator(sharedSecret: x3.sharedSecret, remoteSignedPreKey: try Primitives.unb64(b.signedPreKey)), ad: x3.associatedData)
        let (h, ct) = try s.ratchet.encrypt(plaintext, ad: s.ad)
        try sessions.save(peer, s)
        return Encrypted(envelope: Envelope(kind: "prekey", dhPub: Primitives.b64(h.dhPub), pn: h.pn, n: h.n, ct: Primitives.b64(ct),
                                            ikPub: Primitives.b64(mine.publicKey), ekPub: Primitives.b64(x3.ephemeralPublic), opkId: x3.usedOneTimePreKeyId),
                         keysChanged: keysChanged, peerIk: theirIk)
    }

    private func trySendSealed(_ peer: String, _ enc: Encrypted, relayId: String?, eph: Bool, call: Bool) -> Bool {
        guard let ak = accessKeys.of(peer), let peerIk = enc.peerIk, let cert = currentCert(), sealedRelay.isConnected,
              let box = try? SealedSender.seal(sender: identity.identity, recipientIk: peerIk, cert: cert, envelopeJson: Wire.json(enc.envelope))
        else { return false }
        let id = relayId ?? "s:" + newId()
        pendingSealed[id] = (peer, relayId.flatMap { Int64($0) })
        if !sealedRelay.send(SendSealed(to: peer, ak: ak, sealed: box, id: id, eph: eph ? true : nil, call: call ? true : nil)) {
            pendingSealed[id] = nil
            return false
        }
        return true
    }

    private func currentCert() -> SealedSender.Certificate? {
        let exp = senderCert?.expiry ?? 0
        if exp - nowMs() < Self.certRefreshMs { relay.send(Simple(type: "getSenderCert")) }
        return exp > nowMs() + 60_000 ? senderCert : nil
    }

    private func fetchBundle(_ peer: String) async throws -> ServedBundle {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ServedBundle, Error>) in
            if pendingBundles[peer] != nil { pendingBundles[peer]!.waiters.append(c); return }
            let ticket = UUID()
            pendingBundles[peer] = (ticket, [c])
            relay.send(GetBundle(username: peer))
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if self.pendingBundles[peer]?.ticket == ticket { self.resolveBundle(peer, .failure(SendError.timeout)) }
            }
        }
    }

    private func resolveBundle(_ peer: String, _ r: Result<ServedBundle, Error>) {
        guard let pending = pendingBundles.removeValue(forKey: peer) else { return }
        pending.waiters.forEach { $0.resume(with: r) }
    }

    /// Which of these numbers use cellosig.
    /// (Gives up after 10 s: if the connection drops meanwhile, the answer never comes.)
    func lookup(_ phones: [String]) async -> [String] {
        guard relay.isConnected else { return [] }
        return await withCheckedContinuation { c in
            let ticket = UUID()
            pendingLookups.append((ticket, c))
            relay.send(Lookup(phones: Array(phones.prefix(1000))))
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let i = self.pendingLookups.firstIndex(where: { $0.ticket == ticket }) { self.pendingLookups.remove(at: i).c.resume(returning: []) }
            }
        }
    }

    // MARK: - Calls

    /// STUN/TURN servers for a call, from the relay (empty if it didn't answer).
    func iceServers() async -> [IceServer] {
        guard relay.isConnected else { return [] }
        return await withCheckedContinuation { c in
            let ticket = UUID()
            pendingIce.append((ticket, c))
            relay.send(Simple(type: "getIceServers"))
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let i = self.pendingIce.firstIndex(where: { $0.ticket == ticket }) { self.pendingIce.remove(at: i).c.resume(returning: []) }
            }
        }
    }

    /// Call signalling to `peer`, end to end. False if it couldn't be sent.
    func sendCallSignal(_ peer: String, _ sig: CallSignal) async -> Bool {
        // Caller ID: our profile goes first, so their phone can show our name as it rings.
        if sig.kind == "offer" { await shareProfile(peer) }
        return (try? await sendPayload(peer, Payload(t: "call", call: sig), relayId: nil)) ?? false
    }

    private struct PstnFrame: Encodable { var type = "pstn"; var to: String?; var call: CallSignal }

    /// Signalling for a call with an ordinary phone, to the relay itself (it bridges
    /// to the phone network). An offer carries the number to dial.
    func sendPstnSignal(_ number: String, _ sig: CallSignal) -> Bool {
        relay.send(PstnFrame(to: sig.kind == "offer" ? number : nil, call: sig))
    }

    /// A call entry ("📞 Outgoing call · 1:23", "📞 Missed call") in the chat with `peer`.
    /// `phoneCall`: with an ordinary phone, so never a message request (you'd miss the missed call).
    func logCall(_ peer: String, outgoing: Bool, text: String, missed: Bool, phoneCall: Bool = false) {
        let request = !outgoing && !phoneCall && isRequest(peer, peer)
        try? db.run("INSERT INTO messages(conv, outgoing, body, ts, status, msgId) VALUES(?, ?, ?, ?, ?, ?)",
                    peer, outgoing, text, nowMs(), outgoing ? "sent" : "read", Self.systemPrefix + newId())
        touchConversation(peer, text, incoming: missed && activeChat != peer, request: request)
        if missed && activeChat != peer && !request { onIncoming?(peer, peer, text) }
    }

    // MARK: - Retry / reset

    func retryUnsent() async {
        let rows = (try? db.query("""
            SELECT * FROM messages WHERE outgoing = 1 AND (status = 'failed' OR (status = 'sending' AND ts < ?))
              AND ts > ? AND msgId != '' AND deleted = 0
            """, nowMs() - 30_000, nowMs() - Self.autoRetryWindowMs)) ?? []
        // (Failed ones go again at once; "sending" ones only once clearly stuck — inFlight guards the rest.)
        for r in rows { await resend(Message(row: r)) }
    }

    func retry(_ m: Message) async { await resend(m) }

    private func resend(_ m: Message) async {
        guard !m.msgId.isEmpty, !m.isSystem, !m.deleted, !inFlight.contains(m.id) else { return }
        inFlight.insert(m.id)
        defer { inFlight.remove(m.id) }
        let confirmed = m.status == "delivered" || m.status == "read"
        if !confirmed { try? db.run("UPDATE messages SET status = 'sending' WHERE id = ?", m.id); touch() }
        do {
            await deliverTracked(m.conv, try await payloadFor(m), m.id)
        } catch {
            if !confirmed { try? db.run("UPDATE messages SET status = 'failed' WHERE id = ?", m.id); touch() }
        }
    }

    private func payloadFor(_ m: Message) async throws -> Payload {
        let g = groupRef(m.conv), expire = m.expiresInSec > 0 ? m.expiresInSec : nil
        if let poll = m.poll { return Payload(t: "poll", id: m.msgId, body: m.body, group: g, expire: expire, poll: poll) }
        guard let mime = m.fileMime else { return Payload(t: "text", id: m.msgId, body: m.body, group: g, expire: expire) }
        guard let path = m.filePath, let key = m.fileKey else { throw SendError.noSession }
        var blob = m.fileBlob
        if blob == nil {
            blob = try await blobs.upload(file: URL(fileURLWithPath: path))
            try db.run("UPDATE messages SET fileBlob = ? WHERE id = ?", blob, m.id)
        }
        return Payload(t: "file", id: m.msgId, body: m.body.isEmpty ? nil : m.body,
                       file: FileRef(blob: blob!, key: key, name: m.fileName ?? "file", mime: mime, size: m.fileSize ?? 0, kind: m.fileKind),
                       group: g, expire: expire)
    }

    private func requestReset(_ peer: String) async {
        if nowMs() - (lastResetRequest[peer] ?? 0) < Self.resetMinIntervalMs { return }
        lastResetRequest[peer] = nowMs()
        log.info("can't read messages from \(PhoneNumbers.mask(peer), privacy: .public); asking for a fresh session")
        _ = try? await sendPayload(peer, Payload(t: "reset", id: newId()), relayId: nil, fresh: true)
    }

    /// You verified their safety number but their keys changed since: don't trust the new keys blindly.
    func trustBroken(_ peer: String) -> Bool {
        guard !Self.isGroup(peer), let v = try? db.query("SELECT safety FROM verified WHERE phone = ?", peer).first?.str("safety") else { return false }
        return v != safetyNumber(peer)
    }

    private func resendUndelivered(to peer: String) async {
        if trustBroken(peer) {
            noteSystem(peer, "Unsent messages weren't re-sent because this contact's safety number changed. Compare safety numbers (shield icon), then send again.")
            return
        }
        let since = nowMs() - Self.resendWindowMs
        let direct = (try? db.query("SELECT * FROM messages WHERE conv = ? AND outgoing = 1 AND ts > ? AND status NOT IN ('delivered','read') AND msgId != '' AND msgId NOT LIKE 'sys:%' AND deleted = 0", peer, since)) ?? []
        for r in direct { await resend(Message(row: r)) }
        for g in allGroups() where g.members.contains(peer) {
            let rows = (try? db.query("SELECT * FROM messages WHERE conv = ? AND outgoing = 1 AND ts > ? AND msgId != '' AND deleted = 0", Self.groupPrefix + g.id, since)) ?? []
            for r in rows {
                let m = Message(row: r)
                if (try? db.scalarInt("SELECT 1 FROM receipts WHERE msgId = ? AND member = ?", m.msgId, peer)) != nil { continue }
                if let p = try? await payloadFor(m) { _ = try? await sendPayload(peer, p, relayId: nil) }
            }
        }
    }

    private func noteSafetyNumberChange(_ peer: String, at: Int64 = nowMs()) {
        noteSystem(peer, "Safety number changed. \(PhoneNumbers.pretty(peer)) may have reinstalled cellosig or changed phones — or someone may be intercepting. Tap the shield to compare safety numbers.", at: at)
    }

    func noteSystem(_ conv: String, _ text: String, at: Int64 = nowMs()) {
        try? db.run("INSERT INTO messages(conv, outgoing, body, ts, status, msgId) VALUES(?, 0, ?, ?, 'read', ?)", conv, text, at, Self.systemPrefix + newId())
        try? db.run("INSERT OR IGNORE INTO conversations(id, lastTs) VALUES(?, ?)", conv, at)
        touch()
    }

    // MARK: - Receiving

    private func handleMessage(_ raw: InboundFrame) async {
        guard let opened = await unseal(raw) else { return }
        let (from, env) = opened
        let sentAt = raw.age.map { nowMs() - $0 } ?? raw.ts ?? nowMs()
        // Under the shared lock: the extension and the app may both have been handed
        // this frame; only one decrypts it (the other sees it in seen_frames).
        var outcome: Result<(Data, Bool), Error>?
        CrossProcessLock.run {
            if let mid = raw.mid, (try? db.scalarInt("SELECT 1 FROM seen_frames WHERE mid = ?", mid)) != nil { return }
            outcome = Result { try decrypt(from: from, env) }
            if let mid = raw.mid { try? db.run("INSERT OR IGNORE INTO seen_frames(mid, at) VALUES(?, ?)", mid, nowMs()) }
        }
        guard let outcome else { return }
        let decrypted: (Data, Bool)
        do { decrypted = try outcome.get() }
        catch {
            log.warning("can't decrypt \(env.kind, privacy: .public) message from \(PhoneNumbers.mask(from), privacy: .public)")
            if !(error is ReplayedSessionStart) { Task { await requestReset(from) } }
            return
        }
        if isBlocked(from) { return }
        if decrypted.1 { noteSafetyNumberChange(from, at: sentAt - 1) }
        onPayload(from, Payload.decode(decrypted.0), sentAt)
    }

    private struct ReplayedSessionStart: Error {}
    private struct NoFit: Error {}

    private func decrypt(from peer: String, _ env: Envelope) throws -> (Data, Bool) {
        let header = DoubleRatchet.Header(dhPub: try Primitives.unb64(env.dhPub), pn: env.pn, n: env.n)
        let ct = try Primitives.unb64(env.ct)
        let mine = identity.identity
        let existing = sessions.load(peer)
        if var s = existing {
            if let pt = try? s.ratchet.decrypt(header, ct, ad: s.ad) {
                try sessions.save(peer, s)
                return (pt, false)
            }
            guard env.kind == "prekey" else { throw NoFit() }
        } else if env.kind != "prekey" { throw NoFit() }
        guard let ikS = env.ikPub, let ekS = env.ekPub else { throw NoFit() }
        let ik = try Primitives.unb64(ikS), ek = try Primitives.unb64(ekS)
        if seenStarts.contains(ik: ik, ek: ek) { throw ReplayedSessionStart() }
        let sk = try X3DH.responder(myIdentity: mine, mySignedPreKey: identity.signedPreKey, oneTimePreKey: identity.oneTimePreKey(env.opkId),
                                    initiatorIdentityPublic: ik, initiatorEphemeralPublic: ek)
        var fresh = Session(ratchet: .responder(sharedSecret: sk, signedPreKey: identity.signedPreKey),
                            ad: X3DH.associatedData(initiator: ik, responder: mine.publicKey))
        let pt = try fresh.ratchet.decrypt(header, ct, ad: fresh.ad)
        identity.consumeOneTimePreKey(env.opkId)
        try sessions.save(peer, fresh)
        seenStarts.add(ik: ik, ek: ek)
        let changed = existing?.peerIdentityKey(myIdentityPublic: mine.publicKey).map { $0 != ik } ?? false
        return (pt, changed)
    }

    private func relayCertKey() -> Data? { Vault.shared.readSealed(Paths.keys.appendingPathComponent("relay_cert.bin")) }

    /// Who a frame is really from and its envelope (opening sealed sender if needed).
    private func unseal(_ f: InboundFrame) async -> (String, Envelope)? {
        guard let box = f.sealed else {
            guard let from = f.from, let env = f.envelope else { return nil }
            return (from, env)
        }
        var key = relayCertKey()
        if key == nil {
            relay.send(Simple(type: "getSenderCert"))
            await withCheckedContinuation { c in
                certWaiters.append(c)
                Task { try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !self.certWaiters.isEmpty { self.certWaiters.forEach { $0.resume() }; self.certWaiters = [] } }
            }
            key = relayCertKey()
        }
        guard let serverKey = key,
              let opened = try? SealedSender.open(recipient: identity.identity, box: box, serverKey: serverKey),
              let env = try? JSONDecoder().decode(Envelope.self, from: Data(opened.envelopeJson.utf8)) else {
            log.warning("couldn't open a sealed message")
            return nil
        }
        // A session started inside a sealed box must be with the identity its certificate vouches for.
        if env.kind == "prekey", (env.ikPub.flatMap { try? Primitives.unb64($0) }) != opened.senderIk { return nil }
        return (opened.sender, env)
    }

    private func onPayload(_ from: String, _ p: Payload, _ ts: Int64) {
        if let ak = p.ak { accessKeys.remember(from, ak) }
        switch p.t {
        case "receipt": onReceipt(from, p)
        case "reaction": onReaction(from, p)
        case "vote": onVote(from, p)
        case "edit": onEdit(from, p)
        case "unsend": onUnsend(from, p)
        case "reset": Task { await resendUndelivered(to: from) }
        case "group": if let g = p.group { onGroupAnnouncement(from, g) }
        case "profile": if let pr = p.profile { onProfile(from, pr) }
        case "call":
            guard let sig = p.call else { return }
            if sig.kind == "offer" && isRequest(from, from) {
                noteSystem(from, "📞 Missed call"); return
            }
            guard let onCallSignal else {
                // The notification extension can't ring; say what happened.
                if sig.kind == "offer" { logCall(from, outgoing: false, text: "📞 Missed call", missed: true) }
                return
            }
            onCallSignal(from, sig, ts)
        case "timer":
            guard let conv = conversationFor(from, p.group) else { return }
            let s = max(0, p.expire ?? 0)
            if timerOf(conv) == s { return }
            try? db.run("INSERT OR IGNORE INTO conversations(id, request) VALUES(?, ?)", conv, isRequest(conv, from))
            try? db.run("UPDATE conversations SET timerSec = ? WHERE id = ?", s, conv)
            noteSystem(conv, "\(Self.isGroup(conv) ? groupMemberName(from) : displayName(from)) \(Self.timerSentence(s))")
        case "shield":
            guard let conv = conversationFor(from, p.group) else { return }
            let on = p.body == "on"
            if shieldOf(conv) == on { return }
            try? db.run("INSERT OR IGNORE INTO conversations(id, request) VALUES(?, ?)", conv, isRequest(conv, from))
            try? db.run("UPDATE conversations SET shield = ? WHERE id = ?", on, conv)
            noteSystem(conv, "\(Self.isGroup(conv) ? groupMemberName(from) : displayName(from)) \(Self.shieldSentence(on))")
        case "text", "file", "poll":
            onContent(from, p, ts)
        default: break
        }
    }

    private func onContent(_ from: String, _ p: Payload, _ ts: Int64) {
        guard let conv = conversationFor(from, p.group) else { return }
        let msgId = p.id ?? newId()
        if p.id != nil, (try? db.scalarInt("SELECT 1 FROM messages WHERE conv = ? AND msgId = ? AND outgoing = 0", conv, msgId)) != nil {
            Task { await sendReceipt(from, "delivered", [msgId]) }   // our receipt got lost: confirm again
            return
        }
        let f = p.file
        let request = isRequest(conv, from)
        // Lockdown mode: nothing downloads until you tap it.
        let fetch = f != nil && !request && !Lockdown.on && (f!.size <= Self.autoDownloadBytes)
        let viewing = activeChat == conv
        let expire = max(0, p.expire ?? 0)
        let pollJson = p.t == "poll" ? p.poll.flatMap { (2...10).contains($0.options.count) ? Wire.json($0) : nil } : nil
        guard let row = try? db.run("""
            INSERT INTO messages(conv, outgoing, body, ts, status, msgId, sender, fileName, fileMime, fileSize, fileKey, fileBlob, fileState, fileKind, pollJson, expiresInSec, expiresAt)
            VALUES(?, 0, ?, ?, 'received', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, conv, p.body ?? "", ts, msgId, Self.isGroup(conv) ? from : nil as String?,
            f?.name, f?.mime, f?.size, f?.key, f?.blob, f.map { _ in fetch ? "downloading" : "tap" },
            f?.kind.flatMap { ["sticker", "voice"].contains($0) ? $0 : nil }, pollJson,
            expire, viewing ? expiryFor(expire) : nil as Int64?) else { return }
        if fetch { Task { await downloadAttachment(row) } }
        let text = p.t == "poll" ? "📊 \(p.body ?? "")" : f?.kind == "sticker" ? "Sticker" : f?.kind == "voice" ? "🎤 Voice note" : Self.preview(p.body ?? "", f?.mime)
        touchConversation(conv, text, incoming: !viewing, request: request)
        if p.id != nil && !request {
            let kind = viewing && readReceipts ? "read" : "delivered"
            Task { await sendReceipt(from, kind, [msgId]) }
        }
        if viewing { try? db.run("UPDATE messages SET readAt = ? WHERE id = ?", nowMs(), row) }
        else { onIncoming?(conv, from, expire > 0 ? "⏱ New disappearing message" : text) }
    }

    func isRequestConversation(_ conv: String) -> Bool {
        ((try? db.query("SELECT request FROM conversations WHERE id = ?", conv))?.first?.bool("request")) ?? false
    }

    func isRequest(_ conv: String, _ from: String) -> Bool {
        if let r = try? db.query("SELECT request FROM conversations WHERE id = ?", conv).first { return r.bool("request") }
        return (try? db.scalarInt("SELECT COUNT(*) FROM messages WHERE conv = ? AND outgoing = 1", from)) ?? 0 == 0
    }

    private func onReceipt(_ from: String, _ p: Payload) {
        guard var kind = p.receipt, kind == "delivered" || kind == "read" else { return }
        if kind == "read" && !readReceipts { kind = "delivered" }
        for id in p.ids ?? [] {
            guard let r = try? db.query("SELECT * FROM messages WHERE msgId = ? AND outgoing = 1 LIMIT 1", id).first else { continue }
            let m = Message(row: r)
            let recips = recipients(m.conv)
            guard recips.contains(from) else { continue }
            if (try? db.query("SELECT kind FROM receipts WHERE msgId = ? AND member = ?", id, from).first?.str("kind")) == "read" { continue }
            try? db.run("INSERT OR REPLACE INTO receipts(msgId, member, kind) VALUES(?, ?, ?)", id, from, kind)
            let got = Dictionary(uniqueKeysWithValues: ((try? db.query("SELECT member, kind FROM receipts WHERE msgId = ?", id)) ?? [])
                .compactMap { r in r.str("member").map { ($0, r.str("kind") ?? "") } })
            let status: String? = recips.allSatisfy { got[$0] == "read" } ? "read" : recips.allSatisfy { got[$0] != nil } ? "delivered" : nil
            if let status { try? db.run("UPDATE messages SET status = ? WHERE msgId = ? AND outgoing = 1 AND status != 'read'", status, id) }
        }
        touch()
    }

    private func sendReceipt(_ to: String, _ kind: String, _ ids: [String]) async {
        guard !ids.isEmpty else { return }
        _ = try? await sendPayload(to, Payload(t: "receipt", receipt: kind, ids: ids), relayId: nil)
    }

    /// The user is looking at `conv`: mark read, start disappearing timers, tell senders.
    func markRead(_ conv: String) async {
        let unread = ((try? db.query("SELECT * FROM messages WHERE conv = ? AND outgoing = 0 AND readAt IS NULL AND msgId NOT LIKE 'sys:%'", conv)) ?? []).map(Message.init(row:))
        try? db.run("UPDATE messages SET readAt = ?, expiresAt = CASE WHEN expiresInSec > 0 AND expiresAt IS NULL THEN ? + expiresInSec * 1000 ELSE expiresAt END WHERE conv = ? AND outgoing = 0 AND readAt IS NULL", nowMs(), nowMs(), conv)
        try? db.run("UPDATE conversations SET unread = 0 WHERE id = ?", conv)
        touch()
        guard readReceipts, !isRequestConversation(conv) else { return }
        let bySender = Dictionary(grouping: unread.filter { !$0.msgId.isEmpty }, by: { $0.sender ?? conv })
        for (sender, msgs) in bySender { await sendReceipt(sender, "read", msgs.map(\.msgId)) }
    }

    private func onReaction(_ from: String, _ p: Payload) {
        guard let conv = conversationFor(from, p.group), let t = p.target, let target = messageIn(conv, t), !target.deleted else { return }
        if let e = p.emoji, !e.trimmingCharacters(in: .whitespaces).isEmpty, e.count <= 16 {
            try? db.run("INSERT OR REPLACE INTO reactions(msgId, member, emoji, ts) VALUES(?, ?, ?, ?)", target.msgId, from, e, nowMs())
            if target.outgoing && activeChat != conv { onIncoming?(conv, from, "Reacted \(e) to “\(target.body.prefix(40))”") }
        } else {
            try? db.run("DELETE FROM reactions WHERE msgId = ? AND member = ?", target.msgId, from)
        }
        touch()
    }

    private func onVote(_ from: String, _ p: Payload) {
        guard let conv = conversationFor(from, p.group), let t = p.target, let msg = messageIn(conv, t), let poll = msg.poll else { return }
        var valid = Array(Set(p.choices ?? [])).sorted().filter { poll.options.indices.contains($0) }
        if !poll.multi { valid = Array(valid.prefix(1)) }
        try? db.run("INSERT OR REPLACE INTO votes(msgId, member, choices) VALUES(?, ?, ?)", msg.msgId, from, valid.map(String.init).joined(separator: ","))
        touch()
    }

    // MARK: - Edit / delete for everyone

    /// How long after sending you can still edit or delete a message for everyone (same on Android).
    static let editWindowMs: Int64 = 24 * 3600_000
    private static let maxEditChars = 64_000

    func canUnsend(_ msg: Message) -> Bool {
        msg.outgoing && !msg.deleted && !msg.msgId.isEmpty && !msg.isSystem && nowMs() - msg.ts < Self.editWindowMs
    }

    /// Text messages only (not files or polls).
    func canEdit(_ msg: Message) -> Bool { canUnsend(msg) && msg.fileMime == nil && msg.pollJson == nil }

    /// Change the text of a message you sent; everyone in the chat sees the new text, marked edited.
    func editMessage(_ msg: Message, _ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit(msg), !body.isEmpty, body != msg.body else { return }
        try? db.run("UPDATE messages SET body = ?, editedAt = ? WHERE id = ?", body, nowMs(), msg.id)
        refreshPreview(msg.conv, msg.id)
        let p = Payload(t: "edit", body: body, group: groupRef(msg.conv), target: msg.msgId)
        for r in recipients(msg.conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    /// Delete a message you sent for everyone in the chat.
    func unsend(_ msg: Message) async {
        guard canUnsend(msg) else { return }
        takeBack(msg)
        let p = Payload(t: "unsend", group: groupRef(msg.conv), target: msg.msgId)
        for r in recipients(msg.conv) { _ = try? await sendPayload(r, p, relayId: nil) }
    }

    /// The message `p` points at, if `from` sent it to us in that chat recently enough to change it.
    private func theirChangeable(_ from: String, _ p: Payload) -> Message? {
        guard let conv = conversationFor(from, p.group), let t = p.target, let msg = messageIn(conv, t) else { return nil }
        // Only whoever wrote it may change it (in a group: that member, not anyone in it).
        guard !msg.outgoing, !msg.deleted, (msg.sender ?? conv) == from else { return nil }
        // Some slack over the sender's own limit, for clocks and delivery delays.
        return nowMs() - msg.ts < Self.editWindowMs * 2 ? msg : nil
    }

    private func onEdit(_ from: String, _ p: Payload) {
        guard let msg = theirChangeable(from, p), msg.fileMime == nil, msg.pollJson == nil,
              let body = p.body.map({ String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxEditChars)) }), !body.isEmpty
        else { return }
        try? db.run("UPDATE messages SET body = ?, editedAt = ? WHERE id = ?", body, nowMs(), msg.id)
        refreshPreview(msg.conv, msg.id)
    }

    private func onUnsend(_ from: String, _ p: Payload) {
        guard let msg = theirChangeable(from, p) else { return }
        takeBack(msg)
    }

    /// The words and the attachment go; the row stays as a "deleted" placeholder.
    private func takeBack(_ msg: Message) {
        if let path = msg.filePath { try? FileManager.default.removeItem(atPath: path) }
        try? db.run("""
            UPDATE messages SET deleted = 1, body = '', fileName = NULL, fileMime = NULL, fileSize = NULL, filePath = NULL,
              fileKey = NULL, fileBlob = NULL, fileState = NULL, fileKind = NULL, pollJson = NULL, transcript = NULL WHERE id = ?
            """, msg.id)
        try? db.run("DELETE FROM reactions WHERE msgId = ?", msg.msgId)
        try? db.run("DELETE FROM votes WHERE msgId = ?", msg.msgId)
        for r in reminders(conv: msg.conv) where r.msgRow == msg.id { cancelReminder(r.id) }
        refreshPreview(msg.conv, msg.id)
    }

    /// The chat list shows the latest message: if that's the one that changed, show it as it is now.
    private func refreshPreview(_ conv: String, _ row: Int64) {
        guard let r = try? db.query("SELECT * FROM messages WHERE conv = ? ORDER BY ts DESC, id DESC LIMIT 1", conv).first else { return }
        let latest = Message(row: r)
        guard latest.id == row else { touch(); return }
        let text = latest.deleted ? "🚫 Message deleted" : latest.expiresInSec > 0 ? "⏱ Disappearing message" : latest.body
        try? db.run("UPDATE conversations SET lastText = ? WHERE id = ?", text, conv)
        touch()
    }

    func saveTranscript(_ msg: Message, _ text: String) {
        try? db.run("UPDATE messages SET transcript = ? WHERE id = ?", text, msg.id)
        touch()
    }

    // MARK: - Search

    struct SearchHit: Identifiable {
        var msg: Message
        var id: Int64 { msg.id }
    }

    /// Messages containing `query` (newest first), in your chats (not requests).
    func search(_ query: String, limit: Int = 100) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let rows = (try? db.query("""
            SELECT * FROM messages WHERE body LIKE ? ESCAPE '\\' AND msgId NOT LIKE 'sys:%' AND deleted = 0
              AND conv IN (SELECT id FROM conversations WHERE request = 0)
            ORDER BY ts DESC LIMIT ?
            """, "%" + escaped + "%", limit)) ?? []
        return rows.map { SearchHit(msg: Message(row: $0)) }
    }

    private func onProfile(_ from: String, _ pr: ProfileDto) {
        let name = Profiles.cleanName(pr.name)
        var photoPath: String?
        let file = Paths.profiles.appendingPathComponent(Primitives.sha256Hex(from) + ".img")
        if let b64 = pr.photo, let d = try? Primitives.unb64(b64), d.count <= Profiles.maxPhotoBytes, Profiles.looksLikeImage(d) {
            try? Vault.shared.writeSealed(file, d)   // sealed like the keys: not readable off the phone
            photoPath = file.path
        } else { try? FileManager.default.removeItem(at: file) }
        try? db.run("INSERT OR REPLACE INTO profiles(phone, name, photo) VALUES(?, ?, ?)", from, name, photoPath)
        touch()
    }

    /// Send our profile to the people in `conv` who don't have its current version yet.
    func shareProfile(_ conv: String, force: Bool = false) async {
        guard let dto = ownProfile.dto, !isRequestConversation(conv) else { return }
        for r in recipients(conv) where force || !ownProfile.alreadySent(to: r) {
            if (try? await sendPayload(r, Payload(t: "profile", id: newId(), profile: dto), relayId: nil)) == true { ownProfile.markSent(to: r) }
        }
    }

    // MARK: - Groups

    static func isGroup(_ conv: String) -> Bool { conv.hasPrefix(groupPrefix) }

    func group(_ id: String) -> ChatGroup? {
        guard let r = try? db.query("SELECT * FROM groups WHERE id = ?", id).first else { return nil }
        return ChatGroup(id: id, name: r.str("name") ?? "Group", members: (r.str("members") ?? "").split(separator: ",").map(String.init))
    }

    func allGroups() -> [ChatGroup] {
        ((try? db.query("SELECT * FROM groups")) ?? []).map {
            ChatGroup(id: $0.str("id") ?? "", name: $0.str("name") ?? "Group", members: ($0.str("members") ?? "").split(separator: ",").map(String.init))
        }
    }

    func recipients(_ conv: String) -> [String] {
        Self.isGroup(conv) ? (group(String(conv.dropFirst(Self.groupPrefix.count)))?.members.filter { $0 != me } ?? []) : [conv]
    }

    private func groupRef(_ conv: String) -> GroupRef? {
        guard Self.isGroup(conv), let g = group(String(conv.dropFirst(Self.groupPrefix.count))) else { return nil }
        return GroupRef(id: g.id, name: g.name, members: g.members)
    }

    private func sane(_ ref: GroupRef) -> GroupRef? {
        guard ref.id.range(of: Self.groupIdPattern, options: .regularExpression) != nil else { return nil }
        var r = ref
        if let m = ref.members {
            guard m.count <= 256, m.allSatisfy(PhoneNumbers.isE164) else { return nil }
            var seen = Set<String>()
            r.members = m.filter { seen.insert($0).inserted }
        }
        r.name = ref.name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 }
        return r
    }

    private func conversationFor(_ from: String, _ untrusted: GroupRef?) -> String? {
        guard let untrusted else { return from }
        guard let ref = sane(untrusted) else { return nil }
        if let g = group(ref.id) { return g.members.contains(from) ? Self.groupPrefix + ref.id : nil }
        guard let members = ref.members, members.contains(from), members.contains(me) else { return nil }
        try? db.run("INSERT OR REPLACE INTO groups(id, name, members) VALUES(?, ?, ?)", ref.id, ref.name ?? "Group", members.joined(separator: ","))
        return Self.groupPrefix + ref.id
    }

    private func onGroupAnnouncement(_ from: String, _ untrusted: GroupRef) {
        guard let ref = sane(untrusted), let members = ref.members else { return }
        let existing = group(ref.id)
        if let e = existing, !e.members.contains(from) { return }
        if existing == nil && (!members.contains(from) || !members.contains(me)) { return }
        try? db.run("INSERT OR REPLACE INTO groups(id, name, members) VALUES(?, ?, ?)", ref.id, ref.name ?? existing?.name ?? "Group", members.joined(separator: ","))
        if existing == nil {
            touchConversation(Self.groupPrefix + ref.id, "You were added to the group", incoming: true, request: isRequest(Self.groupPrefix + ref.id, from))
        }
        touch()
    }

    // MARK: - Attachments

    func downloadAttachment(_ row: Int64) async {
        guard let r = try? db.query("SELECT * FROM messages WHERE id = ?", row).first else { return }
        let m = Message(row: r)
        guard let blob = m.fileBlob, let key = m.fileKey else { return }
        try? db.run("UPDATE messages SET fileState = 'downloading' WHERE id = ?", row); touch()
        let dest = Paths.attachments.appendingPathComponent(UUID().uuidString)
        do {
            let declared = min(max(m.fileSize ?? 0, 0), Self.maxFileBytes)
            let maxCipher = 16 + (declared / Int64(ChunkedAead.chunk) + 1) * Int64(ChunkedAead.chunk + 16) + 16
            try await blobs.download(blob, to: dest, maxBytes: maxCipher)
            // Authenticate the whole file before keeping it.
            let h = try FileHandle(forReadingFrom: dest)
            defer { try? h.close() }
            try ChunkedAead.verify(input: h, key: try Primitives.unb64(key))
            guard (try? db.scalarInt("SELECT 1 FROM messages WHERE id = ?", row)) != nil else { try? FileManager.default.removeItem(at: dest); return }
            try db.run("UPDATE messages SET filePath = ?, fileState = 'ready' WHERE id = ?", dest.path, row)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            try? db.run("UPDATE messages SET fileState = 'failed' WHERE id = ?", row)
        }
        touch()
    }

    /// Decrypted bytes of a ready attachment (photos up to 30 MB; bigger files open via share sheet).
    func attachmentData(_ m: Message, limit: Int64 = 30 * 1024 * 1024) -> Data? {
        guard let path = m.filePath, let key = m.fileKey, (m.fileSize ?? 0) <= limit,
              let blob = try? Data(contentsOf: URL(fileURLWithPath: path)), let k = try? Primitives.unb64(key) else { return nil }
        return try? ChunkedAead.decrypt(blob, key: k)
    }

    /// Decrypt into a temporary file (for sharing / opening in another app). Deleted on next launch.
    func exportAttachment(_ m: Message) -> URL? {
        guard let data = attachmentData(m, limit: Self.maxFileBytes) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (m.fileName ?? "file").replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(name == "." || name == ".." ? "file" : name)
        guard (try? data.write(to: url, options: .completeFileProtection)) != nil else { return nil }
        return url
    }

    // MARK: - Conversations

    func conversations(requests: Bool = false) -> [Conversation] {
        ((try? db.query("SELECT * FROM conversations WHERE request = ? ORDER BY pinnedAt IS NULL, pinnedAt DESC, lastTs DESC", requests)) ?? []).map(Conversation.init(row:))
    }

    func conversation(_ id: String) -> Conversation? {
        (try? db.query("SELECT * FROM conversations WHERE id = ?", id))?.first.map(Conversation.init(row:))
    }

    func messages(_ conv: String) -> [Message] {
        ((try? db.query("SELECT * FROM messages WHERE conv = ? ORDER BY ts, id", conv)) ?? []).map(Message.init(row:))
    }

    /// The latest `limit` messages, oldest first (a long chat isn't reloaded whole on every change).
    func messages(_ conv: String, limit: Int) -> [Message] {
        ((try? db.query("""
            SELECT * FROM (SELECT * FROM messages WHERE conv = ? ORDER BY ts DESC, id DESC LIMIT ?) ORDER BY ts, id
            """, conv, limit)) ?? []).map(Message.init(row:))
    }

    func messageCount(_ conv: String) -> Int {
        Int((try? db.scalarInt("SELECT COUNT(*) FROM messages WHERE conv = ?", conv)) ?? 0)
    }

    /// How many messages from this one to the newest (to show enough of the chat to reach it).
    func messagesSince(_ conv: String, row: Int64) -> Int {
        guard let r = try? db.query("SELECT ts FROM messages WHERE id = ?", row).first, let ts = r.int("ts") else { return 0 }
        return Int((try? db.scalarInt("SELECT COUNT(*) FROM messages WHERE conv = ? AND (ts > ? OR (ts = ? AND id >= ?))", conv, ts, ts, row)) ?? 0)
    }

    func messageIn(_ conv: String, _ msgId: String) -> Message? {
        (try? db.query("SELECT * FROM messages WHERE conv = ? AND msgId = ? LIMIT 1", conv, msgId))?.first.map(Message.init(row:))
    }

    func reactions(_ msgId: String) -> [(member: String, emoji: String)] {
        ((try? db.query("SELECT member, emoji FROM reactions WHERE msgId = ? ORDER BY ts", msgId)) ?? []).map { ($0.str("member") ?? "", $0.str("emoji") ?? "") }
    }

    func votes(_ msgId: String) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for r in (try? db.query("SELECT member, choices FROM votes WHERE msgId = ?", msgId)) ?? [] {
            out[r.str("member") ?? ""] = (r.str("choices") ?? "").split(separator: ",").compactMap { Int($0) }
        }
        return out
    }

    func timerOf(_ conv: String) -> Int { Int((try? db.scalarInt("SELECT timerSec FROM conversations WHERE id = ?", conv)) ?? 0) }

    private func touchConversation(_ conv: String, _ text: String, incoming: Bool, request: Bool = false) {
        try? db.run("INSERT OR IGNORE INTO conversations(id, request) VALUES(?, ?)", conv, request)
        try? db.run("UPDATE conversations SET lastText = ?, lastTs = ?, unread = unread + ? WHERE id = ?", text, nowMs(), incoming ? 1 : 0, conv)
        touch()
    }

    func startChat(_ peer: String) {
        try? db.run("INSERT OR IGNORE INTO conversations(id, lastTs) VALUES(?, ?)", peer, nowMs())
        touch()
    }

    func acceptRequest(_ conv: String) async {
        try? db.run("UPDATE conversations SET request = 0 WHERE id = ?", conv)
        touch()
        await shareProfile(conv)
        let msgs = messages(conv).filter { !$0.outgoing && !$0.msgId.isEmpty && !$0.isSystem }
        for (sender, ms) in Dictionary(grouping: msgs, by: { $0.sender ?? conv }) { await sendReceipt(sender, "delivered", ms.map(\.msgId)) }
    }

    func deleteConversation(_ conv: String) {
        for m in messages(conv) {
            if let p = m.filePath { try? FileManager.default.removeItem(atPath: p) }
            if !m.msgId.isEmpty {
                try? db.run("DELETE FROM receipts WHERE msgId = ?", m.msgId)
                try? db.run("DELETE FROM reactions WHERE msgId = ?", m.msgId)
                try? db.run("DELETE FROM votes WHERE msgId = ?", m.msgId)
            }
        }
        try? db.run("DELETE FROM messages WHERE conv = ?", conv)
        try? db.run("DELETE FROM conversations WHERE id = ?", conv)
        cancelReminders(conv: conv)
        touch()
    }

    func setPinned(_ conv: String, _ pinned: Bool) {
        try? db.run("UPDATE conversations SET pinnedAt = ? WHERE id = ?", pinned ? nowMs() : nil as Int64?, conv)
        touch()
    }

    func block(_ phone: String) {
        try? db.run("INSERT OR REPLACE INTO blocked(phone, at) VALUES(?, ?)", phone, nowMs())
        deleteConversation(phone)
        accessKeys.forget(phone)
    }

    func unblock(_ phone: String) { try? db.run("DELETE FROM blocked WHERE phone = ?", phone); touch() }
    func isBlocked(_ phone: String) -> Bool { (try? db.scalarInt("SELECT 1 FROM blocked WHERE phone = ?", phone)) != nil }
    func blockedList() -> [String] { ((try? db.query("SELECT phone FROM blocked ORDER BY at DESC")) ?? []).compactMap { $0.str("phone") } }

    private func expireMessages() {
        let now = nowMs()
        let rows = ((try? db.query("SELECT * FROM messages WHERE expiresAt IS NOT NULL AND expiresAt <= ?", now)) ?? []).map(Message.init(row:))
        guard !rows.isEmpty else { return }
        for m in rows {
            if let p = m.filePath { try? FileManager.default.removeItem(atPath: p) }
            try? db.run("DELETE FROM messages WHERE id = ?", m.id)
            try? db.run("DELETE FROM reactions WHERE msgId = ?", m.msgId)
        }
        log.info("deleted \(rows.count) disappearing message(s)")
        touch()
    }

    // MARK: - Names, safety numbers

    /// Names from your iPhone's contacts (filled in by ContactBook, if you allowed it).
    static var contactNames: [String: String] = [:]

    /// Your contact's name for them, else the name they chose, else the number (as on Android).
    func displayName(_ phone: String) -> String {
        if let n = Self.contactNames[phone] { return n }
        if let n = try? db.query("SELECT name FROM profiles WHERE phone = ?", phone).first?.str("name"), !n.isEmpty { return n }
        return PhoneNumbers.pretty(phone)
    }

    /// Someone in a group, without revealing their number: your contact name for
    /// them or the name they chose, else "Member" + a short tag that stays the
    /// same for that person (so members can still be told apart).
    func groupMemberName(_ phone: String) -> String {
        if phone == me { return "You" }
        let name = displayName(phone)
        if name != PhoneNumbers.pretty(phone) { return name }
        return "Member " + Primitives.sha256Hex("cellosig-member:" + phone).prefix(4).uppercased()
    }

    /// True when the name shown is self-chosen (so the number should be shown under it).
    func hasProfileName(_ phone: String) -> Bool { displayName(phone) != PhoneNumbers.pretty(phone) }

    func title(_ conv: String) -> String {
        Self.isGroup(conv) ? (group(String(conv.dropFirst(Self.groupPrefix.count)))?.name ?? "Group") : displayName(conv)
    }

    func profilePhoto(_ phone: String) -> Data? {
        guard let p = profilePhotoPath(phone) else { return nil }
        return Vault.shared.readMigrating(URL(fileURLWithPath: p))
    }

    func profilePhotoPath(_ phone: String) -> String? {
        try? db.query("SELECT photo FROM profiles WHERE phone = ?", phone).first?.str("photo")
    }

    /// Reactions for every message in a chat at once (one query, not one per message).
    func reactions(conv: String) -> [String: [(member: String, emoji: String)]] {
        var out: [String: [(member: String, emoji: String)]] = [:]
        let rows = (try? db.query("""
            SELECT r.msgId, r.member, r.emoji FROM reactions r JOIN messages m ON m.msgId = r.msgId
            WHERE m.conv = ? ORDER BY r.ts
            """, conv)) ?? []
        for r in rows { out[r.str("msgId") ?? "", default: []].append((r.str("member") ?? "", r.str("emoji") ?? "")) }
        return out
    }

    func safetyNumber(_ peer: String) -> String? {
        guard let s = sessions.load(peer), let theirs = s.peerIdentityKey(myIdentityPublic: identity.identity.publicKey) else { return nil }
        return SafetyNumber.generate(localId: me, localIdentity: identity.identity.publicKey, remoteId: peer, remoteIdentity: theirs)
    }

    func isVerified(_ peer: String) -> Bool {
        guard let sn = safetyNumber(peer) else { return false }
        return (try? db.query("SELECT safety FROM verified WHERE phone = ?", peer).first?.str("safety")) == sn
    }

    func setVerified(_ peer: String, _ on: Bool) {
        if on, let sn = safetyNumber(peer) { try? db.run("INSERT OR REPLACE INTO verified(phone, safety) VALUES(?, ?)", peer, sn) }
        else { try? db.run("DELETE FROM verified WHERE phone = ?", peer) }
        touch()
    }

    // MARK: - Account

    private var accountDeletedWaiter: CheckedContinuation<Void, Never>?

    /// Ask the relay to erase the account, then wipe everything here.
    func deleteAccount() async {
        if relay.isConnected {
            await withCheckedContinuation { c in
                accountDeletedWaiter = c
                relay.send(Simple(type: "deleteAccount"))
                Task { try? await Task.sleep(nanoseconds: 8_000_000_000); self.accountDeletedWaiter?.resume(); self.accountDeletedWaiter = nil }
            }
        }
        eraseEverything()
    }

    func eraseEverything() {
        stop()
        db.close()
        Vault.shared.destroyKey()
        try? FileManager.default.removeItem(at: Paths.root)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory)
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.cellosig.app")
    }

    // MARK: - Text helpers

    static func preview(_ body: String, _ mime: String?) -> String {
        guard let mime else { return body }
        let label = mime.hasPrefix("image/") ? "📷 Photo" : mime.hasPrefix("video/") ? "🎬 Video" : mime.hasPrefix("audio/") ? "🎤 Audio" : "📎 File"
        return body.isEmpty ? label : "\(label): \(body)"
    }

    static func timerLabel(_ s: Int) -> String {
        func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        switch s {
        case ...0: return "off"
        case ..<60: return "\(s) seconds"
        case ..<3600: return plural(s / 60, "minute")
        case ..<86_400: return plural(s / 3600, "hour")
        case ..<(7 * 86_400): return plural(s / 86_400, "day")
        default: return plural(s / (7 * 86_400), "week")
        }
    }

    /// "30s", "5m", "8h", "1d", "1w" (the chat header).
    static func timerShort(_ s: Int) -> String {
        switch s {
        case ...0: return ""
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        case ..<(7 * 86_400): return "\(s / 86_400)d"
        default: return "\(s / (7 * 86_400))w"
        }
    }

    static func timerSentence(_ s: Int) -> String {
        s <= 0 ? "turned off disappearing messages" : "set disappearing messages to \(timerLabel(s))"
    }
}
