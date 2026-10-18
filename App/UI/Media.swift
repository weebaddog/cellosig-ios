import AVFoundation
import CellosigCore
import ImageIO
import PhotosUI
import Speech
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

    /// Chat pictures show about 240 pt wide: decode at most this big (smaller = faster, less memory).
    static let displayPixels = 1000

    /// A chat picture already decoded (chats redraw often).
    static func cached(_ row: Int64) -> UIImage? { cache.object(forKey: NSNumber(value: row)) }

    /// Decrypt + decode a chat picture. Meant to run OFF the main thread (see MessageImage).
    static func load(row: Int64, path: String, key: String) -> UIImage? {
        if let hit = cached(row) { return hit }
        guard let blob = try? Data(contentsOf: URL(fileURLWithPath: path)), let k = try? Primitives.unb64(key),
              let data = try? ChunkedAead.decrypt(blob, key: k),
              let img = animated(data) ?? still(data, maxPixels: displayPixels) else { return nil }
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

/// A chat picture, decrypted and decoded in the background: scrolling never
/// waits for it (it used to happen on the main thread, in the middle of drawing).
struct MessageImage: View {
    let msg: Message
    let sticker: Bool
    let tap: () -> Void
    @State private var img: UIImage?
    @State private var failed = false

    init(msg: Message, sticker: Bool, tap: @escaping () -> Void) {
        self.msg = msg
        self.sticker = sticker
        self.tap = tap
        _img = State(initialValue: ImageDecode.cached(msg.id))   // already decoded: no placeholder flash
    }

    var body: some View {
        let side: CGFloat = sticker ? 140 : 240
        Group {
            if let img, img.images != nil {
                AnimatedImage(image: img).frame(width: side, height: sticker ? side : 240 * img.size.height / max(img.size.width, 1))
                    .clipShape(RoundedRectangle(cornerRadius: sticker ? 0 : 10))
                    .onTapGesture(perform: tap)
            } else if let img {
                Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: side, maxHeight: sticker ? side : 320)
                    .clipShape(RoundedRectangle(cornerRadius: sticker ? 0 : 10))
                    .onTapGesture(perform: tap)
            } else if failed {
                Label("Picture can't be shown", systemImage: "photo").font(.caption)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15))
                    .frame(width: side, height: sticker ? side : 180)
                    .overlay(ProgressView())
            }
        }
        .task(id: msg.id) {
            guard img == nil else { return }
            guard let path = msg.filePath, let key = msg.fileKey, (msg.fileSize ?? 0) <= 30 * 1024 * 1024 else { failed = true; return }
            let row = msg.id
            let out = await Task.detached(priority: .userInitiated) { ImageDecode.load(row: row, path: path, key: key) }.value
            if let out { img = out } else { failed = true }
        }
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
        KeepAlive.shared.heldByMedia = true
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
            guard r.record(forDuration: Self.maxSeconds) else { KeepAlive.shared.heldByMedia = false; return false }
            recorder = r
            file = url
            started = Date()
            recording = true
            return true
        } catch {
            KeepAlive.shared.heldByMedia = false
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
        KeepAlive.shared.heldByMedia = false
    }
}

/// Plays a voice note from memory: the decrypted audio never touches the disk
/// (except briefly, protected, while it's being transcribed).
/// It isn't parsed at all until you press play or transcribe.
struct VoiceNoteView: View {
    @EnvironmentObject var m: Messenger
    let msg: Message
    @StateObject private var player = VoicePlayer()
    @State private var transcribing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { player.toggle { m.attachmentData(msg) } } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: player.progress).frame(width: 130)
                    Text(player.duration.map { CallManager.formatDuration(Int($0.rounded())) } ?? "Voice note").font(.caption2).opacity(0.8)
                }
            }
            if let t = msg.transcript {
                Text(t.isEmpty ? "(no words recognized)" : t).font(.callout).italic().textSelection(.enabled)
            } else if transcribing {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Transcribing…").font(.caption) }
            } else {
                Button {
                    transcribing = true
                    problem = nil
                    Task {
                        defer { transcribing = false }
                        guard let audio = m.attachmentData(msg) else { problem = "Couldn't open the voice note."; return }
                        do { m.saveTranscript(msg, try await Transcriber.transcribe(audio)) }
                        catch let e as Transcriber.Failure { problem = e.message }
                        catch { problem = "Couldn't transcribe it." }
                    }
                } label: { Label("Transcribe", systemImage: "text.quote").font(.caption) }
                .buttonStyle(.plain)
            }
            if let problem { Text(problem).font(.caption2).opacity(0.8) }
        }
        .onDisappear { player.stop() }
    }
}

