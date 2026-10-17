import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// Pictures from other people are decoded scaled down: a crafted image that
/// claims 30000×30000 pixels would otherwise exhaust memory and crash the app
/// as soon as the chat opens (the Android client caps them the same way).
enum ImageDecode {
    static let maxPixels = 1600
    private static let maxSourcePixels = 120_000_000
    private static let maxFrames = 50
    private static let cache: NSCache<NSNumber, UIImage> = { let c = NSCache<NSNumber, UIImage>(); c.countLimit = 60; return c }()

    /// A chat picture, decrypted and decoded once (chats redraw often).
    static func forMessage(_ row: Int64, _ load: () -> Data?) -> UIImage? {
        if let hit = cache.object(forKey: NSNumber(value: row)) { return hit }
        guard let data = load(), let img = animated(data) ?? still(data) else { return nil }
        cache.setObject(img, forKey: NSNumber(value: row))
        return img
    }

    private static func source(_ data: Data) -> CGImageSource? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h <= maxSourcePixels
        else { return nil }
        return src
    }

    private static func frame(_ src: CGImageSource, _ i: Int, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, i, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    static func still(_ data: Data, maxPixels: Int = maxPixels) -> UIImage? {
        guard let src = source(data), let img = frame(src, 0, maxPixels: maxPixels) else { return nil }
        return UIImage(cgImage: img)
    }

    /// GIFs (and animated PNG/WebP): at most 50 frames at 360 px, like Android. nil if it's a single frame.
    static func animated(_ data: Data) -> UIImage? {
        guard let src = source(data) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<min(count, maxFrames) {
            guard let img = frame(src, i, maxPixels: 360) else { break }
            frames.append(UIImage(cgImage: img))
            total += delay(src, i)
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: total) : frames.first
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let dicts = [props?[kCGImagePropertyGIFDictionary], props?[kCGImagePropertyPNGDictionary], props?[kCGImagePropertyWebPDictionary]]
            .compactMap { $0 as? [CFString: Any] }
        let keys = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                    kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
                    kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime]
        let d = dicts.lazy.compactMap { dict in keys.lazy.compactMap { dict[$0] as? Double }.first }.first ?? 0.1
        return min(max(d, 0.02), 10)   // a crafted delay can't freeze the animation for hours
    }
}

/// UIImageView, so animated images play (SwiftUI's Image shows only the first frame).
struct AnimatedImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image; v.startAnimating() }
    }
}

// MARK: - Voice notes

/// Records a voice note (AAC in .m4a, like Android's) into a protected temporary file.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var started: Date?
    private var recorder: AVAudioRecorder?
    private var file: URL?
    static let maxSeconds: TimeInterval = 15 * 60

    func start() async -> Bool {
        guard !recording, !CallManager.shared.inCall, await AVAudioApplication.requestRecordPermission() else { return false }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let url = dir.appendingPathComponent(UUID().uuidString + ".m4a")
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ])
            guard r.record(forDuration: Self.maxSeconds) else { return false }
            recorder = r
            file = url
            started = Date()
            recording = true
            return true
        } catch {
            return false
        }
    }

    /// Stop and hand back the recording (nil if it's too short to be on purpose).
    func finish() -> Data? {
        let length = started.map { Date().timeIntervalSince($0) } ?? 0
        recorder?.stop()
        defer { cleanUp() }
        guard length >= 0.7, let file else { return nil }
        return try? Data(contentsOf: file)
    }

    func cancel() {
        recorder?.stop()
        cleanUp()
    }

    private func cleanUp() {
        if let file { try? FileManager.default.removeItem(at: file) }
        recorder = nil
        file = nil
        started = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Plays a voice note from memory: the decrypted audio never touches the disk.
/// It isn't parsed at all until you press play.
struct VoiceNoteView: View {
    @EnvironmentObject var m: Messenger
    let msg: Message
    @StateObject private var player = VoicePlayer()

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle { m.attachmentData(msg) } } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: player.progress).frame(width: 130)
                Text(player.duration.map { CallManager.formatDuration(Int($0.rounded())) } ?? "Voice note").font(.caption2).opacity(0.8)
            }
        }
    }
}

@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var duration: TimeInterval?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(load: () -> Data?) {
        if playing { player?.pause(); stopTimer(); playing = false; return }
        if player == nil {
            guard !CallManager.shared.inCall, let data = load(), let p = try? AVAudioPlayer(data: data) else { return }
            p.delegate = self
            player = p
            duration = p.duration
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.playing = false
            self.progress = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Stickers

/// Built-in stickers: big emoji drawn into a 512 px PNG on the phone, sent as
/// kind "sticker" (shown without a bubble on both iPhone and Android).
struct StickerPicker: View {
    @Environment(\.dismiss) private var dismiss
    let pick: (Data) -> Void
    static let pack = ["😀", "😂", "🥹", "😍", "😎", "🤔", "😴", "😭", "😡", "🥳", "👍", "👎", "👏", "🙏", "💪", "🤝",
                       "❤️", "💔", "🔥", "✨", "🎉", "🎂", "☕️", "🍕", "🐶", "🐱", "🦄", "🌈", "⭐️", "🌙", "✅", "❓"]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                    ForEach(Self.pack, id: \.self) { e in
                        Button {
                            if let png = Self.render(e) { pick(png) }
                            dismiss()
                        } label: { Text(e).font(.system(size: 54)) }
                    }
                }
                .padding()
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    static func render(_ emoji: String) -> Data? {
        let side: CGFloat = 512
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let text = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: 400)])
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }
        return img.pngData()
    }
}
