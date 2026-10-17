import CellosigCore
import Contacts
import SwiftUI

/// Your iPhone's contacts, like on Android: names show for people in your
/// address book, and "Find friends" asks the relay which of their numbers use
/// cellosig. Only the numbers are ever sent to the relay (for that lookup);
/// names stay on the phone.
@MainActor
final class ContactBook: ObservableObject {
    static let shared = ContactBook()

    enum State: Equatable { case idle, needPermission, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    /// Contacts who use cellosig, sorted by name.
    @Published private(set) var onCellosig: [String] = []

    static var authorized: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), s == .limited { return true }
        return s == .authorized
    }

    /// Names only (no prompt, no relay lookup): for chat titles at startup.
    func loadNames(_ m: Messenger) {
        guard Self.authorized else { return }
        Task {
            let book = await Self.read(countryCode: Self.countryCode(m.me))
            Messenger.contactNames = book
            m.touch()
        }
    }

    /// Ask for access if needed, read the book, and find who's on cellosig.
    func discover(_ m: Messenger) async {
        if !Self.authorized {
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            guard granted else { state = .needPermission; return }
        }
        state = .loading
        let book = await Self.read(countryCode: Self.countryCode(m.me))
        Messenger.contactNames = book
        m.touch()
        guard m.connected else { state = .failed("Not connected to the relay. Try again in a moment."); return }
        let found = Set(await m.lookup(book.keys.filter { $0 != m.me }))
        onCellosig = book.filter { found.contains($0.key) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map(\.key)
        state = .ready
    }

    /// Your own country's calling code, for numbers saved without one.
    private static func countryCode(_ me: String) -> String {
        let digits = me.dropFirst()
        if digits.hasPrefix("1") || digits.hasPrefix("7") { return String(digits.prefix(1)) }
        return String(digits.prefix(2))
    }

    /// E.164 number -> name, read off the main thread.
    private static func read(countryCode: String) async -> [String: String] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: String] = [:]
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: req) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let shown = name.isEmpty ? c.organizationName : name
                guard !shown.isEmpty else { return }
                for n in c.phoneNumbers {
                    if let e164 = PhoneNumbers.normalize(n.value.stringValue, countryCode: countryCode), out[e164] == nil {
                        out[e164] = shown
                    }
                }
            }
            return out
        }.value
    }
}

/// "Contacts on cellosig" in the new-chat screen.
struct ContactsSection: View {
    @EnvironmentObject var m: Messenger
    @ObservedObject private var book = ContactBook.shared
    let pick: (String) -> Void

    var body: some View {
        Section {
            switch book.state {
            case .idle:
                Button { Task { await book.discover(m) } } label: { Label("Find friends in your contacts", systemImage: "person.crop.circle.badge.magnifyingglass") }
            case .needPermission:
                Text("cellosig isn't allowed to see your contacts. Allow it in Settings → cellosig → Contacts.").foregroundStyle(.secondary)
            case .loading:
                HStack { ProgressView(); Text("Checking your contacts…").foregroundStyle(.secondary) }
            case .failed(let why):
                Text(why).foregroundStyle(.secondary)
                Button("Try again") { Task { await book.discover(m) } }
            case .ready:
                if book.onCellosig.isEmpty {
                    Text("None of your contacts use cellosig yet.").foregroundStyle(.secondary)
                }
                ForEach(book.onCellosig, id: \.self) { p in
                    Button { pick(p) } label: {
                        HStack(spacing: 12) {
                            Avatar(conv: p, size: 34)
                            VStack(alignment: .leading) {
                                Text(m.displayName(p)).foregroundStyle(.primary)
                                Text(PhoneNumbers.pretty(p)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: { Text("Contacts on cellosig") } footer: {
            Text("Only phone numbers are sent to the relay to check; names stay on your iPhone.")
        }
        .onAppear { if book.state == .idle && ContactBook.authorized { Task { await book.discover(m) } } }
    }
}
