import SwiftUI

/// Settings → About: exactly which build this is (the IPA's version, build
/// number, when it was built and from which code), so you can tell copies apart.
struct AboutSection: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    private var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    private var build: String { info["CFBundleVersion"] as? String ?? "?" }
    /// Set by the build server when it packages the sideload IPA (absent in other builds).
    private var builtAt: Date? {
        (info["CellosigBuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    private var commit: String? { info["CellosigCommit"] as? String }
    private var kind: String {
        if KeepAlive.available { return "Sideloaded IPA" }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "TestFlight" : "App Store"
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            LabeledContent("Build", value: build)
            LabeledContent("Installed as", value: kind)
            if let builtAt {
                LabeledContent("Built", value: builtAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let commit {
                LabeledContent("Code", value: commit).font(.system(.body, design: .monospaced))
            }
            LabeledContent("Message database", value: Database.encrypted ? "Encrypted (SQLCipher)" : "Not encrypted")
            if !Database.encrypted, let why = Database.notEncryptedReason {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("About") } footer: {
            Text("cellosig \(version) (\(build)). Tell this to whoever helps you with the app, so they know exactly which copy you have.")
        }
        .textSelection(.enabled)
    }
}
