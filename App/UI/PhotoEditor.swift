import CoreImage
import CoreImage.CIFilterBuiltins
import ImagePlayground
import SwiftUI
import Vision

/// Edit a photo before sending it. Everything runs ON THE iPHONE (Apple's
/// Vision and Core Image; Image Playground is on-device too): nothing is
/// uploaded to be edited.
///
/// Every photo also leaves here re-encoded, so its hidden metadata — above
/// all the GPS location where it was taken — is never sent.
struct PhotoEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PhotoEditModel
    @State private var caption = ""
    @State private var imagine = false
    /// (data, mime, file name, caption, as a sticker)
    let send: (Data, String, String, String, Bool) -> Void

    init(image: UIImage, send: @escaping (Data, String, String, String, Bool) -> Void) {
        _model = StateObject(wrappedValue: PhotoEditModel(image))
        self.send = send
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    if model.hasTransparency { Checkerboard() }
                    Image(uiImage: model.image).resizable().scaledToFit()
                    if model.busy {
                        ProgressView(model.busyLabel).padding().liquidGlass(in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if let note = model.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }

                tools

                HStack(spacing: 8) {
                    TextField("Add a caption", text: $caption, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 20), fallback: Color(.secondarySystemBackground))
                    if model.hasTransparency {
                        Button { finish(sticker: true) } label: { Label("Sticker", systemImage: "face.smiling") }
                            .glassButton().disabled(model.busy)
                    }
                    Button { finish(sticker: false) } label: { Image(systemName: "arrow.up").font(.headline.bold()) }
                        .glassButton(prominent: true).disabled(model.busy)
                        .accessibilityLabel("Send")
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("Edit photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.canUndo || model.busy)
                        .accessibilityLabel("Undo")
                }
            }
            .modifier(ImaginePresenter(isPresented: $imagine, source: model.image) { model.adopt($0) })
        }
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                tool("Enhance", "wand.and.stars") { model.run("Enhancing…") { try PhotoEditModel.enhance($0) } }
                tool("Remove background", "scissors") { model.run("Finding the subject…", transparent: true) { try PhotoEditModel.removeBackground($0) } }
                tool("Blur background", "camera.aperture") { model.run("Finding the subject…") { try PhotoEditModel.blurBackground($0) } }
                tool("Blur faces", "face.dashed") { model.run("Finding faces…") { try PhotoEditModel.blurFaces($0) } }
                Menu {
                    ForEach(PhotoEditModel.Look.allCases, id: \.self) { look in
                        Button(look.rawValue) { model.run("Applying \(look.rawValue)…") { try PhotoEditModel.apply(look, $0) } }
                    }
                } label: { toolLabel("Filters", "camera.filters") }
                .disabled(model.busy)
                tool("Rotate", "rotate.right") { model.run("Rotating…") { PhotoEditModel.rotate($0) } }
                if ImaginePresenter.available {
                    tool("Imagine", "sparkles") { imagine = true }
                }
            }
            .padding(.horizontal)
        }
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, icon) }.buttonStyle(.plain).disabled(model.busy)
    }

    private func toolLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).frame(width: 48, height: 48)
                .liquidGlass(in: Circle(), fallback: Color(.secondarySystemBackground))
            Text(title).font(.caption2).lineLimit(1)
        }
        .frame(width: 74)
    }

    private func finish(sticker: Bool) {
        guard let out = model.export(sticker: sticker) else { return }
        send(out.data, out.mime, out.name, caption.trimmingCharacters(in: .whitespacesAndNewlines), sticker)
        dismiss()
    }
}

@MainActor
final class PhotoEditModel: ObservableObject {
    @Published private(set) var image: UIImage
    @Published private(set) var busy = false
    @Published private(set) var busyLabel = ""
    @Published private(set) var note: String?
    @Published private(set) var hasTransparency = false
    private var history: [(UIImage, Bool)] = []

    var canUndo: Bool { !history.isEmpty }

    init(_ image: UIImage) { self.image = image }

