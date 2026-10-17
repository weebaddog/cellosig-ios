import CellosigCore
import SwiftUI

/// The in-app call screen (CallKit shows the system one on the lock screen).
struct CallView: View {
    @EnvironmentObject var m: Messenger
    @ObservedObject var calls = CallManager.shared
    let call: CallManager.State

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Avatar(conv: call.peer, size: 112)
            Text(name).font(.title.bold()).lineLimit(1)
            if name != PhoneNumbers.pretty(call.peer) {
                Text(PhoneNumbers.pretty(call.peer)).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(status).font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            if call.pstn {
                // Honest about it: the phone network carries this call in the clear.
                Label("Phone call · not end-to-end encrypted", systemImage: "phone.fill").font(.caption).foregroundStyle(.orange)
            } else {
                Label("End-to-end encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if call.phase == .incoming {
                HStack(spacing: 70) {
                    round("phone.down.fill", .red) { calls.hangup() }
                    round("phone.fill", .green) { calls.answer() }
                }
            } else if call.phase != .ended {
                HStack(spacing: 34) {
                    round(call.muted ? "mic.slash.fill" : "mic.fill", call.muted ? .orange : .gray) { calls.toggleMute() }
                    round("phone.down.fill", .red) { calls.hangup() }
                    round(call.speaker ? "speaker.wave.3.fill" : "speaker.fill", call.speaker ? .blue : .gray) { calls.toggleSpeaker() }
                }
            }
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    /// Your name for them, else (a phone call) the network's caller name, else the number.
    private var name: String {
        if call.pstn, !m.hasProfileName(call.peer), let n = call.networkName { return n }
        return m.displayName(call.peer)
    }

    private var status: String {
        switch call.phase {
        case .calling: return "Calling…"
        case .ringing: return "Ringing…"
        case .incoming: return "Incoming call"
        case .connecting: return "Connecting…"
        case .active: return CallManager.formatDuration(Int(Date().timeIntervalSince(call.connectedAt ?? Date())))
        case .ended:
            switch call.endReason {
            case "busy": return "Busy"
            case "declined": return "Declined"
            case "failed": return "Couldn't connect"
            case "no_answer", "missed": return "No answer"
            case "no_microphone": return "Microphone access is off"
            default: return CallManager.phoneRefusal(call.endReason)?.capitalizedFirst ?? "Call ended"
            }
        }
    }

    private func round(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Tinted Liquid Glass on iOS 26 (a plain coloured circle before).
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white)
                .frame(width: 72, height: 72).liquidGlass(in: Circle(), tint: color)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Covers the app until it's unlocked: the cellosig password (if one is set),
/// or Face ID / Touch ID / the phone's passcode.
struct LockView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var password = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("cellosig is locked").font(.title3.bold())
            if AppPassword.isSet {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit(tryPassword)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    .frame(maxWidth: 280)
                Button("Unlock", action: tryPassword).buttonStyle(.borderedProminent).disabled(password.isEmpty)
                if model.biometricsAllowed {
                    Button("Use Face ID") { Task { await model.unlock() } }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
            } else {
                Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { if phase == .active { Task { await model.unlock(auto: true) } } }
        .onChange(of: phase) { p in if p == .active { Task { await model.unlock(auto: true) } } }
    }

    private func tryPassword() {
        guard !password.isEmpty else { return }
        message = model.unlock(password: password)
        password = ""
    }
}
