import Foundation

/// Call sounds, synthesized (no audio files in the app): the ringtone for
/// calls iOS won't ring through CallKit, and the ringback the caller hears.
enum Tones {
    /// North-American ringback: 440 + 480 Hz, 2 s on, 4 s off (loops).
    static let ringback: Data = wav(seconds: 6, amplitude: 0.35) { t in
        t < 2 ? (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) / 2 : 0
    }

    /// Ringtone: two quick warbling bursts, then a pause (3 s, loops).
    static let ring: Data = wav(seconds: 3, amplitude: 0.9) { t in
        let burst = (t < 0.4) || (t >= 0.6 && t < 1.0)
        guard burst else { return 0 }
        let f = Int(t * 20) % 2 == 0 ? 1046.5 : 1318.5   // C6 / E6, switching 20 times a second
        return sin(2 * .pi * f * t)
    }

    /// 16 kHz mono 16-bit PCM WAV; `sample` gives -1…1 at time t (seconds).
    private static func wav(seconds: Double, amplitude: Double, sample: (Double) -> Double) -> Data {
        let rate = 16_000, count = Int(Double(rate) * seconds)
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + count * 2); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(count * 2)
        let pcm = (0..<count).map { i -> Int16 in
            let v = max(-1, min(1, sample(Double(i) / Double(rate)) * amplitude))
            return Int16(v * Double(Int16.max)).littleEndian
        }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