/// Voice note → text with Apple's speech recognition, ON THE PHONE ONLY: if
/// this iPhone can't recognize the language on-device, it refuses rather than
/// sending the audio to Apple's servers.
enum Transcriber {
    enum Failure: Error {
        case notAllowed, unavailable

        var message: String {
            switch self {
            case .notAllowed: return "Allow Speech Recognition for cellosig in Settings to transcribe voice notes."
            case .unavailable: return "This iPhone can't transcribe this language on the phone itself (cellosig won't send audio to Apple)."
            }
        }
    }

    private final class Once { var done = false }

    static func transcribe(_ audio: Data) async throws -> String {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.supportsOnDeviceRecognition, rec.isAvailable else { throw Failure.unavailable }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let file = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        try audio.write(to: file, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: file) }
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        let once = Once()
        defer { withExtendedLifetime(rec) {} }   // the recognizer must outlive its task
        return try await withCheckedThrowingContinuation { c in
            rec.recognitionTask(with: req) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    once.done = true
                    // "No speech detected" is a result, not a failure.
                    if (error as NSError).code == 1110 { c.resume(returning: "") } else { c.resume(throwing: error) }
                }
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
        if playing { player?.pause(); stopTimer(); playing = false; KeepAlive.shared.heldByMedia = false; return }
        if player == nil {
            guard !CallManager.shared.inCall, let data = load(), let p = try? AVAudioPlayer(data: data) else { return }
            p.delegate = self
            player = p
            duration = p.duration
        }
        KeepAlive.shared.heldByMedia = true
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

    /// The note scrolled away or the chat closed.
    func stop() {
        guard playing else { return }
        player?.stop()
        stopTimer()
        playing = false
        progress = 0
        KeepAlive.shared.heldByMedia = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.playing = false
            self.progress = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            KeepAlive.shared.heldByMedia = false
        }
    }
}

// MARK: - Stickers

/// Stickers you made from your own photos (shrunk to 512 px PNG, kept in the app's protected storage).
enum MyStickers {
    private static var dir: URL {
        let d = Paths.root.appendingPathComponent("stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return d
    }

    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "png" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    static func add(_ data: Data) -> Bool {
        guard let img = ImageDecode.still(data, maxPixels: 512), let png = img.pngData() else { return false }
        return (try? Vault.shared.writeSealed(dir.appendingPathComponent(UUID().uuidString + ".png"), png)) != nil
    }

    /// The sticker's PNG (sealed on disk; ones from older builds are sealed on first read).
    static func data(_ url: URL) -> Data? { Vault.shared.readMigrating(url) }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// Built-in stickers: big emoji drawn into a 512 px PNG on the phone, sent as
/// kind "sticker" (shown without a bubble on both iPhone and Android).
struct StickerPicker: View {
    @Environment(\.dismiss) private var dismiss
    let pick: (Data) -> Void
    static let pack = ["😀", "😂", "🥹", "😍", "😎", "🤔", "😴", "😭", "😡", "🥳", "👍", "👎", "👏", "🙏", "💪", "🤝",
                       "❤️", "💔", "🔥", "✨", "🎉", "🎂", "☕️", "🍕", "🐶", "🐱", "🦄", "🌈", "⭐️", "🌙", "✅", "❓"]
    @State private var mine = MyStickers.all()
    @State private var newPhoto: PhotosPickerItem?
    @State private var addFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("My stickers").font(.headline).padding(.horizontal)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        PhotosPicker(selection: $newPhoto, matching: .images) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.title)
                                Text("From a photo").font(.caption2)
                            }
                            .frame(width: 72, height: 72)
                            .background {
                                if !Glass26.on { RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])) }
                            }
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 16), fallback: Color.clear)
                        }
                        ForEach(mine, id: \.self) { url in
                            Button {
                                if let d = MyStickers.data(url) { pick(d) }
                                dismiss()
                            } label: {
                                if let img = MyStickers.data(url).flatMap(UIImage.init(data:)) {
                                    Image(uiImage: img).resizable().scaledToFit().frame(width: 72, height: 72)
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { MyStickers.remove(url); mine = MyStickers.all() } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(.horizontal)
                    if addFailed { Text("Couldn't use that picture.").font(.caption).foregroundStyle(.red).padding(.horizontal) }
                    Text("Emoji").font(.headline).padding([.horizontal, .top])
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
                .padding(.top)
            }
            .onChange(of: newPhoto) { item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), MyStickers.add(d) {
                        mine = MyStickers.all()
                        addFailed = false
                    } else {
                        addFailed = true
                    }
                    newPhoto = nil
                }
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
