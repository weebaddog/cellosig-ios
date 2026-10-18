import CellosigCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let conv: String
    /// Open scrolled to this message (from search), briefly highlighted.
    var focus: Int64? = nil
    @State private var highlight: Int64?
    /// How many of the latest messages are loaded ("Show earlier messages" adds more).
    @State private var limit = 300
    /// The newest message is on screen: new ones scroll into view (otherwise you're reading back; stay put).
    @State private var atBottom = true
    @State private var editing: Message?
    @State private var editText = ""
    @State private var unsending: Message?
    @State private var confirmDelete = false
    @State private var editingPhoto: EditablePhoto?
    @State private var showPhotos = false
    @State private var draft = ""
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showPoll = false
    @State private var showSafety = false
    @State private var showStickers = false
    @State private var remind: Message?
    @State private var error: String?
    @State private var share: URL?
    @StateObject private var recorder = VoiceRecorder()
    @ObservedObject private var calls = CallManager.shared
    @FocusState private var focused: Bool

    private var isGroup: Bool { Messenger.isGroup(conv) }

    // (Split into pieces: as one expression it was too big for the compiler to type-check.)
    var body: some View {
        let _ = m.revision
        let msgs = m.messages(conv, limit: limit)
        let c = m.conversation(conv)
        let screen = messageList(msgs, c)
            .navigationTitle(m.title(conv))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems(c) }
        return withLifecycle(withDialogs(withSheets(screen)), msgs)
    }

    /// The messages, with the input bar floating over their bottom edge
    /// (Liquid Glass on iOS 26: the chat scrolls on behind it).
    private func messageList(_ msgs: [Message], _ c: Conversation?) -> some View {
        let total = m.messageCount(conv)
        return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if total > msgs.count {
                            Button("Show earlier messages") { limit += 300 }
                                .font(.footnote).glassButton().padding(.bottom, 4)
                        }
                        let reminders = Dictionary(grouping: m.reminders(conv: conv), by: { $0.msgRow ?? -1 })
                        let reacts = m.reactions(conv: conv)
                        ForEach(msgs) { msg in
                            MessageRow(msg: msg, conv: conv, share: $share, remind: $remind, reminders: reminders[msg.id] ?? [],
                                       reacts: reacts[msg.msgId] ?? [],
                                       highlighted: highlight == msg.id,
                                       edit: { editText = $0.body; editing = $0 }, unsend: { unsending = $0 }).id(msg.id)
                                .onAppear { if msg.id == msgs.last?.id { atBottom = true } }
                                .onDisappear { if msg.id == msgs.last?.id { atBottom = false } }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .background(ChatWallpaper().ignoresSafeArea(edges: .bottom))
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    if let focus {
                        // From search: load far enough back to reach it, then show it.
                        limit = max(limit, m.messagesSince(conv, row: focus) + 20)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            proxy.scrollTo(focus, anchor: .center)
                            highlight = focus
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation { highlight = nil }
                        }
                    } else {
                        proxy.scrollTo(msgs.last?.id, anchor: .bottom)
                    }
                }
                // A new message: follow it if you were at the bottom (or sent it); don't yank you out of history.
                .onChange(of: msgs.last?.id) { _ in
                    guard let last = msgs.last, atBottom || last.outgoing else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if c?.request == true {
                        RequestBar(conv: conv) { dismiss() }
                    } else {
                        inputBar
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(_ c: Conversation?) -> some ToolbarContent {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(m.title(conv)).font(.headline).lineLimit(1)
                    if !isGroup && m.hasProfileName(conv) { Text(PhoneNumbers.pretty(conv)).font(.caption2).foregroundStyle(.secondary) }
                    else if isGroup { Text("\(m.recipients(conv).count + 1) members").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if c?.request != true {
                    // Disappearing messages, right in the header: shows the timer when it's on.
                    Menu {
                        Section("Disappearing messages") {
                            ForEach(Messenger.timerChoices, id: \.self) { s in
                                Button { Task { await m.setTimer(conv, seconds: s) } } label: {
                                    if (c?.timerSec ?? 0) == s { Label(Messenger.timerLabel(s).capitalized, systemImage: "checkmark") }
                                    else { Text(Messenger.timerLabel(s).capitalized) }
                                }
                            }
                        }
                    } label: {
                        let t = c?.timerSec ?? 0
                        if t > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "timer")
                                Text(Messenger.timerShort(t)).font(.caption.bold()).monospacedDigit()
                            }
                        } else {
                            Image(systemName: "timer").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Disappearing messages: \(Messenger.timerLabel(c?.timerSec ?? 0))")
                }
                if !isGroup && c?.request != true {
                    Button {
                        guard guardTrust() else { return }
                        calls.callSmart(conv)
                    } label: { Image(systemName: "phone") }
                    .disabled(calls.inCall || !m.connected)
                }
                if !isGroup {
                    Button { showSafety = true } label: {
                        Image(systemName: m.trustBroken(conv) ? "exclamationmark.shield.fill" : m.isVerified(conv) ? "checkmark.shield.fill" : "shield")
                            .foregroundStyle(m.trustBroken(conv) ? Color.red : m.isVerified(conv) ? Color.green : Color.accentColor)
                    }
                }
                Menu {
                    if !isGroup {
                        Button(role: .destructive) { m.block(conv); dismiss() } label: { Label("Block", systemImage: "hand.raised") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete chat", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
    }

    private func withSheets(_ v: some View) -> some View {
        v
        .sheet(isPresented: $showSafety) { SafetyNumberView(peer: conv) }
        .sheet(isPresented: $showPoll) { PollComposer(conv: conv) }
        .sheet(isPresented: $showStickers) {
            StickerPicker { png in send(data: png, name: "sticker.png", mime: "image/png", kind: "sticker") }
        }
        .sheet(item: $remind) { msg in ReminderSheet(msg: msg).presentationDetents([.medium]) }
        .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .any(of: [.images, .videos]))
        .fullScreenCover(item: $editingPhoto) { p in
            PhotoEditor(image: p.image) { data, mime, name, caption, sticker in
                send(data: data, name: name, mime: mime, kind: sticker ? "sticker" : nil, caption: caption)
            }
        }
        .sheet(item: $share) { url in ShareSheet(items: [url]) }
        // The decrypted copy made for sharing goes as soon as the share sheet closes
        // (the app now keeps running for days, so "on next launch" was too late).
        .onChange(of: share) { old, new in
            if new == nil, let old { try? FileManager.default.removeItem(at: old) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Check the size before reading: a huge file read into memory would crash the app.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) > Messenger.maxFileBytes {
                error = "That file is too large (90 MB max)."; return
            }
            guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file."; return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            send(data: data, name: url.lastPathComponent, mime: mime)
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                // As a file first, so a long video's size is checked before it's loaded into memory.
                guard let picked = try? await item.loadTransferable(type: PickedFile.self) else { error = "Couldn't load that photo."; return }
                defer { try? FileManager.default.removeItem(at: picked.url) }
                let size = (try? picked.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                guard size <= Messenger.maxFileBytes else { error = "That video is too large (90 MB max)."; return }
                guard let data = try? Data(contentsOf: picked.url) else { error = "Couldn't load that photo."; return }
                let type = item.supportedContentTypes.first
                // Photos open in the editor (which also strips their hidden location data);
                // videos and animated GIFs go as they are.
                if let type, type.conforms(to: .image), !type.conforms(to: .gif),
                   let img = ImageDecode.still(data, maxPixels: 3000) {
                    editingPhoto = EditablePhoto(image: img)
                    return
                }
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                let ext = type?.preferredFilenameExtension ?? "jpg"
                send(data: data, name: "photo.\(ext)", mime: mime)
            }
        }
    }

    private func withDialogs(_ v: some View) -> some View {
        v
        .alert("cellosig", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .alert("Edit message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Message", text: $editText, axis: .vertical).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let msg = editing, guardTrust() { Task { await m.editMessage(msg, editText) } }
                editing = nil
            }
        } message: { Text("Everyone in this chat sees the new text, marked “edited”.") }
        .confirmationDialog("Delete for everyone?", isPresented: Binding(get: { unsending != nil }, set: { if !$0 { unsending = nil } }),
                            titleVisibility: .visible) {
            Button("Delete for everyone", role: .destructive) {
                if let msg = unsending { Task { await m.unsend(msg) } }
                unsending = nil
            }
        } message: { Text("The message is removed from everyone's phone in this chat. They see that a message was deleted.") }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete chat", role: .destructive) { m.deleteConversation(conv); dismiss() }
        } message: { Text("All of its messages and files are erased from this iPhone. It can't be undone.") }
    }

    private func withLifecycle(_ v: some View, _ msgs: [Message]) -> some View {
        v
        .onAppear { m.activeChat = conv; Task { await m.markRead(conv) } }
        .onDisappear {
            if m.activeChat == conv { m.activeChat = nil }
            if recorder.recording { recorder.cancel() }   // don't keep the microphone on after leaving
        }
        .onChange(of: msgs.last?.id) { _ in Task { await m.markRead(conv) } }
    }

    @ViewBuilder private var inputBar: some View {
        if recorder.recording {
            HStack(spacing: 12) {
                Button(role: .destructive) { recorder.cancel() } label: { Image(systemName: "trash").font(.title2) }
                Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Recording " + CallManager.formatDuration(Int(Date().timeIntervalSince(recorder.started ?? Date()))))
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    if let data = recorder.finish() { send(data: data, name: "Voice note.m4a", mime: "audio/mp4", kind: "voice") }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .liquidGlass(in: Capsule(), fallback: .bar)
            .padding(.horizontal, Glass26.on ? 10 : 0).padding(.bottom, Glass26.on ? 6 : 0)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    // (A PhotosPicker inside a Menu doesn't open on newer iOS: the menu closes
                    // first. A plain button opens it through .photosPicker instead.)
                    Button { showPhotos = true } label: { Label("Photo or video", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                    Button { showStickers = true } label: { Label("Sticker", systemImage: "face.smiling") }
                    Button { showPoll = true } label: { Label("Poll", systemImage: "chart.bar") }
                } label: {
                    if Glass26.on {
                        Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 40, height: 40).liquidGlass(in: Circle())
                    } else {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .autocorrectionDisabled()          // nothing typed here feeds the keyboard's learning
                    .textInputAutocapitalization(.sentences)
                    .keyboardType(.default)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 20), fallback: Color(.secondarySystemBackground))
                    .onSubmit(sendText)
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        guard guardTrust() else { return }
                        Task { if !(await recorder.start()) { error = "Can't record. Allow the microphone in Settings → cellosig (and not during a call)." } }
                    } label: {
                        if Glass26.on {
                            Image(systemName: "mic").font(.title3.weight(.semibold)).frame(width: 40, height: 40).liquidGlass(in: Circle())
                        } else {
                            Image(systemName: "mic.circle.fill").font(.title)
                        }
                    }
                } else {
                    Button(action: sendText) {
                        if Glass26.on {
                            Image(systemName: "arrow.up").font(.title3.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40).liquidGlass(in: Circle(), tint: .accentColor)
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            // iOS 26: the controls float as glass over the chat; before that, the usual bar.
            .background(Glass26.on ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
        }
    }

    private func guardTrust() -> Bool {
        if m.trustBroken(conv) { showSafety = true; return false }
        return true
    }

    private func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, guardTrust() else { return }
        draft = ""
        Task { await m.sendText(conv, text) }
    }

    private func send(data: Data, name: String, mime: String, kind: String? = nil, caption: String = "") {
        guard guardTrust() else { return }
        Task {
            do { try await m.sendFile(conv, data: data, name: name, mime: mime, caption: caption, kind: kind) }
            catch ChunkedAead.Failure.tooLarge { self.error = "That file is too large (90 MB max)." }
            catch { self.error = "Couldn't prepare that file to send (is the iPhone's storage full?)." }
        }
    }
}

/// "Remind me about this message": the time found in it (if any), or one you pick.
struct ReminderSheet: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let msg: Message
    @State private var at = Date().addingTimeInterval(3600)
    @State private var failed = false

    var body: some View {
        let suggestion = TimeParser.find(msg.body)
        NavigationStack {
            Form {
                if !msg.body.isEmpty {
                    Section { Text(msg.body).lineLimit(3).foregroundStyle(.secondary) }
                }
                if let s = suggestion {
                    Section("Found in the message") {
                        Button { add(s.at) } label: { Label(s.label, systemImage: "alarm") }
                    }
                }
                Section("Pick a time") {
                    DatePicker("Remind me", selection: $at, in: Date().addingTimeInterval(60)...)
                    Button("Set reminder") { add(at) }
                }
                if failed {
                    Text("cellosig isn't allowed to show notifications. Turn them on in Settings → cellosig → Notifications.").foregroundStyle(.red)
                }
            }
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if let s = suggestion { at = s.at } }
        }
    }

    private func add(_ date: Date) {
        Task {
            if await m.addReminder(for: msg, at: date) { dismiss() } else { failed = true }
        }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

/// A picked photo on its way into the editor.
struct EditablePhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A photo or video from the picker, copied to a protected temporary file
/// (deleted after sending, and on next launch).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            try? (dest as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
            return PickedFile(url: dest)
        }
    }
}