    /// A tool's work, off the main thread; the result replaces the picture (undoable).
    /// `transparent`: the result is a cut-out (nil: as transparent as before).
    func run(_ label: String, transparent: Bool? = nil, _ work: @escaping @Sendable (CIImage) throws -> CIImage) {
        guard !busy, let input = CIImage(image: image) else { return }
        busy = true
        busyLabel = label
        note = nil
        Task {
            let result: Result<UIImage, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let out = try work(input)
                    guard let cg = Self.context.createCGImage(out, from: out.extent) else { throw EditError.failed }
                    return UIImage(cgImage: cg)
                }
            }.value
            busy = false
            switch result {
            case .success(let img):
                history.append((image, hasTransparency))
                if history.count > 20 { history.removeFirst() }
                image = img
                hasTransparency = transparent ?? hasTransparency
            case .failure(let e):
                note = (e as? EditError)?.message ?? "That didn't work on this photo."
            }
        }
    }

    /// A picture made elsewhere (Image Playground) replaces this one.
    func adopt(_ img: UIImage) {
        history.append((image, hasTransparency))
        image = img
        hasTransparency = false
    }

    func undo() {
        guard let (img, t) = history.popLast() else { return }
        image = img
        hasTransparency = t
        note = nil
    }

    /// Re-encoded without metadata (no location): PNG if it has a cut-out, else JPEG.
    func export(sticker: Bool) -> (data: Data, mime: String, name: String)? {
        if sticker {
            // Stickers: at most 512 px, like the built-in ones.
            let png = ImageDecode.still(image.pngData() ?? Data(), maxPixels: 512)?.pngData()
            return png.map { ($0, "image/png", "sticker.png") }
        }
        if hasTransparency { return image.pngData().map { ($0, "image/png", "photo.png") } }
        return image.jpegData(compressionQuality: 0.9).map { ($0, "image/jpeg", "photo.jpg") }
    }

    // MARK: - The tools (pure functions on CIImage, run off the main thread)

    enum EditError: Error {
        case noSubject, noFaces, failed
        var message: String {
            switch self {
            case .noSubject: return "Couldn't find a clear subject (a person, pet or object) in this photo."
            case .noFaces: return "No faces found in this photo."
            case .failed: return "That didn't work on this photo."
            }
        }
    }

    nonisolated static let context = CIContext()

    nonisolated static func enhance(_ img: CIImage) throws -> CIImage {
        img.autoAdjustmentFilters().reduce(img) { current, f in
            f.setValue(current, forKey: kCIInputImageKey)
            return f.outputImage ?? current
        }
    }

    /// The main subject(s) as a mask (white = subject), the size of the image.
    nonisolated private static func subjectMask(_ img: CIImage) throws -> CIImage {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: img)
        try handler.perform([req])
        guard let result = req.results?.first, !result.allInstances.isEmpty else { throw EditError.noSubject }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    nonisolated static func removeBackground(_ img: CIImage) throws -> CIImage {
        let mask = try subjectMask(img)
        let f = CIFilter.blendWithMask()
        f.inputImage = img
        f.backgroundImage = CIImage.empty()
        f.maskImage = mask
        guard let out = f.outputImage else { throw EditError.failed }
        // Crop to the subject, with a little room around it.
        let box = boundingBox(of: mask) ?? img.extent
        return out.cropped(to: box.insetBy(dx: -box.width * 0.04, dy: -box.height * 0.04).intersection(img.extent))
    }

    nonisolated static func blurBackground(_ img: CIImage) throws -> CIImage {
        let mask = try subjectMask(img)
        let radius = max(img.extent.width, img.extent.height) / 80
        let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: img.extent)
        let f = CIFilter.blendWithMask()
        f.inputImage = img
        f.backgroundImage = blurred
        f.maskImage = mask.applyingGaussianBlur(sigma: 2).cropped(to: img.extent)   // soft edge
        guard let out = f.outputImage else { throw EditError.failed }
        return out
    }

    nonisolated static func blurFaces(_ img: CIImage) throws -> CIImage {
        let req = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(ciImage: img).perform([req])
        let faces = req.results ?? []
        guard !faces.isEmpty else { throw EditError.noFaces }
        let w = img.extent.width, h = img.extent.height
        // Heavy pixelation + blur: not reversible by sharpening.
        let hidden = img.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(w, h) / 40])
            .applyingGaussianBlur(sigma: max(w, h) / 120)
            .cropped(to: img.extent)
        var out = img
        for face in faces {
            let b = face.boundingBox   // normalized, origin bottom-left (as CIImage)
            let r = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
                .insetBy(dx: -b.width * w * 0.25, dy: -b.height * h * 0.3)
            out = hidden.cropped(to: r).composited(over: out)
        }
        return out
    }

    enum Look: String, CaseIterable {
        case vivid = "Vivid", warm = "Warm", cool = "Cool", mono = "Mono", noir = "Noir", fade = "Fade"
        var filter: String {
            switch self {
            case .vivid: return "CIPhotoEffectChrome"
            case .warm: return "CIPhotoEffectInstant"
            case .cool: return "CIPhotoEffectProcess"
            case .mono: return "CIPhotoEffectMono"
            case .noir: return "CIPhotoEffectNoir"
            case .fade: return "CIPhotoEffectFade"
            }
        }
    }

    nonisolated static func apply(_ look: Look, _ img: CIImage) throws -> CIImage {
        img.applyingFilter(look.filter)
    }

    nonisolated static func rotate(_ img: CIImage) -> CIImage {
        let r = img.oriented(.right)
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }

    /// The area where the mask is on (to crop a cut-out to its subject).
    nonisolated private static func boundingBox(of mask: CIImage) -> CGRect? {
        let small = mask.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        guard let cg = context.createCGImage(small, from: small.extent, format: .L8, colorSpace: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let row = cg.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where p[y * row + x] > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // CGImage rows run top-down; CIImage coordinates bottom-up.
        let s = mask.extent.width / CGFloat(width)
        return CGRect(x: CGFloat(minX) * s + mask.extent.minX,
                      y: CGFloat(height - 1 - maxY) * s + mask.extent.minY,
                      width: CGFloat(maxX - minX + 1) * s,
                      height: CGFloat(maxY - minY + 1) * s)
    }
}

/// Grey/white squares behind a cut-out, so you can see what's transparent.
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}

/// "Imagine": Apple Intelligence's Image Playground, on the phone, starting
/// from your photo (iOS 18.1+ on iPhones that have Apple Intelligence).
struct ImaginePresenter: ViewModifier {
    @Binding var isPresented: Bool
    let source: UIImage
    let done: (UIImage) -> Void

    static var available: Bool {
        if #available(iOS 18.1, *) { return ImagePlaygroundViewController.isAvailable }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.1, *) {
            content.imagePlaygroundSheet(isPresented: $isPresented, concepts: [], sourceImage: Image(uiImage: source)) { url in
                if let d = try? Data(contentsOf: url), let img = ImageDecode.still(d, maxPixels: 3000) { done(img) }
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            content
        }
    }
}
