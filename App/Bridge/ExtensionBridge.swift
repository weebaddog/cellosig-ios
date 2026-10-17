import CellosigCore
import Combine
import Foundation
import WidgetKit

/// The app's side of the widget and the share extension: keeps the small
/// files they read up to date, and sends what was shared from other apps.
@MainActor
final class ExtensionBridge {
    static let shared = ExtensionBridge()

    private weak var messenger: Messenger?
    private var watch: AnyCancellable?
    private var observing = false
    private var processing = false

    func attach(_ m: Messenger) {
        messenger = m
        // Chats change often; the files are rewritten at most every 1.5 s.
        watch = m.$revision
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeSnapshots() }
        observeInbox()
        // Not right now: this runs while AppModel.shared is still being created, and the snapshot reads it.
        Task { @MainActor in
            self.writeSnapshots()
            self.processInbox()
        }
    }

    func detach() {
        watch = nil
        messenger = nil
        // Signed out: the widget and share sheet must not keep showing chats.
        SharedFiles.write(WidgetData(unread: 0, chats: [], showContent: false), to: SharedFiles.widget)
        SharedFiles.write(ShareTargets(targets: [], locked: true), to: SharedFiles.shareTargets)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Snapshots

    func writeSnapshots() {
        guard let m = messenger, AppGroup.container != nil else { return }
        let convs = m.conversations()
        let locked = AppModel.shared.lockEnabled
        let showContent = Shared.defaults.bool(forKey: "notify_preview") && !locked
        let unread = convs.reduce(0) { $0 + $1.unread }
        let chats = showContent ? convs.prefix(6).map { c in
            WidgetData.Chat(id: c.id, title: m.title(c.id),
                            text: c.timerSec > 0 ? "⏱ Disappearing messages" : c.lastText,
                            ts: c.lastTs, unread: c.unread)
        } : []
        if SharedFiles.write(WidgetData(unread: unread, chats: Array(chats), showContent: showContent), to: SharedFiles.widget) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        let targets = convs.prefix(200).map { ShareTargets.Target(id: $0.id, title: m.title($0.id), group: $0.isGroup) }
        SharedFiles.write(ShareTargets(targets: Array(targets), locked: locked), to: SharedFiles.shareTargets)
    }

    // MARK: - Share inbox

    /// The share extension posts a Darwin notification when it queued something;
    /// if we're running (e.g. kept alive in the background) we send it at once.
    private func observeInbox() {
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in Task { @MainActor in ExtensionBridge.shared.processInbox() } },
            SharedFiles.inboxNotification as CFString, nil, .deliverImmediately)
    }

    func processInbox() {
        guard !processing, let m = messenger, let inbox = SharedFiles.inbox else { return }
        let fm = FileManager.default
        let jobs = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !jobs.isEmpty else { return }
        processing = true
        Task {
            for dir in jobs {
                let manifest = dir.appendingPathComponent("manifest.json")
                guard let job = SharedFiles.read(ShareJob.self, from: manifest) else {
                    // Half-written (the extension was killed): drop it once it's clearly abandoned.
                    let made = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    if made < Date().addingTimeInterval(-3600) { try? fm.removeItem(at: dir) }
                    continue
                }
                // Read everything, then remove the job before sending, so it can never go out twice.
                let files: [(ShareJob.File, Data)] = job.files.prefix(ShareLimits.maxFiles).compactMap { f in
                    let url = dir.appendingPathComponent((f.path as NSString).lastPathComponent)
                    return (try? Data(contentsOf: url)).map { (f, $0) }
                }
                try? fm.removeItem(at: dir)
                await send(job, files, m)
            }
            processing = false
            // More may have arrived meanwhile.
            let more = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            if !more.isEmpty { processInbox() }
        }
    }

    private func send(_ job: ShareJob, _ files: [(ShareJob.File, Data)], _ m: Messenger) async {
        guard let c = m.conversation(job.conv), !c.request else { return }
        if m.trustBroken(job.conv) {
            m.noteSystem(job.conv, "Something you shared wasn't sent because this contact's safety number changed. Compare safety numbers (shield icon), then share it again.")
            return
        }
        let text = job.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // One file with a few words: the words become its caption.
        let caption = files.count == 1 && !text.isEmpty ? text : ""
        if caption.isEmpty && !text.isEmpty { await m.sendText(job.conv, text) }
        for (f, data) in files where Int64(data.count) <= ShareLimits.maxFileBytes {
            try? await m.sendFile(job.conv, data: data, name: f.name, mime: f.mime, caption: caption)
        }
    }
}
