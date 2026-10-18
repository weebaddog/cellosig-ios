import CellosigCore
import SwiftUI

/// What's encrypted and what isn't — for one chat (`conv`), or the whole app (nil).
/// Green check: protected. Orange: not encrypted, or worth knowing.
struct EncryptionInfo: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    var conv: String? = nil
    var showsDone = true
    @State private var showSafety = false

    var body: some View {
        let _ = m.revision
        let preview = Shared.defaults.bool(forKey: "notify_preview")
        List {
            if let conv { chatSection(conv) }

            Section {
                row(Database.encrypted, "Message database",
                    Database.encrypted ? "Encrypted (SQLCipher, AES-256) with a key only this iPhone holds."
                                       : "Not encrypted by cellosig\(Database.notEncryptedReason.map { " — \($0)" } ?? "") (iOS's own protection still applies).")
                row(true, "Keys, photos, files, voice notes",
                    "Sealed with a key that never leaves this iPhone's Keychain; not in iCloud or computer backups.")
                row(!preview, "Notifications",
                    preview ? "Show who wrote and what — on the Lock Screen too, where anyone holding the phone can read them. (Settings → Privacy)"
                            : "Show only “New message”: nothing readable on the Lock Screen.")
                let shielded = Shared.defaults.bool(forKey: ScreenShield.key) || conv.map { m.shieldOf($0) } == true
                row(shielded, "Screenshots",
                    shielded ? "Blocked: screenshots and screen recordings come out blank. (A camera pointed at the screen still works.)"
                             : "Allowed. Turn on Block screenshots for this chat (••• menu) or for all of cellosig (Settings → Security).")
                row(false, "Things you share out",
                    "A photo or file you save or share to another app leaves cellosig's protection.")
            } header: { Text("On this iPhone") }

            Section {
                row(true, "Contents", "Never readable by the relay: messages, photos, files, voice notes, calls, reactions, polls, names and profile photos are all end-to-end encrypted.")
                row(true, "Message sizes", "Padded, so the relay can't tell a short message from a long one.")
                row(false, "Your phone number", "The relay knows your number and that you use cellosig.")
                row(false, "Who and when", "It sees who each message is for and when it's sent (with sealed sender, not who sent it).")
                row(false, "Your IP address", "It sees the internet address you connect from (roughly where you are).")
            } header: { Text("What the relay can see") } footer: {
                Text("The relay passes messages along and deletes each one as soon as it's delivered.")
            }

            if m.pstnAvailable {
                Section {
                    row(false, "Calls to regular phone numbers",
                        "Go through the phone network, so they are NOT end-to-end encrypted. The call screen says so in orange.")
                }
            }
        }
        .navigationTitle(conv == nil ? "Encryption overview" : "Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showSafety) { if let conv { SafetyNumberView(peer: conv) } }
    }

    @ViewBuilder private func chatSection(_ conv: String) -> some View {
        let group = Messenger.isGroup(conv)
        let name = m.title(conv)
        let timer = m.timerOf(conv)
        Section {
            row(true, "Messages, photos, files, voice notes",
                group ? "End-to-end encrypted to each member of \(name) separately. Only they can read them."
                      : "End-to-end encrypted. Only you and \(name) can read them.")
            if !group {
                row(true, "Calls", "End-to-end encrypted cellosig calls.")
                let broken = m.trustBroken(conv), verified = m.isVerified(conv)
                Button { showSafety = true } label: {
                    row(verified && !broken, "Safety number",
                        broken ? "Changed since you verified it — compare again before sending anything sensitive."
                               : verified ? "Verified: nobody is in the middle." : "Not verified yet. Tap to compare with \(name), in person or on a call.")
                }
                .buttonStyle(.plain)
                let sealed = m.accessKeys.of(conv) != nil
                row(sealed, "Sealed sender",
                    sealed ? "On: the relay can't see that messages to \(name) come from you."
                           : "Not yet: it starts once \(name) has written to you. Until then the relay sees who sent each message.")
            }
            row(timer > 0, "Disappearing messages",
                timer > 0 ? "On: new messages are erased \(Messenger.timerLabel(timer)) after they're read."
                          : "Off: messages stay until you delete them.")
        } header: { Text("In this chat") }
    }

    private func row(_ good: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: good ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(good ? Color.green : Color.orange)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(good ? "Protected" : "Not protected"): \(title). \(detail)")
    }
}

/// The notice at the top of every chat; tap for the details.
struct EncryptionBanner: View {
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Label("Messages and calls are end-to-end encrypted. Tap to see what's protected.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 14), fallback: .thinMaterial)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
