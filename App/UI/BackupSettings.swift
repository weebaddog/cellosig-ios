import CellosigCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Chat backups: on/off (off by default), the folder, back up now, see the code
/// again, and restore from a backup file (from this iPhone or the Android app).
struct BackupSettings: View {
    @EnvironmentObject var m: Messenger
    @ObservedObject private var b = ChatBackups.shared

    private enum Pick { case newFolder, folder, backup }
    @State private var pick: Pick?
    @State private var importing = false
    @State private var newCode: String?      // shown first when turning on
    @State private var pendingCode: String?  // then waits for the folder
    @State private var shownCode: String?
    @State private var restoreURL: URL?
    @State private var askCode = false
    @State private var typed = ""
    @State private var checked: BackupInfo?
    @State private var problem: String?

    private func present(_ p: Pick) {
        pick = p
        // (After an alert closes: SwiftUI won't open the picker while it's still going.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { importing = true }
    }

    var body: some View {
        Section {
            Toggle("Back up chats every day", isOn: Binding(
                get: { b.isOn },
                set: { on in if on { newCode = BackupFormat.newPassphrase() } else { b.turnOff() } }))
            if b.isOn {
                LabeledContent("Folder", value: b.folder?.lastPathComponent ?? "Not chosen")
                LabeledContent("Last backup", value: b.lastAt?.formatted(date: .abbreviated, time: .shortened) ?? "None yet")
                Button("Back up now") { Task { await b.backUpNow(m) } }.disabled(b.busy != nil)
                Button("Change folder") { present(.folder) }.disabled(b.busy != nil)
                Button("Show the backup code") { shownCode = b.passphrase ?? "" }
            }
            if let s = b.busy ?? b.status ?? (b.isOn ? b.lastError : nil) { Text(s).font(.caption) }
            Button("Restore from a backup") { present(.backup) }.disabled(b.busy != nil)
        } header: { Text("Chat backups") } footer: {
            Text("Chats, photos, files, groups and stickers, into a folder you choose (On My iPhone, iCloud Drive, a USB drive…), locked with a 30-digit code only you have. Keeps the newest 2; disappearing messages are left out. Backups from the Android app restore here too.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: pick == .backup ? [.item] : [.folder]) { result in
            let p = pick
            pick = nil
            guard case .success(let url) = result else { pendingCode = nil; return }
            switch p {
            case .newFolder:
                guard let code = pendingCode else { return }
                pendingCode = nil
                do { try b.turnOn(code: code, folder: url); Task { await b.backUpNow(m) } }
                catch { problem = "Couldn't use that folder: \(error.localizedDescription)" }
            case .folder:
                do { try b.setFolder(url) } catch { problem = "Couldn't use that folder: \(error.localizedDescription)" }
            case .backup:
                restoreURL = url; typed = ""; askCode = true
            case nil: break
            }
        }
        .alert("Write down your backup code", isPresented: Binding(get: { newCode != nil }, set: { if !$0 { newCode = nil } }), presenting: newCode) { code in
            Button("I wrote it down") { pendingCode = code; newCode = nil; present(.newFolder) }
            Button("Cancel", role: .cancel) { newCode = nil }
        } message: { code in
            Text("\(BackupFormat.pretty(code))\n\nYou need these 30 digits to restore a backup on a new phone. Nobody else has them and they can't be recovered. Next, choose the folder for backups.")
        }
        .alert("Your backup code", isPresented: Binding(get: { shownCode != nil }, set: { if !$0 { shownCode = nil } }), presenting: shownCode) { _ in
            Button("Done", role: .cancel) { shownCode = nil }
        } message: { code in Text(code.isEmpty ? "Couldn't read it." : BackupFormat.pretty(code)) }
        .alert("Enter the backup code", isPresented: $askCode) {
            TextField("30 digits", text: $typed).keyboardType(.numberPad)
            Button("Next") {
                guard let url = restoreURL, let code = BackupFormat.normalize(typed) else { problem = "That's not 30 digits."; return }
                Task {
                    do { checked = try await b.check(url, code: code) }
                    catch { problem = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { restoreURL = nil }
        } message: { Text("The 30 digits shown when backups were turned on.") }
        .alert("Replace your chats?", isPresented: Binding(get: { checked != nil }, set: { if !$0 { checked = nil } }), presenting: checked) { info in
            Button("Replace", role: .destructive) {
                guard let url = restoreURL, let code = BackupFormat.normalize(typed) else { return }
                Task {
                    do { b.status = try await b.restore(url, code: code, info: info, m: m) }
                    catch { problem = "Restore failed: \(error.localizedDescription)" }
                    restoreURL = nil; typed = ""
                }
            }
            Button("Cancel", role: .cancel) { restoreURL = nil }
        } message: { info in
            Text("This backup from \(info.made.formatted(date: .abbreviated, time: .shortened)) has \(info.messages) messages in \(info.chats) chats. The chats on this iPhone now are replaced by it. Contacts will see your safety number changed if this is a new phone.")
        }
        .alert("Chat backups", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }), presenting: problem) { _ in
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text($0) }
    }
}
