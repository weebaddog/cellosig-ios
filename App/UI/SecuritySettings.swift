import SwiftUI

/// Settings → App lock, Lockdown mode, Emergency (the same choices as on Android).
struct SecuritySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var lockError = false
    @State private var editingPassword = false
    @State private var confirmErase = false
    @State private var lockdown = Lockdown.on
    @State private var passwordSet = AppPassword.isSet
    @ObservedObject private var security = SecurityMonitor.shared
    @AppStorage(ScreenShield.key, store: Shared.defaults) private var blockScreenshots = false

    var body: some View {
        Section {
            Toggle("Lock cellosig", isOn: Binding(get: { model.lockEnabled }, set: { on in
                Task { if !(await model.setLock(on)) { lockError = true } }
            }))
            .disabled(passwordSet)   // a password always locks; remove it to turn the lock off
            Button(passwordSet ? "Change cellosig password" : "Set a cellosig password") { editingPassword = true }
            if passwordSet {
                Button("Remove password", role: .destructive) {
                    AppPassword.remove()
                    passwordSet = false
                    model.eraseOnFails = false
                }
                Toggle("Erase after \(AppPassword.maxFails) wrong passwords", isOn: Binding(get: { model.eraseOnFails }, set: { model.eraseOnFails = $0 }))
            }
        } header: { Text("App lock") } footer: {
            Text(passwordSet
                 ? "cellosig asks for its password whenever you leave it\(model.biometricsAllowed ? " (Face ID works too)" : ""). Calls still ring on the lock screen."
                 + (model.eraseOnFails ? " After \(AppPassword.maxFails) wrong passwords in a row, cellosig erases itself from this iPhone." : "")
                 : "Locks cellosig with Face ID or the iPhone's passcode whenever you leave it. A cellosig password of its own works even if someone knows your phone's passcode.")
        }
        .alert("App lock", isPresented: $lockError) { Button("OK") {} } message: {
            Text("Couldn't turn the lock on. This iPhone needs a passcode (Settings → Face ID & Passcode), and you need to confirm it once.")
        }
        .sheet(isPresented: $editingPassword) {
            PasswordSheet { pw in
                AppPassword.set(pw)
                passwordSet = true
                model.lockEnabled = true
            }
        }

        Section {
            Toggle("Block screenshots", isOn: $blockScreenshots)
                .onChange(of: blockScreenshots) { _ in ScreenShield.refresh() }
        } footer: {
            Text("Screenshots and screen recordings of cellosig come out blank. To block them in just one chat or group (for everyone in it), use Block screenshots in that chat's ••• menu.")
        }

        Section {
            Toggle("Lockdown mode", isOn: $lockdown)
                .onChange(of: lockdown) { Lockdown.on = $0; model.objectWillChange.send() }
        } header: { Text("Lockdown mode") } footer: {
            Text("""
            For when you may be targeted by spyware. cellosig then handles as little as possible of what others send until you ask:
            • nothing downloads automatically
            • pictures stay hidden until you tap them
            • only contacts whose safety number you verified can call you
            • no in-chat YouTube player
            • other people's profile photos aren't shown
            • with a cellosig password set, Face ID can't unlock the app (password only)
            """)
        }

        Section {
            if security.findings.isEmpty {
                Label("No signs of a jailbreak, injected code or a broken sandbox", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
            } else {
                ForEach(security.findings) { f in
                    Label(f.what, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            // Live: re-checked every 15 s while cellosig is open.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Label("Checking live · last check \(security.lastChecked.formatted(.relative(presentation: .numeric)))",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch SecurityCheck.appleLockdownMode {
            case true?: Label("iPhone Lockdown Mode is on", systemImage: "lock.shield.fill").foregroundStyle(.green)
            case false?: Label("iPhone Lockdown Mode is off", systemImage: "lock.shield").foregroundStyle(.orange)
            case nil: EmptyView()
            }
        } header: { Text("Security check") } footer: {
            Text("""
            This only catches crude tools. Spyware like Pegasus breaks into iOS itself and hides from apps, so a clean check can't prove the phone is safe — no app can. What really protects you:
            • Apple's Lockdown Mode (Settings → Privacy & Security → Lockdown Mode)
            • installing iOS updates right away
            • restarting the iPhone every day or two
            • if you're worried, a scan with Amnesty International's Mobile Verification Toolkit
            """)
        }

        Section {
            Label("Orange dot at the top = an app is using the microphone", systemImage: "circle.fill").foregroundStyle(.orange)
            Label("Green dot = an app is using the camera", systemImage: "circle.fill").foregroundStyle(.green)
        } header: { Text("Microphone & camera") } footer: {
            Text("""
            iOS shows these dots for every app, and apps can't hide them. While a dot is showing, swipe down Control Center to see which app it is. Settings → Privacy & Security → App Privacy Report lists which apps used the microphone and camera over the last week.
            cellosig uses the microphone only during calls and while you record a voice note, and never uses the camera. (iOS doesn't let apps see what other apps are doing, so cellosig can't watch for that itself.)
            """)
        }

        Section {
            Button("Erase everything on this iPhone", role: .destructive) { confirmErase = true }
        } header: { Text("Emergency") } footer: {
            Text("Erases cellosig's keys, messages, files and settings from this iPhone at once. Your account on the relay stays; signing up again with your number starts fresh.")
        }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { model.eraseEverything() }
        } message: { Text("This can't be undone.") }
    }
}

/// Choose (or change) the cellosig password.
struct PasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String) -> Void
    @State private var first = ""
    @State private var second = ""

    private var problem: String? {
        if first.count < AppPassword.minLength { return "At least \(AppPassword.minLength) characters." }
        if !second.isEmpty && first != second { return "The two don't match." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $first).textContentType(.newPassword)
                    SecureField("Type it again", text: $second).textContentType(.newPassword)
                } footer: {
                    Text(problem ?? "There's no way to recover it: if you forget it, you'll have to erase cellosig and sign up again.")
                        .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("cellosig password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(first); dismiss() }.disabled(problem != nil || first != second)
                }
            }
        }
    }
}
