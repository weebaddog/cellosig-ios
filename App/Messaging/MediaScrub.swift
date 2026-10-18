import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Removes hidden information from photos and videos before they're sent:
/// where it was taken (GPS), when, the camera / phone model, editing software,
/// and any other tags. Only what's needed to show it right stays
/// (orientation; frame timing for animations).
enum MediaScrub {
    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't remove the hidden information (location, date, camera) from this file, so it wasn't sent." }
    }

    /// The cleaned file, or the file unchanged if it isn't a photo or video.
    static func clean(_ data: Data, mime: String) async throws -> Data {
        if mime.hasPrefix("image/") { return try image(data) }
        if mime.hasPrefix("video/") { return try await video(data, mime: mime) }
        return data
    }

    // MARK: - Photos

    /// Every frame is drawn into a new file of the same type; none of the old tags are copied.
    static func image(_ data: Data) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) > 0 else { throw Failure.unreadable }
        let count = CGImageSourceGetCount(src)
        let out = NSMutableData()
        // Some types can be read but not written (e.g. RAW): those become JPEG.
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type as String)
        let outType = writable ? type : UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, outType, writable ? count : 1, nil) else { throw Failure.unreadable }
        if let global = keptContainerProperties(src) { CGImageDestinationSetProperties(dest, global as CFDictionary) }
        for i in 0..<(writable ? count : 1) {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw Failure.unreadable }
            CGImageDestinationAddImage(dest, frame, keptFrameProperties(src, i) as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable }
        return out as Data
    }

    /// Orientation (or the photo shows sideways), quality, and animation timing — nothing else.
    private static func keptFrameProperties(_ src: CGImageSource, _ i: Int) -> [CFString: Any] {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        var kept: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let o = p[kCGImagePropertyOrientation] { kept[kCGImagePropertyOrientation] = o }
        if let g = p[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            kept[kCGImagePropertyGIFDictionary] = g.filter { [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime].contains($0.key) }
        }
        if let png = p[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            let timing = png.filter { [kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime].contains($0.key) }
            if !timing.isEmpty { kept[kCGImagePropertyPNGDictionary] = timing }
        }
        return kept
    }

    /// An animation's loop count.
    private static func keptContainerProperties(_ src: CGImageSource) -> [CFString: Any]? {
        let p = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] ?? [:]
        if let g = p[kCGImagePropertyGIFDictionary] as? [CFString: Any], let loops = g[kCGImagePropertyGIFLoopCount] {
            return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]]
        }
        if let png = p[kCGImagePropertyPNGDictionary] as? [CFString: Any], let loops = png[kCGImagePropertyAPNGLoopCount] {
            return [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loops]]
        }
        return nil
    }

    // MARK: - Videos

    /// Re-wrapped without re-encoding (same quality, fast): the old file's tags
    /// (location, dates, device, software) are left behind.
    static func video(_ data: Data, mime: String) async throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scrub-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let isMov = mime == "video/quicktime"
        let input = dir.appendingPathComponent(isMov ? "in.mov" : "in.mp4")
        let output = dir.appendingPathComponent(isMov ? "out.mov" : "out.mp4")
        try data.write(to: input, options: [.completeFileProtection])

        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Failure.unreadable }
        session.outputURL = output
        session.outputFileType = isMov ? .mov : .mp4
        session.metadata = []                            // none of the file's tags
        session.metadataItemFilter = .forSharing()       // and no location / personal tags from its tracks
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        guard session.status == .completed, let cleaned = try? Data(contentsOf: output) else { throw Failure.unreadable }
        return cleaned
    }
}
