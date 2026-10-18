import SwiftUI

/// Who a Report sheet is about (a 1:1 contact, or one member of a group).
struct ReportTarget: Identifiable {
    let phone: String
    var id: String { phone }
}

/// Report someone for abuse: a reason, optionally the last few messages as
/// evidence (shared from your own copy — the relay can't read chats), and
/// blocking them at the same time.
struct ReportSheet: View {
    @EnvironmentObject var m: Messenger
    @Environment(\.dismiss) private var dismiss
    let phone: String
    /// The chat it was reported from (where the shared messages come from).
    let conv: String
    /// Called after reporting; true if they were also blocked.
    var done: (Bool) -> Void = { _ in }

    @State private var reason = Self.reasons[0].key
    @State private var share = true
    @State private var block = true
    @State private var failed = false
    @State private var sent = false

    static let reasons: [(key: String, label: String)] = [
        ("spam", "Spam or scam"),
        ("harassment", "Harassment, bullying or threats"),
        ("sexual", "Sexual content"),
        ("violence", "Violence or hate"),
        ("child_safety", "Involves a child"),
        ("impersonation", "Pretending to be someone else"),
        ("other", "Something else"),
    ]

    private var name: String { Messenger.isGroup(conv) ? m.groupMemberName(phone) : m.displayName(phone) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(Self.reasons, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("What's wrong?") }
                Section {
                    Toggle("Include the last 10 messages", isOn: $share)
                } footer: {
                    Text(share
                         ? "Your last 10 messages with \(name) are sent with the report, from your copy of this chat, so the problem can be checked. Nothing else is shared."
                         : "Only the report is sent. cellosig can't read your chats, so without messages it may be harder to act on.")
                }
                Section {
                    Toggle("Also block \(name)", isOn: $block)
                } footer: {
                    Text("Reports are reviewed within 24 hours; accounts that abuse others are removed. \(name) isn't told who reported them.")
                }
            }
            .navigationTitle("Report \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") {
                        guard m.report(phone, in: conv, reason: reason, share: share) else { failed = true; return }
                        if block { m.block(phone) }
                        sent = true
                    }
                    .bold()
                }
            }
            .alert("Couldn't send the report", isPresented: $failed) { Button("OK") {} } message: {
                Text("cellosig isn't connected right now. Try again in a moment.")
            }
            .alert("Thanks — report sent", isPresented: $sent) {
                Button("OK") { dismiss(); done(block) }
            } message: {
                Text(block ? "\(name) is blocked." : "You can still block \(name) from the chat's menu.")
            }
        }
    }
}
