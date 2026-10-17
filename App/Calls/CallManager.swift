import AVFoundation
import CallKit
import CellosigCore
import Foundation
import os
import PushKit
import UIKit
import UserNotifications
import WebRTC

/// One-to-one encrypted voice calls (the iOS port of the Android CallManager).
///
/// Security: WebRTC always encrypts media (DTLS-SRTP). What makes it END-TO-END
/// is that the offer/answer SDP — which pins each side's DTLS certificate
/// fingerprint — travels only inside our Double Ratchet messages, so the relay
/// (and any TURN server) only ever forwards ciphertext.
///
/// Signalling is non-trickle, exactly like Android: each side waits for ICE
/// gathering (bounded) and sends one SDP with all its candidates.
///
/// iOS specifics: calls go through CallKit (the system call screen, also on
/// the lock screen), and a closed app is woken by a VoIP push from the relay.
/// iOS insists that every VoIP push shows a call at once, before we know who's
/// calling, so the push shows "cellosig" ringing while the app connects and
/// decrypts the offer; if no offer turns up, that call ends by itself.
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    enum Phase { case calling, ringing, incoming, connecting, active, ended }

    struct State: Equatable {
        var id: String
        var uuid: UUID
        var peer: String
        var outgoing: Bool
        var phase: Phase
        var connectedAt: Date?
        var muted = false
        var speaker = false
        var endReason: String?
        /// iOS refused to show this call through CallKit (it happens to sideloaded
        /// copies): it runs on our own call screen instead, with our own ringing.
        var kitless = false
        /// A call with an ordinary phone, through the relay's bridge (NOT end-to-end encrypted).
        var pstn = false
        /// The phone network's name for an incoming caller, if the relay looked it up.
        var networkName: String?
        /// For a phone call we place: its audio link is up before they pick up, so
        /// it only counts as answered once the relay says so.
        var remoteAnswered = true
    }

    /// The audio link is up (for a phone call, possibly before they answer).
    private var mediaConnected = false

    @Published private(set) var state: State?

    private static let ringTimeoutNs: UInt64 = 45_000_000_000
    private static let gatherTimeoutNs: UInt64 = 4_000_000_000
    // An offer that sat in the relay's queue longer than this is a call that already gave up.
    private static let staleOfferMs: Int64 = 40_000
    // Offline longer than this: skip the missed-call entry (it'd just be noise).
    private static let missedLogMaxMs: Int64 = 7 * 86_400_000

    let log = Logger(subsystem: "com.cellosig.app", category: "cellosig-call")
    private var messenger: Messenger? { AppModel.shared.messenger }

    private let provider: CXProvider
    private let controller = CXCallController()
    private var voip: PKPushRegistry?

    private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()
    private var pc: RTCPeerConnection?
    private var track: RTCAudioTrack?
    private var remoteOffer: String?
    private var timeout: Task<Void, Never>?
    private var gatherWaiter: CheckedContinuation<Void, Never>?
    private var gatherDone = false

    /// A call iOS is showing because a VoIP push came in, still waiting for its offer.
    private var placeholder: UUID?
    /// Answer pressed on that call before its offer arrived.
    private var pendingAnswer: CXAnswerCallAction?
    /// Declined before its offer arrived: refuse the offer when it does.
    private var declinedPushAt: Date?

    private override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic, .phoneNumber]
        cfg.includesCallsInRecents = false   // keep who you talk to out of the Phone app's history
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)   // main queue
        // WebRTC plays and records only once CallKit has activated the audio session.
        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.voiceChat.rawValue
        audio.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        RTCAudioSessionConfiguration.setWebRTC(audio)
    }

    /// Register for VoIP pushes (must happen at every launch).
    func registerForVoIP() {
        guard voip == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        voip = r
    }

    var inCall: Bool { state.map { $0.phase != .ended } ?? false }

    /// The phone button in a chat: someone without cellosig can't take an app
    /// call, so ring their phone instead (through the relay), if this account
    /// may (as on Android).
    func callSmart(_ peer: String) {
        // (Offline, the lookup finds nobody: don't mistake that for "not on cellosig".)
        guard let m = messenger, m.pstnAvailable, m.connected, !Messenger.isGroup(peer), peer.hasPrefix("+1") else { call(peer); return }
        Task {
            let onCellosig = await m.lookup([peer]).contains(peer)
            call(peer, pstn: !onCellosig)
        }
    }

    // MARK: - User actions

    /// Place a call (CallKit then asks us to start it: see perform(start:)).
    /// `pstn`: ring an ordinary phone through the relay's phone bridge.
    func call(_ peer: String, pstn: Bool = false) {
        guard !inCall, placeholder == nil else { return }
        let s = State(id: UUID().uuidString.lowercased(), uuid: UUID(), peer: peer, outgoing: true, phase: .calling,
                      pstn: pstn, remoteAnswered: !pstn)
        state = s
        let action = CXStartCallAction(call: s.uuid, handle: CXHandle(type: pstn ? .phoneNumber : .generic, value: pstn ? peer : shownName(peer)))
        controller.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            Task { @MainActor in
                // Not allowed to use the system call screen: place it on ours.
                self.log.warning("CallKit refused the call (\((error as NSError).code)); calling without it")
                guard self.state?.id == s.id else { return }
                self.state?.kitless = true
                self.activateAudioManually()
                self.startOutgoing(s)
            }
        }
    }

    func answer() {
        guard let s = state, s.phase == .incoming else { return }
        if s.kitless {
            stopRinging()
            guard let offer = remoteOffer else { return }
            activateAudioManually()
            acceptIncoming(s, offer)
            return
        }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: s.uuid))) { _ in }
    }

    func hangup() {
        guard let s = state, s.phase != .ended else { return }
        if s.kitless { userEnded(s.id); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: s.uuid))) { error in
            // CallKit no longer knows the call: end it ourselves.
            if error != nil { Task { @MainActor in self.userEnded(s.id) } }
        }
    }

    func toggleMute() {
        guard let s = state else { return }
        if s.kitless {
            track?.isEnabled = s.muted   // was muted: unmute
            state?.muted.toggle()
            return
        }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: s.uuid, muted: !s.muted))) { _ in }
    }

    func toggleSpeaker() {
        guard var s = state else { return }
        s.speaker.toggle()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.overrideOutputAudioPort(s.speaker ? .speaker : .none)
        rtc.unlockForConfiguration()
        state = s
    }

    // MARK: - Signalling from the peer

    /// Signalling for a call: from a cellosig contact (end to end), or with
    /// `pstn` from the relay's phone bridge (`networkName`: the phone network's
    /// caller name; `error`: why the relay refused a phone call).
    func onSignal(_ from: String, _ sig: CallSignal, _ ts: Int64, pstn: Bool = false, networkName: String? = nil, error: String? = nil) {
        let s = state
        log.info("call signal \(sig.kind, privacy: .public) from \(PhoneNumbers.mask(from), privacy: .public)\(pstn ? " (phone)" : "")")
        if let error { log.warning("phone call refused by the relay: \(error, privacy: .public)") }
        switch sig.kind {
        case "offer":
            let waited = nowMs() - ts
            if waited > Self.staleOfferMs {
                // They called while we were offline; the call is long over, but say so.
                if waited < Self.missedLogMaxMs { messenger?.logCall(from, outgoing: false, text: "📞 Missed call", missed: true, phoneCall: pstn) }
                return
            }
            if let s, s.phase != .ended {
                if s.id != sig.id { send(from, CallSignal(id: sig.id, kind: "busy"), pstn: pstn) }
                return
            }
            // Lockdown mode: only contacts with a verified safety number may ring (so no phone calls).
            if Lockdown.on, pstn || messenger.map({ !$0.isVerified(from) || $0.trustBroken(from) }) ?? true {
                send(from, CallSignal(id: sig.id, kind: "busy"), pstn: pstn)
                messenger?.logCall(from, outgoing: false, text: "📞 Missed call (Lockdown mode: only verified contacts can call)", missed: true, phoneCall: pstn)
                return
            }
            if let at = declinedPushAt, Date().timeIntervalSince(at) < 30 {
                declinedPushAt = nil
                send(from, CallSignal(id: sig.id, kind: "hangup", reason: "declined"), pstn: pstn)
                messenger?.logCall(from, outgoing: false, text: "📞 Declined call", missed: false, phoneCall: pstn)
                return
            }
            guard let sdp = sig.sdp else { return }
            remoteOffer = sdp
            let uuid = placeholder ?? UUID()
            let adopting = placeholder != nil
            placeholder = nil
            state = State(id: sig.id, uuid: uuid, peer: from, outgoing: false, phase: .incoming, pstn: pstn, networkName: networkName)
            send(from, CallSignal(id: sig.id, kind: "ringing"), pstn: pstn)
            if adopting {
                provider.reportCall(with: uuid, updated: update(from))
                if let a = pendingAnswer { pendingAnswer = nil; accept(a) }
            } else {
                provider.reportNewIncomingCall(with: uuid, update: update(from)) { error in
                    guard let error else { return }
                    Task { @MainActor in
                        guard self.isCurrent(sig.id) else { return }
                        let code = (error as NSError).code
                        if code == CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue
                            || code == CXErrorCodeIncomingCallError.filteredByBlockList.rawValue {
                            // Focus / Do Not Disturb, or blocked in iOS settings: they meant it.
                            self.end(sig.id, "missed", notify: true, signal: "busy", tellCallKit: false)
                        } else {
                            // iOS won't let this copy use the system call screen (sideloaded):
                            // ring on our own screen instead of turning the call away.
                            self.log.warning("CallKit refused the incoming call (\(code)); ringing without it")
                            self.state?.kitless = true
                            self.startRinging(from)
                        }
                    }
                }
            }
            armTimeout(sig.id) { $0.end(sig.id, "missed", notify: false) }
        default:
            // Everything else must belong to the current call, from its peer (the relay's
            // replies about a phone call we placed carry the number we dialled).
            guard let s, s.id == sig.id, s.pstn == pstn, s.peer == from || (pstn && from.isEmpty), s.phase != .ended else { return }
            switch sig.kind {
            case "ringing":
                // A phone call brings the network's own ringback over the audio link.
                if s.phase == .calling { state?.phase = .ringing; if !s.pstn { startRingback() } }
            case "progress":
                // Calling a phone: the relay's side of the audio link, so it connects while it rings.
                guard s.pstn, s.outgoing, s.phase == .calling || s.phase == .ringing, let conn = pc, let sdp = sig.sdp else { return }
                Task {
                    do { try await conn.setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) }
                    catch { self.end(s.id, "failed", notify: true, signal: "failed") }
                }
            case "answer" where s.pstn && sig.sdp == nil:
                // The phone was picked up.
                timeout?.cancel()
                state?.remoteAnswered = true
                if mediaConnected {
                    state?.phase = .active
                    state?.connectedAt = Date()
                    if !s.kitless { provider.reportOutgoingCall(with: s.uuid, connectedAt: Date()) }
                } else {
                    state?.phase = .connecting
                    armTimeout(s.id) { $0.end(s.id, "failed", notify: true, signal: "failed") }
                }
            case "answer":
                guard let conn = pc, let sdp = sig.sdp else { return }
                timeout?.cancel()
                stopRingback()
                state?.phase = .connecting
                provider.reportOutgoingCall(with: s.uuid, startedConnectingAt: Date())
                Task {
                    do { try await conn.setRemote(RTCSessionDescription(type: .answer, sdp: sdp)) }
                    catch { self.end(s.id, "failed", notify: true, signal: "failed"); return }
                    self.armTimeout(s.id) { $0.end(s.id, "failed", notify: true, signal: "failed") }
                }
            case "busy": end(s.id, "busy", notify: false)
            case "hangup": end(s.id, error ?? sig.reason ?? "ended", notify: false)
            default: break
            }
        }
    }

    // MARK: - CallKit actions

    private func perform(start action: CXStartCallAction) {
        guard let s = state, s.uuid == action.callUUID, s.outgoing else { action.fail(); return }
        configureAudioSession()
        action.fulfill()
        provider.reportCall(with: s.uuid, updated: update(s.peer))
        startOutgoing(s)
    }

    /// Make the offer and send it (with or without CallKit).
    private func startOutgoing(_ s: State) {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                self.end(s.id, "no_microphone", notify: false); return
            }
            do {
                let conn = try await self.newConnection()
                let offer = try await conn.makeOffer()
                try await conn.setLocal(offer)
                await self.awaitGathering()
                guard self.isCurrent(s.id), let sdp = conn.localDescription?.sdp, let m = self.messenger else { return }
                let signal = CallSignal(id: s.id, kind: "offer", sdp: sdp)
                let sent = s.pstn ? m.sendPstnSignal(s.peer, signal) : await m.sendCallSignal(s.peer, signal)
                guard sent else { self.end(s.id, "failed", notify: false); return }
                self.armTimeout(s.id) { $0.end(s.id, "no_answer", notify: true, signal: "missed") }
            } catch {
                self.end(s.id, "failed", notify: false)
            }
        }
    }

    private func perform(answer action: CXAnswerCallAction) {
        if action.callUUID == placeholder { pendingAnswer = action; return }   // the offer is still on its way
        accept(action)
    }

    private func accept(_ action: CXAnswerCallAction) {
        guard let s = state, s.uuid == action.callUUID, s.phase == .incoming, let offer = remoteOffer else { action.fail(); return }
        configureAudioSession()
        action.fulfill()
        acceptIncoming(s, offer)
    }

    /// Answer the offer (with or without CallKit).
    private func acceptIncoming(_ s: State, _ offer: String) {
        timeout?.cancel()
        state?.phase = .connecting
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                self.end(s.id, "declined", notify: true, signal: "declined"); return
            }
            do {
                let conn = try await self.newConnection()
                try await conn.setRemote(RTCSessionDescription(type: .offer, sdp: offer))
                let answer = try await conn.makeAnswer()
                try await conn.setLocal(answer)
                await self.awaitGathering()
                guard self.isCurrent(s.id), let sdp = conn.localDescription?.sdp else { return }
                self.send(s.peer, CallSignal(id: s.id, kind: "answer", sdp: sdp), pstn: s.pstn)
                // If media never connects, don't sit on "Connecting…" forever.
                self.armTimeout(s.id) { $0.end(s.id, "failed", notify: true, signal: "failed") }
            } catch {
                self.end(s.id, "failed", notify: true, signal: "failed")
            }
        }
    }

    private func perform(end action: CXEndCallAction) {
        action.fulfill()
        if action.callUUID == placeholder {
            placeholder = nil
            pendingAnswer?.fail()
            pendingAnswer = nil
            declinedPushAt = Date()
            return
        }
        guard let s = state, s.uuid == action.callUUID else { return }
        userEnded(s.id)
    }

    private func userEnded(_ id: String) {
        guard let s = state, s.id == id, s.phase != .ended else { return }
        let reason = s.phase == .incoming ? "declined" : s.phase == .active ? "ended" : "missed"  // missed: we gave up before they answered
        end(id, reason, notify: true, signal: reason, tellCallKit: false)
    }

    private func perform(mute action: CXSetMutedCallAction) {
        guard let s = state, s.uuid == action.callUUID else { action.fail(); return }
        track?.isEnabled = !action.isMuted
        state?.muted = action.isMuted
        action.fulfill()
    }

    private func configureAudioSession() {
        KeepAlive.shared.stop()   // the call owns the audio session now
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.setConfiguration(RTCAudioSessionConfiguration.webRTC())
        rtc.unlockForConfiguration()
    }

    // MARK: - Calls without CallKit

    /// CallKit normally switches the audio on for a call; without it we do it ourselves.
    private func activateAudioManually() {
        configureAudioSession()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.setActive(true)
        rtc.unlockForConfiguration()
        rtc.audioSessionDidActivate(AVAudioSession.sharedInstance())
        rtc.isAudioEnabled = true
    }

    private func deactivateAudioManually() {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.lockForConfiguration()
        try? rtc.setActive(false)
        rtc.unlockForConfiguration()
        rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        KeepAlive.shared.start()
    }

    private var ringer: Task<Void, Never>?
    private static let ringNotificationId = "incoming-call"

    /// Ring on our own: our call screen is up (RootView shows it), the phone
    /// buzzes and plays the alert sound until answered or ended, and in the
    /// background a notification says a call is coming in.
    private func startRinging(_ from: String) {
        stopRinging()
        if UIApplication.shared.applicationState != .active {
            let c = UNMutableNotificationContent()
            c.title = "Incoming call"
            c.body = Shared.defaults.bool(forKey: "notify_preview") ? "\(shownName(from)) is calling — tap to answer" : "Tap to answer"
            c.sound = .defaultCritical
            c.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.ringNotificationId, content: c, trigger: nil))
        }
        // A real ringtone at full volume (the system alert sound was too quiet to notice).
        KeepAlive.shared.stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        ringPlayer = try? AVAudioPlayer(data: Tones.ring)
        ringPlayer?.numberOfLoops = -1
        ringPlayer?.volume = 1
        ringPlayer?.play()
        ringer = Task {
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var ringPlayer: AVAudioPlayer?

    private func stopRinging() {
        ringer?.cancel()
        ringer = nil
        if ringPlayer != nil {
            ringPlayer?.stop()
            ringPlayer = nil
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.ringNotificationId])
    }

    /// "Ring… ring…" for the caller while the other phone rings (through the call's audio, like a phone call).
    private var ringbackPlayer: AVAudioPlayer?

    private func startRingback() {
        stopRingback()
        ringbackPlayer = try? AVAudioPlayer(data: Tones.ringback)
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.volume = 0.8
        ringbackPlayer?.play()
    }

    private func stopRingback() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    // MARK: - VoIP push

    private func incomingPush(_ info: [AnyHashable: Any], _ done: @escaping () -> Void) {
        if let url = RelayAddress.accept(info["r"]) { messenger?.moveRelay(to: url) }
        let u = UUID()
        guard !inCall, placeholder == nil, let m = messenger else {
            // iOS still requires a call for every VoIP push: show it and end it at once.
            provider.reportNewIncomingCall(with: u, update: update(nil)) { _ in
                Task { @MainActor in
                    self.provider.reportCall(with: u, endedAt: nil, reason: .unanswered)
                    done()
                }
            }
            return
        }
        placeholder = u
        provider.reportNewIncomingCall(with: u, update: update(nil)) { error in
            Task { @MainActor in
                if error != nil, self.placeholder == u { self.placeholder = nil }
                done()
            }
        }
        m.wakeForCall()
        Task {
            await m.waitUntilQuiet(maxSeconds: 12)
            // Everything waiting was read and none of it was a call we can ring for
            // (it was stale, cancelled, from a stranger or a blocked number).
            guard self.placeholder == u else { return }
            self.placeholder = nil
            self.pendingAnswer?.fail()
            self.pendingAnswer = nil
            self.provider.reportCall(with: u, endedAt: nil, reason: .remoteEnded)
        }
    }

    // MARK: - WebRTC

    private func newConnection() async throws -> RTCPeerConnection {
        var servers = (await messenger?.iceServers() ?? []).map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        if servers.isEmpty { servers = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])] }
        let config = RTCConfiguration()
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        // With a direct path the other person learns your IP address (and so
        // roughly where you are). When a TURN relay is available, send audio
        // only through it so neither side sees the other's address.
        if servers.contains(where: { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }) {
            config.iceTransportPolicy = .relay
        }
        gatherDone = false
        mediaConnected = false
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let conn = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { throw CallError.setup }
        let source = factory.audioSource(with: constraints)
        let t = factory.audioTrack(with: source, trackId: "audio0")
        conn.add(t, streamIds: ["cellosig"])
        track = t
        pc = conn
        return conn
    }

    private func awaitGathering() async {
        if gatherDone { return }
        await withCheckedContinuation { c in
            gatherWaiter = c
            Task {
                try? await Task.sleep(nanoseconds: Self.gatherTimeoutNs)
                self.gatheringFinished()
            }
        }
    }

    private func gatheringFinished() {
        gatherDone = true
        gatherWaiter?.resume()
        gatherWaiter = nil
    }

    private func connectionChanged(_ conn: RTCPeerConnection, _ newState: RTCPeerConnectionState) {
        guard conn === pc, let s = state else { return }
        switch newState {
        case .connected:
            mediaConnected = true
            // A phone call that's still ringing: the link is ready, but nobody picked up yet.
            guard s.phase != .active, s.remoteAnswered else { return }
            timeout?.cancel()
            state?.phase = .active
            state?.connectedAt = Date()
            if s.outgoing && !s.kitless { provider.reportOutgoingCall(with: s.uuid, connectedAt: Date()) }
        case .failed:
            end(s.id, "failed", notify: true, signal: "failed")
        default: break
        }
    }

    // MARK: - Ending

    private func end(_ id: String, _ reason: String, notify: Bool, signal: String? = nil, tellCallKit: Bool = true) {
        guard let s = state, s.id == id, s.phase != .ended else { return }
        log.info("call ended: \(reason, privacy: .public)")
        timeout?.cancel()
        if notify, let signal { send(s.peer, CallSignal(id: id, kind: "hangup", reason: signal), pstn: s.pstn) }
        stopRingback()
        if s.kitless {
            stopRinging()
            if s.phase != .incoming { deactivateAudioManually() }
        } else if tellCallKit {
            provider.reportCall(with: s.uuid, endedAt: Date(), reason: Self.kitReason(reason, outgoing: s.outgoing))
        }
        pc?.close()
        pc = nil
        track = nil
        remoteOffer = nil
        gatheringFinished()
        state?.phase = .ended
        state?.endReason = reason
        // Without CallKit nothing else hands the audio back: keep this copy reachable again.
        if s.kitless { KeepAlive.shared.start() }
        logCall(s, reason)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the call screen show "Call ended" briefly
            if self.state?.id == id { self.state = nil }
        }
    }

    private static func kitReason(_ reason: String, outgoing: Bool) -> CXCallEndedReason {
        switch reason {
        case "failed", "no_microphone": return .failed
        case "missed", "no_answer": return outgoing ? .remoteEnded : .unanswered
        default: return .remoteEnded
        }
    }

    private func logCall(_ s: State, _ reason: String) {
        let duration = s.connectedAt.map { Int(Date().timeIntervalSince($0)) }
        let text: String
        if let d = duration { text = (s.outgoing ? "📞 Outgoing call · " : "📞 Incoming call · ") + Self.formatDuration(d) }
        else if !s.outgoing && (reason == "missed" || reason == "no_answer") { text = "📞 Missed call" }
        else if !s.outgoing && reason == "declined" { text = "📞 Declined call" }
        else if s.outgoing && reason == "busy" { text = "📞 Outgoing call · busy" }
        else if s.outgoing && reason == "declined" { text = "📞 Outgoing call · declined" }
        else if s.outgoing && reason == "no_microphone" { text = "📞 Call not placed · microphone access is off (Settings → cellosig)" }
        else if s.outgoing, let why = Self.phoneRefusal(reason) { text = "📞 Call not placed · \(why)" }
        else if s.outgoing { text = "📞 Outgoing call · no answer" }
        else { text = "📞 Missed call" }
        messenger?.logCall(s.peer, outgoing: s.outgoing, text: text, missed: !s.outgoing && duration == nil && reason != "declined", phoneCall: s.pstn)
    }

    /// Why the relay wouldn't place a phone call, in words (nil: not a refusal).
    static func phoneRefusal(_ reason: String?) -> String? {
        switch reason {
        case "not_allowed": return "phone calls aren't set up for this account"
        case "destination_not_allowed": return "that number can't be called (premium or not allowed)"
        case "not_configured", "unavailable": return "the relay's phone line isn't available"
        default: return nil
        }
    }

    static func formatDuration(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    private func armTimeout(_ id: String, _ onTimeout: @escaping @MainActor (CallManager) -> Void) {
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(nanoseconds: Self.ringTimeoutNs)
            guard !Task.isCancelled, self.isCurrent(id) else { return }
            onTimeout(self)
        }
    }

    /// To a cellosig contact (end to end), or for a phone call to the relay's bridge.
    private func send(_ peer: String, _ sig: CallSignal, pstn: Bool = false) {
        if pstn { _ = messenger?.sendPstnSignal(peer, sig); return }
        Task { _ = await messenger?.sendCallSignal(peer, sig) }
    }

    private func isCurrent(_ id: String) -> Bool { state.map { $0.id == id && $0.phase != .ended } ?? false }

    /// What the system call screen shows. The caller's name only if notifications may show names.
    private func shownName(_ peer: String?) -> String {
        guard let peer, Shared.defaults.bool(forKey: "notify_preview") else { return "cellosig" }
        // A phone call: the network's caller name if there is one (it isn't in your cellosig chats).
        if let s = state, s.pstn, s.peer == peer, let n = s.networkName, messenger?.hasProfileName(peer) != true { return n }
        return messenger?.displayName(peer) ?? PhoneNumbers.pretty(peer)
    }

    private func update(_ peer: String?) -> CXCallUpdate {
        let u = CXCallUpdate()
        let name = shownName(peer)
        u.remoteHandle = CXHandle(type: .generic, value: name)
        u.localizedCallerName = name
        u.hasVideo = false
        u.supportsHolding = false
        u.supportsGrouping = false
        u.supportsUngrouping = false
        u.supportsDTMF = false
        return u
    }

    enum CallError: Error { case setup, sdp }
}

