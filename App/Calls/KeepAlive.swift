import AVFoundation
import Foundation

/// Sideloaded builds (free Apple ID) can't receive push notifications, so iOS
/// would suspend the app — and its relay connection — moments after it leaves
/// the screen. This keeps it running by playing silence (the "audio" background
/// mode), so messages still notify and calls still ring.
/// Costs some battery; Settings can turn it off. Not in App Store/TestFlight
/// builds, which get woken by push instead.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    /// Only builds packaged for sideloading carry this Info.plist flag.
    static var available: Bool { Bundle.main.object(forInfoDictionaryKey: "CellosigKeepAlive") as? Bool == true }

    var enabled: Bool {
        get { Self.available && (Shared.defaults.object(forKey: "keep_alive") as? Bool ?? true) }
        set { Shared.defaults.set(newValue, forKey: "keep_alive"); newValue ? start() : stop() }
    }

    private var player: AVAudioPlayer?
    private var observing = false
    private var retry: Task<Void, Never>?
    private var heartbeat: Timer?

    /// Start (or resume after a call, voice note or interruption). If iOS won't
    /// hand over the audio right now (e.g. a call is just giving it back), try again shortly.
    func start() {
        guard enabled, !CallManager.shared.inCall else { return }
        observe()
        if attempt() { retry?.cancel(); retry = nil } else { scheduleRetry() }
    }

    private func attempt() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch { return false }
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence())
            player?.numberOfLoops = -1
        }
        if player?.isPlaying != true, player?.play() != true { return false }
        beat()
        return true
    }

    /// Something else needs the audio session (a call, recording, playback).
    func stop() {
        retry?.cancel()
        retry = nil
        player?.stop()
    }

    var isRunning: Bool { player?.isPlaying == true }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task {
            defer { self.retry = nil }
            for delay in [1, 2, 5, 10, 30] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled, self.enabled, !CallManager.shared.inCall else { return }
                if self.attempt() { return }
            }
        }
    }

    // MARK: - Did iOS pause us anyway?

    /// While running, note the time every 20 s. Back in the foreground, a long
    /// gap since the last note means iOS suspended the app in the background
    /// (so messages and calls didn't arrive until it was opened).
    private func beat() {
        Shared.defaults.set(Date().timeIntervalSince1970, forKey: "keepalive_beat")
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in
                guard KeepAlive.shared.isRunning else { return }
                Shared.defaults.set(Date().timeIntervalSince1970, forKey: "keepalive_beat")
            }
        }
    }

    private var backgroundedAt: Date?

    func enteredBackground() {
        backgroundedAt = Date()
        start()   // make sure it's actually playing as we leave the screen
    }

    /// Back on screen: was the app paused while away?
    func enteredForeground() {
        defer { backgroundedAt = nil }
        guard enabled, let away = backgroundedAt, Date().timeIntervalSince(away) > 90 else { return }
        let last = Shared.defaults.double(forKey: "keepalive_beat")
        if Date().timeIntervalSince1970 - last > 75 {
            Shared.defaults.set(Date().timeIntervalSince1970, forKey: "keepalive_paused_at")
        } else {
            Shared.defaults.removeObject(forKey: "keepalive_paused_at")
        }
        start()
    }

    /// When iOS last paused the app in the background (nil: it stayed running).
    var pausedAt: Date? {
        let t = Shared.defaults.double(forKey: "keepalive_paused_at")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { Task { @MainActor in KeepAlive.shared.start() } }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in KeepAlive.shared.player = nil; KeepAlive.shared.start() }
        }
    }

    /// One second of silent 8 kHz mono 16-bit WAV.
    private static func silence() -> Data {
        let rate = 8000, samples = rate
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + samples * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(samples * 2)
        d.append(Data(count: samples * 2))
        return d
    }
}