struct MessageRow: View {
    @EnvironmentObject var m: Messenger
    let msg: Message
    let conv: String
    @Binding var share: URL?
    @Binding var remind: Message?
    let reminders: [Reminder]
    /// This message's reactions (looked up for the whole chat at once).
    var reacts: [(member: String, emoji: String)] = []
    var highlighted = false
    var edit: (Message) -> Void = { _ in }
    var unsend: (Message) -> Void = { _ in }
    /// Lockdown mode: this picture was tapped to show it.
    @State private var revealed = false

    private var isSticker: Bool { msg.fileKind == "sticker" && msg.fileState == "ready" && (!Lockdown.on || revealed) }

    /// A verification code someone sent you ("your code is 482913"): one tap to copy (as on Android).
    private var otp: String? {
        guard !msg.outgoing, !msg.deleted, msg.poll == nil,
              let r = msg.body.range(of: #"(?i)\b(?:code|otp|pin|passcode)\b\D{0,30}?(\d{4,8})\b"#, options: .regularExpression)
        else { return nil }
        return String(msg.body[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).last { (4...8).contains($0.count) }
    }

    var body: some View {
        if msg.isSystem {
            Text(msg.body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 12), fallback: .thinMaterial)
                .padding(4).frame(maxWidth: .infinity)
        } else {
            HStack {
                if msg.outgoing { Spacer(minLength: 50) }
                VStack(alignment: msg.outgoing ? .trailing : .leading, spacing: 2) {
                    if Messenger.isGroup(conv), !msg.outgoing, let s = msg.sender {
                        Text(m.displayName(s)).font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    bubble
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.yellow, lineWidth: highlighted ? 3 : 0))
                        .contextMenu { if !msg.deleted { menu } }
                    ForEach(reminders) { r in
                        Button { m.cancelReminder(r.id) } label: {
                            Label(TimeParser.label(r.at), systemImage: "alarm").font(.caption2)
                        }
                        .glassButton().controlSize(.mini)
                        .accessibilityHint("Cancels this reminder")
                    }
                    if !reacts.isEmpty {
                        Text(reacts.map(\.emoji).joined()).font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .liquidGlass(in: Capsule(), fallback: Color(.secondarySystemBackground))
                    }
                    footer
                }
                if !msg.outgoing { Spacer(minLength: 50) }
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        if isSticker {
            // Stickers have no bubble.
            attachment
        } else {
            bubbleBox
        }
    }

    private var bubbleBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if msg.deleted {
                Label(msg.outgoing ? "You deleted this message" : "This message was deleted", systemImage: "nosign")
                    .italic().opacity(0.8)
            } else if let poll = msg.poll {
                PollView(msg: msg, poll: poll, conv: conv)
            } else if msg.fileMime != nil {
                attachment
                if !msg.body.isEmpty { Text(msg.body) }
            } else {
                Text(msg.body).textSelection(.enabled)
            }
            if !msg.deleted, msg.poll == nil, let video = YouTubeLinks.find(msg.body) {
                YouTubeCard(videoId: video, tint: msg.outgoing ? .white : .primary)
            }
            if let code = otp {
                Button { SecurePasteboard.copy(code) } label: { Label("Copy code \(code)", systemImage: "doc.on.doc") }
                    .glassButton().controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(msg.outgoing ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 16).fill(msg.outgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground))))
    }

    @ViewBuilder private var attachment: some View {
        switch msg.fileState {
        case "ready":
            if msg.fileKind == "voice" || msg.fileMime?.hasPrefix("audio/") == true {
                VoiceNoteView(msg: msg)
            } else if msg.isImage && Lockdown.on && !revealed {
                // Lockdown mode: not even decoded until you ask.
                Button { revealed = true } label: {
                    Label(msg.fileKind == "sticker" ? "Show sticker" : "Show picture", systemImage: "eye.slash")
                }
                .foregroundStyle(msg.outgoing ? Color.white : Color.accentColor)
            } else if msg.isImage {
                MessageImage(msg: msg, sticker: isSticker) { share = m.exportAttachment(msg) }
            } else {
                Button { share = m.exportAttachment(msg) } label: {
                    Label("\(msg.fileName ?? "File") · \(ByteCountFormatter.string(fromByteCount: msg.fileSize ?? 0, countStyle: .file))", systemImage: "doc")
                }.foregroundStyle(msg.outgoing ? Color.white : Color.accentColor)
            }
        case "downloading":
            HStack { ProgressView(); Text("Downloading…").font(.caption) }
        case "failed":
            Button("Download failed — tap to retry") { Task { await m.downloadAttachment(msg.id) } }
        default:
            Button { Task { await m.downloadAttachment(msg.id) } } label: {
                Label("Download \(msg.fileName ?? "file") (\(ByteCountFormatter.string(fromByteCount: msg.fileSize ?? 0, countStyle: .file)))", systemImage: "arrow.down.circle")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if msg.expiresInSec > 0 { Image(systemName: "timer") }
            if msg.editedAt != nil && !msg.deleted { Text("edited ·") }
            Text(Date(timeIntervalSince1970: Double(msg.ts) / 1000).formatted(date: .omitted, time: .shortened))
            if msg.outgoing {
                switch msg.status {
                case "sending": Image(systemName: "clock")
                case "sent": Image(systemName: "checkmark")
                case "delivered": Image(systemName: "checkmark.circle")
                case "read": Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                case "unregistered": Text("Not on cellosig").foregroundStyle(.red)
                default: Button("Not sent — retry") { Task { await m.retry(msg) } }.foregroundStyle(.red)
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private var menu: some View {
        ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏"], id: \.self) { e in
            Button(e) { Task { await m.react(conv, msgId: msg.msgId, emoji: e) } }
        }
        if reacts.contains(where: { $0.member == m.me }) {
            Button("Remove reaction") { Task { await m.react(conv, msgId: msg.msgId, emoji: nil) } }
        }
        if !msg.body.isEmpty {
            Button { SecurePasteboard.copy(msg.body) } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        Button { remind = msg } label: {
            Label(TimeParser.find(msg.body).map { "Remind me \($0.label)" } ?? "Remind me…", systemImage: "alarm")
        }
        if m.canEdit(msg) {
            Button { edit(msg) } label: { Label("Edit", systemImage: "pencil") }
        }
        if m.canUnsend(msg) {
            Button(role: .destructive) { unsend(msg) } label: { Label("Delete for everyone", systemImage: "trash") }
        }
    }
}

struct RequestBar: View {
    @EnvironmentObject var m: Messenger
    let conv: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("\(m.title(conv)) isn't in your chats. Accept to reply and let them know you've seen their messages.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                if !Messenger.isGroup(conv) { Button("Block", role: .destructive) { m.block(conv); close() }.glassButton() }
                Button("Delete", role: .destructive) { m.deleteConversation(conv); close() }.glassButton()
                Spacer()
                Button("Accept") { Task { await m.acceptRequest(conv) } }.glassButton(prominent: true)
            }
        }
        .padding()
        .liquidGlass(in: RoundedRectangle(cornerRadius: Glass26.on ? 24 : 0), fallback: .bar)
        .padding(Glass26.on ? 10 : 0)
    }
}

struct PollView: View {
    @EnvironmentObject var m: Messenger
    let msg: Message
    let poll: PollDto
    let conv: String

    var body: some View {
        let votes = m.votes(msg.msgId)
        let mine = votes[m.me] ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("📊 \(msg.body)").bold()
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                let count = votes.values.filter { $0.contains(i) }.count
                Button {
                    var next = poll.multi ? mine : []
                    if mine.contains(i) { next.removeAll { $0 == i } } else { next.append(i) }
                    Task { await m.vote(conv, pollMsgId: msg.msgId, choices: next) }
                } label: {
                    HStack {
                        Image(systemName: mine.contains(i) ? (poll.multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (poll.multi ? "square" : "circle"))
                        Text(option)
                        Spacer()
                        Text("\(count)").monospacedDigit()
                    }
                }.buttonStyle(.plain)
            }
            if poll.multi { Text("Pick any").font(.caption2).opacity(0.7) }
        }
        .frame(minWidth: 200)
    }
}

struct PollComposer: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let conv: String
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multi = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") { TextField("Ask something", text: $question) }
                Section("Options") {
                    ForEach(options.indices, id: \.self) { i in TextField("Option \(i + 1)", text: $options[i]) }
                    if options.count < 10 { Button("Add option") { options.append("") } }
                }
                Toggle("Allow several answers", isOn: $multi)
            }
            .navigationTitle("Poll")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await m.sendPoll(conv, question: question, options: options, multi: multi) }
                        dismiss()
                    }.disabled(question.isEmpty || options.filter { !$0.isEmpty }.count < 2)
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Copies stay on this device (no Universal Clipboard) and expire after 60 s.
enum SecurePasteboard {
    static func copy(_ s: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: s]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
    }
}