// MARK: - CallKit

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            if let s = state { end(s.id, "failed", notify: true, signal: "failed", tellCallKit: false) }
            placeholder = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated { perform(start: action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { perform(answer: action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { perform(end: action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { perform(mute: action) }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        Task { @MainActor in KeepAlive.shared.start() }   // sideloaded builds: stay reachable after the call
    }
}

// MARK: - PushKit

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            Shared.defaults.set(hex, forKey: "voip_token")
            messenger?.setVoipToken(hex)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated { Shared.defaults.removeObject(forKey: "voip_token") }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        MainActor.assumeIsolated { incomingPush(payload.dictionaryPayload, completion) }
    }
}

// MARK: - WebRTC callbacks (on WebRTC's own thread)

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.connectionChanged(peerConnection, newState) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in if peerConnection === self.pc { self.gatheringFinished() } }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}  // non-trickle: sent inside the SDP
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Callback -> async bridges for WebRTC's SDP API

private extension RTCPeerConnection {
    private static var noConstraints: RTCMediaConstraints { RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil) }

    func makeOffer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            offer(for: Self.noConstraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? CallManager.CallError.sdp) }
            }
        }
    }

    func makeAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { c in
            answer(for: Self.noConstraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? CallManager.CallError.sdp) }
            }
        }
    }

    func setLocal(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setLocalDescription(sdp) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }

    func setRemote(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            setRemoteDescription(sdp) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }
}
