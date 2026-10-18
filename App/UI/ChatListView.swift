import CellosigCore
import SwiftUI

/// A chat to open, optionally at one message (from search).
struct ChatRoute: Hashable {
    var conv: String
    var focus: Int64?
}

struct ChatListView: View {
    @EnvironmentObject var m: Messenger
    @EnvironmentObject var model: AppModel
    @State private var path: [ChatRoute] = []
    @State private var showNew = false
    @State private var showSettings = false
    @State private var query = ""
    @State private var deleting: String?

    var body: some View {
        let _ = m.revision
        let convs = m.conversations()
        let requests = m.conversations(requests: true)
        NavigationStack(path: $path) {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    chatList(convs, requests)
                } else {
                    SearchResults(query: query, convs: convs, path: $path)
                }
            }
            .searchable(text: $query, prompt: "Search chats and messages")
            .navigationTitle("cellosig")
            .navigationDestination(for: ChatRoute.self) { ChatView(conv: $0.conv, focus: $0.focus) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                if !Glass26.on {   // iOS 26: the floating glass button below instead
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if Glass26.on && query.isEmpty {
                    Button { showNew = true } label: {
                        Image(systemName: "square.and.pencil").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .liquidGlass(in: Circle(), tint: .accentColor)
                    }
                    .accessibilityLabel("New chat")
                    .padding(.trailing, 20).padding(.bottom, 12)
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { conv in showNew = false; path = [ChatRoute(conv: conv)] }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete chat", role: .destructive) { if let d = deleting { m.deleteConversation(d) }; deleting = nil }
            } message: { Text("All of its messages and files are erased from this iPhone. It can't be undone.") }
            .onAppear(perform: openTapped)
            .onChange(of: model.openConversation) { _ in openTapped() }
        }
    }

