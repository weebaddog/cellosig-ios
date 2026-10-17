import SwiftUI

/// Settings → App lock, Lockdown mode, Emergency (the same choices as on Android).
struct SecuritySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var lockError = false
    @State private var editingPassword = false
    @State private var confirmErase = false
    @State private var lockdown = Lockdown.on
    @State private var passwordSet = AppPassword.isSet

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
            Toggle("Lockdown mode", isOn: $lockdown)
                .onChange(of: lockdown) { Lockdown.on = $0; model.objectWillChange.send() }
        } header: { Text("Lockdown mode") } footer: {
            Text("""
            For when you may be targeted by spyware. cellosig then handles as little as possible of what others send until you ask:
            • nothing downloads automatically
            • pictures stay hidden until you tap them
            • only contacts whose safety number you verified can call you
            • with a cellosig password set, Face ID can't unlock the app (password only)
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
