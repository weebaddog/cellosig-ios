import Foundation
import MetricKit
import SwiftUI
import UIKit

/// Problem reports to the owner: crashes (from iOS's own crash reports, handed over at the next
/// launch) and errors the app hits, automatically if that's on in Settings (it is unless turned
/// off), and "Report a problem" written by a person. They go to cellosig.com (the owner's
/// CelloCloud server, which emails them to the owner) and hold only what went wrong, the app
/// version and the iPhone model: never messages, contacts or keys, and phone numbers and email
/// addresses are blanked out of error texts. The same as the Android app's ProblemReports.kt.
@MainActor
final class ProblemReports: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = ProblemReports()
    static let source = "cellosig-iphone"
    private static let url = URL(string: "https://cellosig.com/api/report")!
    private var started = false

    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "reports_auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "reports_auto"); objectWillChange.send() }
    }

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                let what = [c.exceptionType.map { "exception \($0)" }, c.signal.map { "signal \($0)" }, c.terminationReason]
                    .compactMap { $0 }.joined(separator: ", ")
                let stack = String(decoding: c.callStackTree.jsonRepresentation(), as: UTF8.self)
                let version = "\(c.metaData.applicationBuildVersion)"
                Task { @MainActor in
                    guard self.isOn else { return }
                    try? await self.post(kind: "crash", message: "Crash: \(what.isEmpty ? "unknown" : what) (build \(version))", detail: stack)
                }
            }
        }
    }

    /// Something went wrong that the app survived; sent if automatic reports are on.
    func error(_ place: String, _ e: Error) {
        guard isOn else { return }
        Task { try? await post(kind: "app error", message: "\(place): \(String(describing: e))", detail: "") }
    }

    /// "Report a problem": what the person wrote. Nil if it was sent, else why not.
    func userReport(_ text: String, details: Bool) async -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Write what went wrong first." }
        do { try await post(kind: "user", message: t, detail: "", device: details); return nil }
        catch { return "Couldn't send it: \(error.localizedDescription)" }
    }

    /// Phone numbers (7+ digits) and email addresses blanked out.
    nonisolated static func scrub(_ s: String) -> String {
        var out = s
        for (pattern, with) in [("(?<![\\w.:])\\+?\\(?\\d(?:[ ().-]{0,2}\\d){6,}", "[number]"),
                                ("[^\\s@()<>\"']+@[^\\s@()<>\"']+\\.[A-Za-z]{2,}", "[email]")] {
            let re = try! NSRegularExpression(pattern: pattern)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: with)
        }
        return out
    }

    private static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private func post(kind: String, message: String, detail: String, device: Bool = true) async throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var body: [String: Any] = [
            "source": Self.source, "kind": kind,
            "message": String((kind == "user" ? message : Self.scrub(message)).prefix(500)),
            "detail": String(Self.scrub(detail).prefix(6000)),
            "version": String(version.prefix(30)),
        ]
        if device { body["device"] = String("\(Self.model) · iOS \(UIDevice.current.systemVersion)".prefix(80)) }
        var req = URLRequest(url: Self.url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "x-cellocloud")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "the server said \(code)"]) }
    }
}

/// Settings → Problem reports.
struct ProblemReportSettings: View {
    @ObservedObject private var r = ProblemReports.shared
    @State private var writing = false
    @State private var text = ""
    @State private var details = true
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        Section {
            Toggle("Send problem reports automatically", isOn: Binding(get: { r.isOn }, set: { r.isOn = $0 }))
            Button("Report a problem") { writing = true; result = nil }
            if let result { Text(result).font(.caption) }
        } header: { Text("Problem reports") } footer: {
            Text("When cellosig crashes or something fails, the error, app version and iPhone model go to cellosig's developer, so it can be fixed. Never your messages, contacts or keys; numbers and email addresses are blanked out.")
        }
        .sheet(isPresented: $writing) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $text).frame(minHeight: 140)
                            .onChange(of: text) { t in if t.count > 500 { text = String(t.prefix(500)) } }
                    } footer: { Text("What happened, and what you expected. It goes straight to cellosig's developer. Don't include anything private.") }
                    Toggle("Include the app version and iPhone model", isOn: $details)
                    if let result { Text(result).font(.caption) }
                }
                .navigationTitle("Report a problem")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { writing = false }.disabled(sending) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(sending ? "Sending…" : "Send") {
                            sending = true
                            Task {
                                let why = await r.userReport(text, details: details)
                                sending = false
                                if why == nil { writing = false; text = ""; result = "Sent. Thank you!" } else { result = why }
                            }
                        }.disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
