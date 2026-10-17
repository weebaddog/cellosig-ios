import LocalAuthentication
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share to cellosig" from Photos, Safari, Files and other apps.
///
/// The extension can't open your keys or messages: it copies what you shared
/// into the App Group inbox with the chat you picked, then tells the app (a
/// Darwin notification), which encrypts and sends it — right away if it's
/// running, otherwise the next time you open it.
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "cellosig", code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor
final class ShareModel: ObservableObject {
    var items: [NSExtensionItem] = []
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    @Published var targets: ShareTargets?
    @Published var unlocked = false
    @Published var busy = false
    @Published var note = ""
    @Published var error: String?
    @Published var done = false

    var available: Bool { AppGroup.container != nil }

    func load() {
        targets = SharedFiles.read(ShareTargets.self, from: SharedFiles.shareTargets)
        unlocked = targets?.locked != true
        if !unlocked { Task { await unlock() } }
    }

    /// App lock is on: same check as opening the app.
    func unlock() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; return }
        unlocked = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Share to cellosig")) == true
    }

    func send(to conv: String) {
        guard !busy, let inbox = SharedFiles.inbox else { return }
        busy = true
        Task {
            let fm = FileManager.default
            let job = inbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: job, withIntermediateDirectories: true,
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let (texts, files, skipped) = await Collector.collect(items, into: job)
                var text = texts.joined(separator: "\n")
                let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !extra.isEmpty { text = text.isEmpty ? extra : extra + "\n" + text }
                guard !text.isEmpty || !files.isEmpty else {
                    try? fm.removeItem(at: job)
                    error = skipped > 0 ? "That's too large to send (90 MB max)." : "There's nothing here cellosig can send."
                    busy = false
                    return
                }
                let manifest = ShareJob(conv: conv, text: text.isEmpty ? nil : text, files: files)
                // The manifest goes last: until it exists the app ignores the folder.
                guard SharedFiles.write(manifest, to: job.appendingPathComponent("manifest.json")) else { throw CocoaError(.fileWriteUnknown) }
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                     CFNotificationName(SharedFiles.inboxNotification as CFString), nil, nil, true)
                done = true
                try? await Task.sleep(nanoseconds: 900_000_000)
                finish()
            } catch {
                try? fm.removeItem(at: job)
                self.error = "Couldn't hand this to cellosig."
                busy = false
            }
        }
    }
}

/// Copies the shared things into the job folder: photos, videos and files as
/// files; links and text as text.
enum Collector {
    static func collect(_ items: [NSExtensionItem], into dir: URL) async -> (texts: [String], files: [ShareJob.File], skipped: Int) {
        var texts: [String] = [], files: [ShareJob.File] = [], skipped = 0
        for item in items {
            for p in item.attachments ?? [] {
                if files.count >= ShareLimits.maxFiles { skipped += 1; continue }
                if let type = fileType(p) {
                    switch await copyFile(p, type: type, into: dir, index: files.count) {
                    case .some(.some(let f)): files.append(f)
                    case .some(.none): skipped += 1
                    case .none: break
                    }
                } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    texts.append(url.absoluteString)
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(s)
                }
            }
        }
        return (texts, files, skipped)
    }

    /// The first file-like type on offer (pictures, videos, documents), not links or text.
    private static func fileType(_ p: NSItemProvider) -> UTType? {
        let offered = p.registeredTypeIdentifiers.compactMap(UTType.init)
        for wanted in [UTType.image, .movie, .audio, .pdf] {
            if let t = offered.first(where: { $0.conforms(to: wanted) }) { return t }
        }
        if let t = offered.first(where: { $0.conforms(to: .fileURL) }) { return t }
        if let t = offered.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }) { return t }
        return nil
    }

    /// nil: couldn't read it; .some(nil): too large; .some(file): copied.
    private static func copyFile(_ p: NSItemProvider, type: UTType, into dir: URL, index: Int) async -> ShareJob.File?? {
        await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { c.resume(returning: nil); return }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                guard size <= ShareLimits.maxFileBytes else { c.resume(returning: .some(nil)); return }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "bin") : url.pathExtension
                let stored = "\(index).\(ext)"
                do {
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(stored))
                } catch { c.resume(returning: nil); return }
                let actual = UTType(filenameExtension: ext) ?? type
                let base = (p.suggestedName ?? url.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "/", with: "_")
                let name = base.isEmpty ? "file.\(ext)" : base.hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
                c.resume(returning: .some(ShareJob.File(name: name, mime: actual.preferredMIMEType ?? "application/octet-stream", path: stored)))
            }
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if !model.available {
                    explain("Sharing isn't available in this install",
                            "This copy of cellosig was installed without an App Group, so the share sheet can't reach the app.")
                } else if model.done {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                        Text("Sending from cellosig").font(.headline)
                        Text("If cellosig isn't running, it goes out the next time you open it.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else if model.targets == nil || model.targets?.targets.isEmpty == true {
                    explain("No chats yet", "Open cellosig and start a chat first.")
                } else if !model.unlocked {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                        Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    picker
                }
            }
            .navigationTitle("Send with cellosig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() }.disabled(model.busy && !model.done) }
            }
            .alert("cellosig", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
        .onAppear { model.load() }
    }

    private var picker: some View {
        let all = model.targets?.targets ?? []
        let shown = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return List {
            Section {
                TextField("Add a message (optional)", text: $model.note, axis: .vertical).lineLimit(1...4)
            }
            Section("Send to") {
                ForEach(shown) { t in
                    Button { model.send(to: t.id) } label: {
                        HStack {
                            Image(systemName: t.group ? "person.3.fill" : "person.fill").foregroundStyle(.secondary).frame(width: 28)
                            Text(t.title).foregroundStyle(.primary)
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                    .disabled(model.busy)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
    }

    private func explain(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
