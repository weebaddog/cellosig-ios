import CellosigCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let conv: String
    @State private var draft = ""
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showPoll = false
    @State private var showSafety = false
    @State private var error: String?
    @State private var share: URL?
    @FocusState private var focused: Bool

    private var isGroup: Bool { Messenger.isGroup(conv) }

    var body: some View {
        let _ = m.revision
        let msgs = m.messages(conv)
        let c = m.conversation(conv)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(msgs) { msg in
                            MessageRow(msg: msg, conv: conv, share: $share).id(msg.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo(msgs.last?.id, anchor: .bottom) }
                .onChange(of: msgs.count) { _ in withAnimation { proxy.scrollTo(msgs.last?.id, anchor: .bottom) } }
            }
            if c?.request == true {
                RequestBar(conv: conv) { dismiss() }
            } else {
                inputBar
            }
        }
        .navigationTitle(m.title(conv))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(m.title(conv)).font(.headline).lineLimit(1)
                    if !isGroup && m.hasProfileName(conv) { Text(PhoneNumbers.pretty(conv)).font(.caption2).foregroundStyle(.secondary) }
                    else if isGroup { Text("\(m.recipients(conv).count + 1) members").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isGroup {
                    Button { showSafety = true } label: {
                        Image(systemName: m.trustBroken(conv) ? "exclamationmark.shield.fill" : m.isVerified(conv) ? "checkmark.shield.fill" : "shield")
                            .foregroundStyle(m.trustBroken(conv) ? Color.red : m.isVerified(conv) ? Color.green : Color.accentColor)
                    }
                }
                Menu {
                    Menu("Disappearing messages") {
                        ForEach(Messenger.timerChoices, id: \.self) { s in
                            Button { Task { await m.setTimer(conv, seconds: s) } } label: {
                                if (c?.timerSec ?? 0) == s { Label(Messenger.timerLabel(s).capitalized, systemImage: "checkmark") }
                                else { Text(Messenger.timerLabel(s).capitalized) }
                            }
                        }
                    }
                    if !isGroup {
                        Button(role: .destructive) { m.block(conv); dismiss() } label: { Label("Block", systemImage: "hand.raised") }
                    }
                    Button(role: .destructive) { m.deleteConversation(conv); dismiss() } label: { Label("Delete chat", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showSafety) { SafetyNumberView(peer: conv) }
        .sheet(isPresented: $showPoll) { PollComposer(conv: conv) }
        .sheet(item: $share) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file."; return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            send(data: data, name: url.lastPathComponent, mime: mime)
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { error = "Couldn't load that photo."; return }
                let type = item.supportedContentTypes.first
                let mime = type?.preferredMIMEType ?? "image/jpeg"
                let ext = type?.preferredFilenameExtension ?? "jpg"
                send(data: data, name: "photo.\(ext)", mime: mime)
            }
        }
        .alert("cellosig", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onAppear { m.activeChat = conv; Task { await m.markRead(conv) } }
        .onDisappear { if m.activeChat == conv { m.activeChat = nil } }
        .onChange(of: msgs.count) { _ in Task { await m.markRead(conv) } }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) { Label("Photo or video", systemImage: "photo") }
                Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                Button { showPoll = true } label: { Label("Poll", systemImage: "chart.bar") }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .autocorrectionDisabled()          // nothing typed here feeds the keyboard's learning
                .textInputAutocapitalization(.sentences)
                .keyboardType(.default)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                .onSubmit(sendText)
            Button(action: sendText) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
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

    private func send(data: Data, name: String, mime: String) {
        guard guardTrust() else { return }
        Task {
            do { try await m.sendFile(conv, data: data, name: name, mime: mime) }
            catch { self.error = "That file is too large (90 MB max)." }
        }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct MessageRow: View {
    @EnvironmentObject var m: Messenger
    let msg: Message
    let conv: String
    @Binding var share: URL?

    var body: some View {
        if msg.isSystem {
            Text(msg.body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(8).frame(maxWidth: .infinity)
        } else {
            HStack {
                if msg.outgoing { Spacer(minLength: 50) }
                VStack(alignment: msg.outgoing ? .trailing : .leading, spacing: 2) {
                    if Messenger.isGroup(conv), !msg.outgoing, let s = msg.sender {
                        Text(m.displayName(s)).font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    bubble
                        .contextMenu { menu }
                    let reactions = m.reactions(msg.msgId)
                    if !reactions.isEmpty {
                        Text(reactions.map(\.emoji).joined()).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                    }
                    footer
                }
                if !msg.outgoing { Spacer(minLength: 50) }
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let poll = msg.poll {
                PollView(msg: msg, poll: poll, conv: conv)
            } else if msg.fileMime != nil {
                attachment
                if !msg.body.isEmpty { Text(msg.body) }
            } else {
                Text(msg.body).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(msg.outgoing ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 16).fill(msg.outgoing ? Color.blue : Color(.secondarySystemBackground)))
    }

    @ViewBuilder private var attachment: some View {
        switch msg.fileState {
        case "ready":
            if msg.isImage, let d = m.attachmentData(msg), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { share = m.exportAttachment(msg) }
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
        if m.reactions(msg.msgId).contains(where: { $0.member == m.me }) {
            Button("Remove reaction") { Task { await m.react(conv, msgId: msg.msgId, emoji: nil) } }
        }
        if !msg.body.isEmpty {
            Button { SecurePasteboard.copy(msg.body) } label: { Label("Copy", systemImage: "doc.on.doc") }
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
                if !Messenger.isGroup(conv) { Button("Block", role: .destructive) { m.block(conv); close() } }
                Button("Delete", role: .destructive) { m.deleteConversation(conv); close() }
                Spacer()
                Button("Accept") { Task { await m.acceptRequest(conv) } }.buttonStyle(.borderedProminent)
            }
        }
        .padding().background(.bar)
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
