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
            Text(m.displayName(call.peer)).font(.title.bold()).lineLimit(1)
            if m.hasProfileName(call.peer) {
                Text(PhoneNumbers.pretty(call.peer)).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(status).font(.title3).foregroundStyle(.secondary).monospacedDigit()
            }
            Label("End-to-end encrypted", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
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
            default: return "Call ended"
            }
        }
    }

    private func round(_ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white)
                .frame(width: 72, height: 72).background(Circle().fill(color))
        }
    }
}

/// Covers the app until Face ID / Touch ID / the passcode unlocks it.
struct LockView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("cellosig is locked").font(.title3.bold())
            Button("Unlock") { Task { await model.unlock() } }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { if phase == .active { Task { await model.unlock(auto: true) } } }
        .onChange(of: phase) { p in if p == .active { Task { await model.unlock(auto: true) } } }
    }
}
