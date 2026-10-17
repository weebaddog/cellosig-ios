import CellosigCore
import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var m: Messenger
    @EnvironmentObject var model: AppModel
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false

    var body: some View {
        let _ = m.revision
        let convs = m.conversations()
        let requests = m.conversations(requests: true)
        NavigationStack(path: $path) {
            List {
                if !m.connected {
                    Label("Connecting to relay…", systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                }
                if m.authFailed {
                    Label("The relay no longer accepts this sign-in. Sign up again in Settings.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
                if !requests.isEmpty {
                    NavigationLink { RequestsView(path: $path) } label: {
                        Label("Message requests (\(requests.count))", systemImage: "tray")
                    }
                }
                ForEach(convs) { c in
                    NavigationLink(value: c.id) { ConversationRow(c: c) }
                        .swipeActions {
                            Button(role: .destructive) { m.deleteConversation(c.id) } label: { Label("Delete", systemImage: "trash") }
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
            .navigationTitle("cellosig")
            .navigationDestination(for: String.self) { ChatView(conv: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { conv in showNew = false; path = [conv] }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear(perform: openTapped)
            .onChange(of: model.openConversation) { _ in openTapped() }
        }
    }

    /// A notification was tapped: show that chat.
    private func openTapped() {
        guard let conv = model.openConversation else { return }
        model.openConversation = nil
        showNew = false
        showSettings = false
        path = [conv]
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
            if !Messenger.isGroup(conv), let d = m.profilePhoto(conv), let img = UIImage(data: d) {
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

struct RequestsView: View {
    @EnvironmentObject var m: Messenger
    @Binding var path: [String]

    var body: some View {
        let _ = m.revision
        List(m.conversations(requests: true)) { c in
            Button { path.append(c.id) } label: { ConversationRow(c: c) }
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
                if groupMode && !members.isEmpty {
                    Section("Members") {
                        ForEach(members, id: \.self) { Text(PhoneNumbers.pretty($0)) }
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
