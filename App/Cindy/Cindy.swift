import AVFoundation
import Foundation
import Network
import SwiftUI

/// Cindy inside one of the user's apps. The app calls `configure` once at launch with what Cindy may do in it,
/// and puts `CindySettingsSection()` in its Settings. While the switch is on, the app is linked to Cindy on the
/// PC: a Cindy button floats over every screen (CindyOverlay) and Cindy can run the app's actions.
/// Switched off = disconnected, so she can do nothing in the app. Used on the main thread only.
final class Cindy: ObservableObject {
    static let shared = Cindy()

    /// Something Cindy can do in this app. `run` gets the arguments she chose (by `params` name) and returns what
    /// happened, in a few words she can read out; throw to report a failure.
    /// risky = the PC asks the user "Can I...?" first (sending, deleting, calling...).
    struct Action {
        let name: String
        let desc: String
        var params: [String: String] = [:]
        var risky = false
        let run: @MainActor ([String: Any]) async throws -> String
    }

    enum Who { case me, cindy, note }
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let who: Who
        var text: String
    }

    @Published private(set) var isOn = false
    @Published private(set) var linked = false
    @Published private(set) var lines: [Line] = []
    @Published private(set) var status = ""
    @Published private(set) var connected = false
    @Published private(set) var thinking = false
    @Published private(set) var asking: String?  // a "Can I...?" waiting for yes or no
    @Published private(set) var listening = false
    /// The app hides Cindy's button while it's locked (App lock): nothing shows over the lock screen.
    var hidden = false {
        didSet { if hidden != oldValue { CindyOverlay.shared.update() } }
    }

    private(set) var appId = ""
    private(set) var appName = ""
    private var actions: [Action] = []
    private var link: CindyLink?
    private var replying: Int?  // index in lines of the reply being streamed
    private var voiceTurn = false  // the user spoke, so Cindy speaks back
    private let voice = AVSpeechSynthesizer()
    private let mic = CindyMic()
    private let path = NWPathMonitor()
    private var away = false
    private var configured = false

    /// Call once at launch. id: "cellosig", "cellocloud"...; name: shown to the user and to Cindy.
    func configure(id: String, name: String, actions: [Action]) {
        guard !configured else { return setActions(actions) }
        configured = true
        appId = id
        appName = name
        self.actions = actions
        linked = CindyPairing.load() != nil
        isOn = linked && UserDefaults.standard.bool(forKey: "cindy.on")
        path.pathUpdateHandler = { [weak self] p in
            let awayNow = !(p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = awayNow != self.away
                self.away = awayNow
                if changed { self.link?.reconnectNow(awayFromHome: awayNow) }
            }
        }
        path.start(queue: .global(qos: .utility))
        if isOn { connect() }
        CindyOverlay.shared.update()
    }

    /// The app's actions changed (for example after signing in): tell Cindy now.
    func setActions(_ list: [Action]) {
        actions = list
        if link != nil {
            disconnect()
            connect()
        }
    }

    /// The Settings switch. Returns false when the app isn't linked yet: show the pairing scanner, then `link(uri:)`.
    @discardableResult
    func setOn(_ on: Bool) -> Bool {
        if on && !linked { return false }
        UserDefaults.standard.set(on, forKey: "cindy.on")
        isOn = on
        if on { connect() } else { disconnect() }
        CindyOverlay.shared.update()
        return true
    }

    /// A scanned (or pasted) pairing code from the PC. Turns Cindy on.
    func link(uri: String) -> Bool {
        guard let p = CindyPairing.parse(uri) else { return false }
        p.save()
        linked = true
        disconnect()
        return setOn(true)
    }

    /// Forget the PC (Settings "Unlink").
    func unlink() {
        setOn(false)
        CindyPairing.clear()
        linked = false
        lines = []
    }

    private func describe() -> [String: Any] {
        ["id": appId, "name": appName, "platform": "ios", "actions": actions.map {
            ["name": $0.name, "desc": $0.desc, "risky": $0.risky, "params": $0.params] as [String: Any]
        }]
    }

    private func connect() {
        guard link == nil, let pairing = CindyPairing.load() else { return }
        status = "Connecting…"
        let l = CindyLink(pairing: pairing, app: describe())
        l.onStatus = { [weak self] s in self?.linkStatus(s) }
        l.onMessage = { [weak self] m in self?.handle(m) }
        l.onHosts = { $0.save() }
        link = l
        l.start(awayFromHome: away)
    }

    private func disconnect() {
        link?.stop()
        link = nil
        connected = false
        thinking = false
        asking = nil
        status = ""
        if mic.active { mic.finish() }
    }

    private func linkStatus(_ s: CindyLink.Status) {
        switch s {
        case .connecting: connected = false; status = "Connecting…"
        case .connected(let pc): connected = true; status = "Connected to \(pc)"
        case .offline(let why): connected = false; status = why
        case .revoked:
            connected = false
            unlink()
            status = "This app was unpaired on the PC"
            return
        }
        if !connected {
            thinking = false
            asking = nil
        }
    }

    private func add(_ who: Who, _ text: String) {
        lines.append(Line(who: who, text: text))
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
            replying = nil
        }
    }

    private func handle(_ msg: [String: Any]) {
        let text = msg["text"] as? String ?? ""
        switch msg["type"] as? String {
        case "do": runAction(msg)
        case "heard": if !text.isEmpty { add(.me, text) }
        case "ignored": thinking = false
        case "text":
            if let i = replying, i < lines.count { lines[i].text += text } else {
                add(.cindy, text)
                replying = lines.count - 1
            }
        case "tool": status = "Working on it…"
        case "error": add(.note, text)
        case "ask":
            asking = text
            replying = nil
            let detail = msg["detail"] as? String ?? ""
            add(.cindy, detail.isEmpty ? text : "\(text)\n\(detail)")
            if voiceTurn { speak(text) }
        case "alert": add(.note, "⚠ \(text)")
        case "done":
            if let i = replying, i < lines.count, voiceTurn { speak(lines[i].text) }
            replying = nil
            thinking = false
            voiceTurn = false
            if connected { status = "Connected" }
        case "synced":
            if msg["busy"] as? Bool != true {
                thinking = false
                replying = nil
            }
        default: break
        }
    }

    private func runAction(_ msg: [String: Any]) {
        let id = msg["id"] as? String ?? ""
        let args = msg["args"] as? [String: Any] ?? [:]
        let action = actions.first { $0.name == msg["action"] as? String }
        let sender = link
        Task { @MainActor in
            var ok = true
            var text: String
            if let action {
                do { text = try await action.run(args) } catch {
                    ok = false
                    text = error.localizedDescription
                }
            } else {
                ok = false
                text = "no such action"
            }
            sender?.send(["type": "result", "id": id, "ok": ok, "text": text])
        }
    }

    /// Something the user typed in the panel (or Yes / No for a "Can I...?").
    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        add(.me, t)
        guard link?.send(["type": "say", "text": t]) == true else {
            return add(.note, "Not connected to Cindy right now. \(connected ? "" : status)")
        }
        asking = nil
        thinking = true
        replying = nil
    }

    /// The mic button: start listening, or send what was heard so far.
    func tapMic() {
        if mic.active { return mic.finish() }
        quiet()
        listening = true
        mic.start { [weak self] pcm in
            guard let self else { return }
            self.listening = false
            guard let pcm else { return }
            guard self.link?.sendAudio(pcm) == true else { return self.add(.note, "Not connected to Cindy right now.") }
            self.asking = nil
            self.thinking = true
            self.voiceTurn = true
            self.replying = nil
        }
    }

    /// Stop what she's doing.
    func stop() {
        link?.send(["type": "stop"])
        quiet()
    }

    func quiet() { voice.stopSpeaking(at: .immediate) }

    private func speak(_ text: String) {
        let clean = text.replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        voice.speak(u)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// An action argument as text ("" if missing).
    func text(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let v = self[key] { return "\(v)" }
        return ""
    }

    func int(_ key: String, _ fallback: Int) -> Int {
        if let i = self[key] as? Int { return i }
        return Int(text(key)) ?? fallback
    }

    func bool(_ key: String, _ fallback: Bool) -> Bool {
        if let b = self[key] as? Bool { return b }
        switch text(key).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return fallback
        }
    }
}
