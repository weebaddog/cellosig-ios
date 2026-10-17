import AVFoundation
import Foundation

/// Sideloaded builds (free Apple ID) can't receive push notifications, so iOS
/// would suspend the app — and its relay connection — moments after it leaves
/// the screen. This keeps it running by playing silence (the "audio" background
/// mode), so messages still notify and calls still ring through CallKit.
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

    /// Start (or resume after a call, voice note or interruption).
    func start() {
        guard enabled, !CallManager.shared.inCall else { return }
        observe()
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch { return }
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence())
            player?.numberOfLoops = -1
        }
        if player?.isPlaying != true { player?.play() }
    }

    /// Something else needs the audio session (a call, recording, playback).
    func stop() {
        player?.stop()
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