    private func chatList(_ convs: [Conversation], _ requests: [Conversation]) -> some View {
        List {
                if !m.connected {
                    Label("Connecting to relay…", systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                        .glassBanner()
                }
                if KeepAlive.shared.enabled, let paused = KeepAlive.shared.pausedAt, Date().timeIntervalSince(paused) < 6 * 3600 {
                    Label("iOS paused cellosig in the background at \(paused.formatted(date: .omitted, time: .shortened)), so calls and messages waited until you opened it. Don't swipe cellosig away in the app switcher, and turn off Low Power Mode.", systemImage: "moon.zzz")
                        .font(.footnote).foregroundStyle(.orange)
                        .glassBanner()
                }
                if m.authFailed {
                    Label("The relay no longer accepts this sign-in. Sign up again in Settings.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                        .glassBanner()
                }
                if !requests.isEmpty {
                    NavigationLink { RequestsView(path: $path) } label: {
                        Label("Message requests (\(requests.count))", systemImage: "tray")
                    }
                }
                ForEach(convs) { c in
                    NavigationLink(value: ChatRoute(conv: c.id)) { ConversationRow(c: c) }
                        // (Not role: .destructive: that deletes on a full swipe before you can confirm.)
                        .swipeActions(allowsFullSwipe: false) {
                            Button { deleting = c.id } label: { Label("Delete", systemImage: "trash") }.tint(.red)
                            Button { m.setPinned(c.id, c.pinnedAt == nil) } label: {
                                Label(c.pinnedAt == nil ? "Pin" : "Unpin", systemImage: c.pinnedAt == nil ? "pin" : "pin.slash")
                            }.tint(.orange)
                        }
                }
                if convs.isEmpty && requests.isEmpty {
                    Text("No chats yet. Tap ✏️ to message someone.").foregroundStyle(.secondary)
                }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, Glass26.on ? 84 : 0, for: .scrollContent)   // room for the floating button
    }

    /// A notification, widget or share was tapped: show that chat.
    private func openTapped() {
        guard let conv = model.openConversation else { return }
        model.openConversation = nil
        guard m.conversation(conv) != nil else { return }
        showNew = false
        showSettings = false
        query = ""
        path = [ChatRoute(conv: conv)]
    }
}

/// Chats whose name matches, then messages containing the words.
struct SearchResults: View {
    @EnvironmentObject var m: Messenger
    let query: String
    let convs: [Conversation]
    @Binding var path: [ChatRoute]

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let digits = q.filter(\.isNumber)
        let chats = convs.filter { m.title($0.id).localizedCaseInsensitiveContains(q) || (digits.count >= 3 && $0.id.contains(digits)) }
        let hits = m.search(q)
        List {
            if !chats.isEmpty {
                Section("Chats") {
                    ForEach(chats) { c in
                        Button { path.append(ChatRoute(conv: c.id)) } label: { ConversationRow(c: c) }.buttonStyle(.plain)
                    }
                }
            }
            if !hits.isEmpty {
                Section("Messages") {
                    ForEach(hits) { h in
                        Button { path.append(ChatRoute(conv: h.msg.conv, focus: h.msg.id)) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Avatar(conv: h.msg.conv, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(m.title(h.msg.conv)).font(.subheadline.bold()).lineLimit(1)
                                        Spacer()
                                        Text(ConversationRow.when(h.msg.ts)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(Self.highlighted(Self.snippet(h.msg.body, q), q)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if chats.isEmpty && hits.isEmpty {
                Text("Nothing found for “\(q)”.").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    /// The part of a long message around the match.
    static func snippet(_ body: String, _ q: String) -> String {
        guard body.count > 120, let r = body.range(of: q, options: .caseInsensitive) else { return body }
        let start = body.index(r.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        return (start == body.startIndex ? "" : "…") + body[start...].prefix(160)
    }

    static func highlighted(_ text: String, _ q: String) -> AttributedString {
        var a = AttributedString(text)
        var from = a.startIndex
        while let r = a[from...].range(of: q, options: .caseInsensitive) {
            a[r].inlinePresentationIntent = .stronglyEmphasized
            from = r.upperBound
        }
        return a
    }
}

struct ConversationRow: View {
    @EnvironmentObject var m: Messenger
    let c: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Avatar(conv: c.id, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if c.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(m.title(c.id)).font(.headline).lineLimit(1)
                    Spacer()
                    Text(Self.when(c.lastTs)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(c.lastText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if c.timerSec > 0 { Image(systemName: "timer").font(.caption).foregroundStyle(.secondary) }
                    if c.unread > 0 {
                        Text("\(c.unread)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.blue))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func when(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct Avatar: View {
    @EnvironmentObject var m: Messenger
    let conv: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if !Messenger.isGroup(conv), let img = AvatarCache.image(m, conv) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(hue: Double(conv.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360,
                                        saturation: 0.45, brightness: 0.75))
                    if Messenger.isGroup(conv) { Image(systemName: "person.3.fill").foregroundStyle(.white).font(.system(size: size * 0.35)) }
                    else { Text(initials).foregroundStyle(.white).font(.system(size: size * 0.4, weight: .semibold)) }
                }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }

    private var initials: String {
        let name = m.title(conv)
        guard m.hasProfileName(conv) else { return "#" }
        return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Profile pictures, decoded once at avatar size (they used to be re-read and
/// re-decoded at full size on every redraw of every row). A new photo from
/// that person changes the file's date, which makes a new cache entry.
@MainActor
enum AvatarCache {
    private static let cache: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 200; return c }()

    static func image(_ m: Messenger, _ phone: String) -> UIImage? {
        guard let path = m.profilePhotoPath(phone) else { return nil }
        let changed = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)#\(changed)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let img = ImageDecode.still(d, maxPixels: 300) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct RequestsView: View {
    @EnvironmentObject var m: Messenger
    @Binding var path: [ChatRoute]

    var body: some View {
        let _ = m.revision
        List(m.conversations(requests: true)) { c in
            Button { path.append(ChatRoute(conv: c.id)) } label: { ConversationRow(c: c) }
        }
        .navigationTitle("Requests")
    }
}

struct NewChatView: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let open: (String) -> Void
    @State private var number = ""
    @State private var country = "1"
    @State private var groupMode = false
    @State private var groupName = ""
    @State private var members: [String] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $groupMode) {
                    Text("Chat").tag(false)
                    Text("New group").tag(true)
                }.pickerStyle(.segmented)

                if groupMode {
                    Section("Group name") { TextField("Name", text: $groupName) }
                }
                Section(groupMode ? "Add members" : "Phone number") {
                    HStack {
                        Text("+")
                        TextField("1", text: $country).keyboardType(.numberPad).frame(width: 44)
                        TextField("Phone number", text: $number).keyboardType(.phonePad)
                    }
                    Button(groupMode ? "Add" : (busy ? "Checking…" : "Start chat")) { go() }.disabled(number.isEmpty || busy)
                }
                // Calling an ordinary phone (through the relay's phone bridge), when this account may.
                if !groupMode && m.pstnAvailable {
                    Section {
                        Button { callPhone() } label: { Label("Call this number (regular phone call)", systemImage: "phone") }
                            .disabled(number.isEmpty)
                    } footer: {
                        Text("Rings any phone, even without cellosig. Goes through your relay and the phone network, so it isn't end-to-end encrypted. US and Canadian numbers only.")
                    }
                }
                ContactsSection { p in
                    if groupMode {
                        if !members.contains(p) { members.append(p) }
                    } else {
                        m.startChat(p)
                        open(p)
                    }
                }
                if groupMode && !members.isEmpty {
                    Section("Members") {
                        ForEach(members, id: \.self) { Text(m.displayName($0)) }
                            .onDelete { members.remove(atOffsets: $0) }
                        Button("Create group") {
                            Task {
                                let conv = await m.createGroup(name: groupName.isEmpty ? "Group" : groupName, members: members)
                                open(conv)
                            }
                        }.disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let status { Section { Text(status).foregroundStyle(.secondary) } }
            }
            .navigationTitle(groupMode ? "New group" : "New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func callPhone() {
        guard let p = PhoneNumbers.normalize(number, countryCode: country) else { status = "Enter a full phone number."; return }
        guard p != m.me else { status = "That's your own number."; return }
        guard p.hasPrefix("+1") else { status = "Phone calls only go to US and Canadian numbers."; return }
        dismiss()
        CallManager.shared.call(p, pstn: true)
    }

    private func go() {
        guard let p = PhoneNumbers.normalize(number, countryCode: country) else { status = "That doesn't look like a full phone number."; return }
        guard p != m.me else { status = "That's your own number."; return }
        busy = true
        Task {
            let registered = await m.lookup([p]).contains(p)
            busy = false
            guard registered else { status = "\(PhoneNumbers.pretty(p)) isn't on cellosig yet."; return }
            if groupMode {
                if !members.contains(p) { members.append(p) }
                number = ""
                status = nil
            } else {
                m.startChat(p)
                open(p)
            }
        }
    }
}
