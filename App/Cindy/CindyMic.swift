import AVFoundation
import Foundation

/// Tap-to-talk: records 16 kHz mono 16-bit (what Whisper on the PC takes) until the user goes quiet for a moment,
/// taps again, or 30 s pass. The PC transcribes it; no wake word needed inside an app.
final class CindyMic {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var heardSpeech = false
    private var quietMs = 0.0
    private var noise = 300.0
    private var onDone: ((Data?) -> Void)?
    private(set) var active = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Asks for the microphone the first time; onDone gets the recording (nil = nothing said, or no mic).
    func start(_ onDone: @escaping (Data?) -> Void) {
        guard !active else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { return onDone(nil) }
                self.begin(onDone)
            }
        }
    }

    private func begin(_ onDone: @escaping (Data?) -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { return onDone(nil) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = AVAudioConverter(from: format, to: target) else { return onDone(nil) }
        converter = conv
        pcm = Data()
        heardSpeech = false
        quietMs = 0
        noise = 300
        self.onDone = onDone
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        do {
            try engine.start()
            active = true
        } catch {
            input.removeTap(onBus: 0)
            onDone(nil)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        var sum = 0.0
        for i in 0..<n { sum += abs(Double(samples[i])) }
        let level = sum / Double(n)
        let chunk = Data(bytes: samples, count: n * 2)
        let ms = Double(n) / 16.0
        DispatchQueue.main.async { self.add(chunk, level: level, ms: ms) }
    }

    private func add(_ chunk: Data, level: Double, ms: Double) {
        guard active else { return }
        pcm.append(chunk)
        if !heardSpeech && pcm.count < 16000 { noise = noise * 0.7 + level * 0.3 }  // first 0.5 s: room noise
        if level > max(noise * 2.5, 500) {
            heardSpeech = true
            quietMs = 0
        } else if heardSpeech {
            quietMs += ms
            if quietMs >= 1200 { return finish() }  // 1.2 s of quiet after speaking
        } else if pcm.count > 8 * 16000 * 2 {
            return finish()  // nothing said in 8 s
        }
        if pcm.count >= 30 * 16000 * 2 { finish() }
    }

    /// Tapped again (or done by itself): send what we have.
    func finish() {
        guard active else { return }
        active = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let done = onDone
        onDone = nil
        done?(heardSpeech && pcm.count >= 3200 ? pcm : nil)
    }
}
