import CellosigCore
import LocalAuthentication
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
        if Account.load() != nil {
            app.registerForRemoteNotifications()
            // PushKit must be set up at every launch: iOS may have launched us for a call.
            MainActor.assumeIsolated {
                _ = AppModel.shared
                CallManager.shared.registerForVoIP()
            }
        }
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

    /// In the foreground the chat list shows new messages itself, but a reminder
    /// you set must still show (it was being swallowed while the app was open).
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done(n.request.identifier.hasPrefix("reminder:") ? [.banner, .list, .sound] : [])
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
    /// App lock (Settings): set when the app goes to the background.
    @Published private(set) var locked = false
    private var promptedThisVisit = false

    var lockEnabled: Bool {
        get { Shared.defaults.bool(forKey: "app_lock") }
        set {
            Shared.defaults.set(newValue, forKey: "app_lock")
            objectWillChange.send()
            ExtensionBridge.shared.writeSnapshots()   // the widget hides chats while the lock is on
        }
    }

    static let defaultRelay = "wss://theoretical-grades-rising-louis.trycloudflare.com"

    init() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("share"))
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("voice"))
        if let account = Account.load() {
            locked = lockEnabled
            start(account)
        }
    }

    func start(_ account: Account) {
        do {
            let m = try Messenger(account: account)
            m.onIncoming = { [weak self] conv, sender, preview in self?.notify(conv: conv, sender: sender, preview: preview) }
            m.onCallSignal = { from, sig, ts in CallManager.shared.onSignal(from, sig, ts) }
            m.onPstnSignal = { number, sig, name, error in
                CallManager.shared.onSignal(number, sig, nowMs(), pstn: true, networkName: name, error: error)
            }
            m.start()
            messenger = m
            ExtensionBridge.shared.attach(m)
            ContactBook.shared.loadNames(m)
            CallManager.shared.registerForVoIP()
            // After the first screen is up: starting audio isn't needed to draw it.
            Task { @MainActor in KeepAlive.shared.start() }
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
        ExtensionBridge.shared.detach()
        Account.clear()
    }

    func erased() {
        messenger = nil
        ExtensionBridge.shared.detach()
    }

    /// The chat that was open when the app went to the background.
    private var chatOnScreen: String?

    private var lastPhase: ScenePhase = .active
    /// Our own Face ID / passcode prompt is up (it makes the app "inactive" too).
    private var authenticating = false

    func phaseChanged(_ p: ScenePhase) {
        // The privacy cover: up the moment you leave (so the app switcher never shows
        // your chats), down the moment you come back — not only once the unlock
        // animation has finished. Not for our own Face ID prompt (App lock covers that).
        switch p {
        case .active: obscured = false
        case .inactive: obscured = lastPhase == .active && !authenticating
        default: obscured = true
        }
        lastPhase = p
        if p == .active {
            KeepAlive.shared.enteredForeground()
            messenger?.foregrounded()
            ExtensionBridge.shared.processInbox()
            ScreenShield.refresh()   // (the window may not have existed yet at launch)
            if let conv = chatOnScreen, let m = messenger, m.activeChat == nil {
                m.activeChat = conv
                Task { await m.markRead(conv) }
            }
            chatOnScreen = nil
        }
        if p == .background {
            // Still running (sideloaded keep-alive, or a call): nobody is looking, so
            // new messages in the open chat notify and stay unread.
            if let conv = messenger?.activeChat { chatOnScreen = conv; messenger?.activeChat = nil }
            if messenger != nil { KeepAlive.shared.enteredBackground() }
            promptedThisVisit = false
            if lockEnabled && messenger != nil { locked = true }
        }
    }

    /// With a cellosig password: the password, or Face ID / Touch ID (never in
    /// Lockdown mode). Without one: Face ID / Touch ID, falling back to the
    /// phone's passcode.
    /// `auto`: the lock screen asking by itself — only once per visit, so
    /// cancelling the prompt doesn't bring it straight back.
    func unlock(auto: Bool = false) async {
        guard locked else { return }
        if auto { guard !promptedThisVisit else { return }; promptedThisVisit = true }
        let ctx = LAContext()
        var err: NSError?
        if AppPassword.isSet {
            guard biometricsAllowed, ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return }
            ctx.localizedFallbackTitle = ""   // the fallback is our password field, not the phone's passcode
            if await evaluate(ctx, .deviceOwnerAuthenticationWithBiometrics, "Unlock cellosig") { locked = false }
            return
        }
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // The passcode was removed from the phone: nothing left to check against.
            locked = false; return
        }
        if await evaluate(ctx, .deviceOwnerAuthentication, "Unlock cellosig") { locked = false }
    }

    /// Face ID / passcode, marked as ours (so the privacy cover doesn't go up for it).
    private func evaluate(_ ctx: LAContext, _ policy: LAPolicy, _ reason: String) async -> Bool {
        authenticating = true
        defer { authenticating = false }
        return (try? await ctx.evaluatePolicy(policy, localizedReason: reason)) == true
    }

    /// Face ID may unlock the app (with a password set: unless Lockdown mode is on).
    var biometricsAllowed: Bool { !(AppPassword.isSet && Lockdown.on) }

    var eraseOnFails: Bool {
        get { Shared.defaults.bool(forKey: "erase_on_fails") }
        set { Shared.defaults.set(newValue, forKey: "erase_on_fails"); objectWillChange.send() }
    }

    /// Unlock with the cellosig password. Returns what to tell the user if it was wrong.
    func unlock(password: String) -> String? {
        switch AppPassword.check(password, eraseOnFails: eraseOnFails) {
        case .ok:
            locked = false
            return nil
        case .wrong(let left?):
            return left == 1 ? "Wrong password. One more wrong try erases cellosig." : "Wrong password. \(left) tries left before cellosig erases itself."
        case .wrong(nil):
            return "Wrong password."
        case .erase:
            eraseEverything()
            return nil
        }
    }

    /// Wipe cellosig from this iPhone (keys, messages, files, settings). The
    /// relay account stays; signing up again on this number replaces it.
    func eraseEverything() {
        CallManager.shared.hangup()
        if let m = messenger { m.eraseEverything() } else {
            Vault.shared.destroyKey()
            try? FileManager.default.removeItem(at: Paths.root)
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        for key in ["app_lock", "erase_on_fails", "lockdown", "notify_preview", "read_receipts", "wallpaper", "keepalive_paused_at"] {
            Shared.defaults.removeObject(forKey: key)
        }
        messenger = nil
        locked = false
        KeepAlive.shared.stop()   // nothing left to stay connected for
        ExtensionBridge.shared.detach()
    }

    /// Turning the lock on needs a passcode on the phone and one successful check.
    func setLock(_ on: Bool) async -> Bool {
        guard on else { lockEnabled = false; return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err),
              await evaluate(ctx, .deviceOwnerAuthentication, "Lock cellosig with Face ID or your passcode")
        else { return false }
        lockEnabled = true
        return true
    }

    /// A local notification while the app runs in the background (push notifications come with the relay's APNs support).
    private func notify(conv: String, sender: String, preview: String) {
        guard let m = messenger else { return }
        let showContent = Shared.defaults.bool(forKey: "notify_preview")
        let c = UNMutableNotificationContent()
        c.title = showContent ? m.title(conv) : "cellosig"
        // Previews off: only that something arrived — never who or what.
        c.body = showContent ? (Messenger.isGroup(conv) ? "\(m.groupMemberName(sender)): \(preview)" : preview)
                             : (preview.hasPrefix("📞") ? "Missed call" : "New message")
        c.sound = .default
        c.threadIdentifier = conv
        c.userInfo = ["conv": conv]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var calls = CallManager.shared
    @AppStorage("theme", store: Shared.defaults) private var theme = "system"
    @AppStorage("accent", store: Shared.defaults) private var accent = "blue"
    @AppStorage("notify_preview", store: Shared.defaults) private var notifyPreview = false
    @State private var captured = UIScreen.main.isCaptured

    var body: some View {
        ZStack {
            if let m = model.messenger {
                ChatListView().environmentObject(m)
                if model.locked { LockView() }
                // Above the lock: a call can be answered without unlocking (it shows only the caller, not your chats).
                if let call = calls.state {
                    CallView(call: call).environmentObject(m).transition(.move(edge: .bottom))
                }
            } else {
                SetupView()
            }
            if model.obscured {
                Color(.systemBackground).ignoresSafeArea()
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            }
            // The screen is being recorded, mirrored or AirPlayed: show nothing of your chats.
            if captured && !model.obscured {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "record.circle").font(.largeTitle).foregroundStyle(.red)
                    Text("Screen recording or mirroring is on").font(.headline)
                    Text("cellosig is hidden while your screen is being recorded or shown on another display.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            }
        }
        .alert("cellosig", isPresented: .constant(model.startupError != nil)) {
            Button("OK") { model.startupError = nil }
        } message: { Text(model.startupError ?? "") }
        .tint(Appearance.accent(accent))
        .preferredColorScheme(Appearance.scheme(theme))
        // A chat tapped in the widget.
        .onOpenURL { url in if let conv = AppLinks.conversation(from: url) { model.openConversation = conv } }
        // The widget shows message previews only while they're allowed.
        .onChange(of: notifyPreview) { _ in ExtensionBridge.shared.writeSnapshots() }
        // Block screenshots (Settings → Security): needs the window, so not before it's on screen.
        .task { ScreenShield.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
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
                        Button(action: requestCode) { Text(busy ? "Sending code…" : "Send code").frame(maxWidth: .infinity) }
                            .glassButton(prominent: true).controlSize(.large)
                            .disabled(busy || number.isEmpty)
                            .listRowBackground(Glass26.on ? Color.clear : nil)
                    }
                } else {
                    Section("Code sent to \(PhoneNumbers.pretty(phone!))") {
                        TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button(action: submitCode) { Text(busy ? "Checking…" : "Verify").frame(maxWidth: .infinity) }
                            .glassButton(prominent: true).controlSize(.large)
                            .disabled(busy || code.count < 4)
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
