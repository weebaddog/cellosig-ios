import CellosigCore
import SwiftUI
import UserNotifications

@main
struct CellosigApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: phase) { p in model.phaseChanged(p) }
        }
    }
}

/// Push registration, quiet "relay moved" pushes, and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if Account.load() != nil { app.registerForRemoteNotifications() }
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            Shared.defaults.set(hex, forKey: "apns_token")
            AppModel.shared.messenger?.setPushToken(hex)
        }
    }

    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// Background push: the relay moved to a new address.
    func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            if let url = RelayAddress.accept(info["r"]) { AppModel.shared.messenger?.moveRelay(to: url); done(.newData) }
            else { done(.noData) }
        }
    }

    /// Tapped a notification: open that chat.
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let conv = response.notification.request.content.userInfo["conv"] as? String
        Task { @MainActor in
            if let conv { AppModel.shared.openConversation = conv }
            done()
        }
    }

    /// In the foreground the chat list shows new messages itself.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])
    }
}

/// Holds the signed-in messenger (or nil while setting up).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var messenger: Messenger?
    /// Set when a notification is tapped; the chat list opens it.
    @Published var openConversation: String?
    @Published var startupError: String?
    /// Hides the app's contents in the app switcher.
    @Published var obscured = false

    static let defaultRelay = "wss://theoretical-grades-rising-louis.trycloudflare.com"

    init() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("share"))
        if let account = Account.load() { start(account) }
    }

    func start(_ account: Account) {
        do {
            let m = try Messenger(account: account)
            m.onIncoming = { [weak self] conv, sender, preview in self?.notify(conv: conv, sender: sender, preview: preview) }
            m.start()
            messenger = m
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted { Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() } }
            }
        } catch {
            startupError = "Couldn't open your messages (\(error.localizedDescription))."
        }
    }

    func signedOut() {
        messenger?.stop()
        messenger = nil
        Account.clear()
    }

    func erased() {
        messenger = nil
    }

    func phaseChanged(_ p: ScenePhase) {
        obscured = p != .active
        if p == .active { messenger?.foregrounded() }
    }

    /// A local notification while the app runs in the background (push notifications come with the relay's APNs support).
    private func notify(conv: String, sender: String, preview: String) {
        guard let m = messenger else { return }
        let showContent = Shared.defaults.bool(forKey: "notify_preview")
        let c = UNMutableNotificationContent()
        c.title = showContent ? m.title(conv) : "cellosig"
        c.body = showContent ? (Messenger.isGroup(conv) ? "\(m.displayName(sender)): \(preview)" : preview) : "New message"
        c.sound = .default
        c.threadIdentifier = conv
        c.userInfo = ["conv": conv]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if let m = model.messenger {
                ChatListView().environmentObject(m)
            } else {
                SetupView()
            }
            if model.obscured {
                Color(.systemBackground).ignoresSafeArea()
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .alert("cellosig", isPresented: .constant(model.startupError != nil)) {
            Button("OK") { model.startupError = nil }
        } message: { Text(model.startupError ?? "") }
    }
}

// MARK: - Sign-up

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var relay = AppModel.defaultRelay
    @State private var country = "1"
    @State private var number = ""
    @State private var code = ""
    @State private var phone: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("End-to-end encrypted messages. Your phone number is your account; the relay only ever sees ciphertext.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if phone == nil {
                    Section("Your phone number") {
                        HStack {
                            Text("+")
                            TextField("1", text: $country).keyboardType(.numberPad).frame(width: 44)
                            TextField("Phone number", text: $number).keyboardType(.phonePad).textContentType(.telephoneNumber)
                        }
                    }
                    Section("Relay") {
                        TextField("wss://…", text: $relay)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).font(.footnote.monospaced())
                    }
                    Section {
                        Button(busy ? "Sending code…" : "Send code", action: requestCode).disabled(busy || number.isEmpty)
                    }
                } else {
                    Section("Code sent to \(PhoneNumbers.pretty(phone!))") {
                        TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button(busy ? "Checking…" : "Verify", action: submitCode).disabled(busy || code.count < 4)
                        Button("Use a different number") { phone = nil; code = "" }.foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("cellosig")
        }
    }

    private var relayURL: URL? {
        let s = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), ["ws", "wss"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }

    private func requestCode() {
        error = nil
        guard let url = relayURL else { error = "The relay address must start with wss://"; return }
        guard let p = PhoneNumbers.normalize(number, countryCode: country) else { error = "That doesn't look like a full phone number."; return }
        busy = true
        Task {
            let r = await PhoneVerification.requestCode(relay: url, phone: p)
            busy = false
            switch r {
            case .ok: phone = p
            case .failed(let why): error = Self.explain(why)
            }
        }
    }

    private func submitCode() {
        guard let url = relayURL, let p = phone else { return }
        error = nil
        busy = true
        Task {
            let r = await PhoneVerification.submitCode(relay: url, phone: p, code: code.filter(\.isNumber))
            busy = false
            switch r {
            case .ok(let token?):
                let account = Account(phone: p, token: token, relayURL: url.absoluteString)
                do { try account.save(); model.start(account) } catch { self.error = "Couldn't save your account." }
            case .ok(nil): error = "The relay didn't issue a token."
            case .failed(let why): error = Self.explain(why)
            }
        }
    }

    static func explain(_ reason: String) -> String {
        switch reason {
        case "unreachable": return "Can't reach the relay. Check the address and your connection."
        case "bad_code": return "That code isn't right (or it expired)."
        case "rate_limited": return "Too many attempts. Wait a few minutes and try again."
        case "sms_failed": return "The relay couldn't text that number."
        case "bad_phone": return "That phone number isn't valid."
        default: return "The relay said: \(reason)"
        }
    }
}
