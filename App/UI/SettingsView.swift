import CellosigCore
import PhotosUI
import SwiftUI

struct SafetyNumberView: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let peer: String

    var body: some View {
        let _ = m.revision
        NavigationStack {
            List {
                if let sn = m.safetyNumber(peer) {
                    Section {
                        Text(SafetyNumber.formatted(sn))
                            .font(.system(.title3, design: .monospaced))
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical)
                    } footer: {
                        Text("Compare this number with \(m.displayName(peer)) in person or on a call. If both phones show the same digits, nobody is intercepting your messages.")
                    }
                    if m.trustBroken(peer) {
                        Section {
                            Label("\(m.displayName(peer))'s safety number changed since you verified it. Compare again before sending anything sensitive.", systemImage: "exclamationmark.shield.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        Toggle("Verified", isOn: Binding(get: { m.isVerified(peer) }, set: { m.setVerified(peer, $0) }))
                    }
                } else {
                    Text("Send or receive a message first; the safety number comes from both of your keys.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Safety number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Messenger
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var lockError = false
    @AppStorage("notify_preview", store: Shared.defaults) private var notifyPreview = false

    var body: some View {
        let _ = m.revision
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Your number", value: PhoneNumbers.pretty(m.me))
                    LabeledContent("Relay", value: m.connected ? "Connected" : "Connecting…")
                }
                Section {
                    TextField("Your name", text: $name)
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Choose photo", systemImage: "person.crop.circle") }
                    Button("Save profile") { saveProfile(photo: nil) }
                } header: { Text("Your profile") } footer: {
                    Text("Sent end-to-end encrypted to people you message, so they see your name instead of a number.")
                }
                Section("Privacy") {
                    Toggle("Send read receipts", isOn: Binding(get: { m.readReceipts }, set: { m.readReceipts = $0 }))
                    Toggle("Show sender and message in notifications", isOn: $notifyPreview)
                }
                AppearanceSection()
                if AppGroup.container == nil {
                    Section {
                        Label("Widget and Share to cellosig are off in this install", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark")
                    } footer: {
                        Text("They need an App Group, which this copy of cellosig was installed without (the signing tool didn't add one).")
                    }
                }
                if KeepAlive.available {
                    Section {
                        Toggle("Stay connected in the background", isOn: Binding(get: { KeepAlive.shared.enabled }, set: { KeepAlive.shared.enabled = $0; m.touch() }))
                        if KeepAlive.shared.enabled {
                            LabeledContent("Status", value: KeepAlive.shared.isRunning ? "Running" : "Not running")
                            if let paused = KeepAlive.shared.pausedAt {
                                LabeledContent("Last paused by iOS", value: paused.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    } footer: {
                        Text("This copy of cellosig was installed without Apple's push service, so it only receives while it's running. On: it keeps running (by playing silence) so messages notify and calls ring — uses more battery. Swiping it away in the app switcher still stops it.")
                    }
                }
                Section {
                    Toggle("Lock with Face ID or passcode", isOn: Binding(get: { model.lockEnabled }, set: { on in
                        Task { if !(await model.setLock(on)) { lockError = true } }
                    }))
                } header: { Text("App lock") } footer: {
                    Text("Locks cellosig whenever you leave it. Calls still ring on the lock screen.")
                }
                let reminders = m.reminders()
                if !reminders.isEmpty {
                    Section("Reminders") {
                        ForEach(reminders) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TimeParser.label(r.at)).font(.subheadline.bold())
                                Text("\(m.title(r.conv)): \(r.text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .swipeActions { Button("Cancel", role: .destructive) { m.cancelReminder(r.id) } }
                        }
                    }
                }
                let blocked = m.blockedList()
                if !blocked.isEmpty {
                    Section("Blocked") {
                        ForEach(blocked, id: \.self) { p in
                            HStack { Text(PhoneNumbers.pretty(p)); Spacer(); Button("Unblock") { m.unblock(p) } }
                        }
                    }
                }
                Section {
                    Button("Delete my account", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Erases your account from the relay and everything cellosig stored on this iPhone.")
                }
                Section {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { name = m.ownProfile.name ?? "" }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        saveProfile(photo: Self.squareJPEG(img))
                    }
                    photoItem = nil
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    Task { await m.deleteAccount(); model.erased() }
                }
            } message: { Text("This can't be undone.") }
            .alert("App lock", isPresented: $lockError) { Button("OK") {} } message: {
                Text("Couldn't turn the lock on. This iPhone needs a passcode (Settings → Face ID & Passcode), and you need to confirm it once.")
            }
        }
    }

    private func saveProfile(photo: Data?) {
        try? m.ownProfile.set(name: name, photo: photo, removePhoto: false)
        // Everyone you talk to gets the new version.
        Task { for c in m.conversations() { await m.shareProfile(c.id, force: true) } }
    }

    /// Small square JPEG (fits the 96 KB profile limit).
    static func squareJPEG(_ img: UIImage) -> Data? {
        let side: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let scaled = renderer.image { _ in
            let s = max(side / img.size.width, side / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        for q in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let d = scaled.jpegData(compressionQuality: q), d.count <= Profiles.maxPhotoBytes { return d }
        }
        return nil
    }
}
