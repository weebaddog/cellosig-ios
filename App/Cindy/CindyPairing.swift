import Foundation
import Security

/// What the PC's pairing QR code contains (the celloai://pair link the Cindy app scans too), one per app.
/// Kept in the Keychain (this device only): the token is this app's secret with the PC.
struct CindyPairing: Codable, Equatable {
    var hosts: [String]
    var port: Int
    var fingerprint: String
    var token: String
    var pcName: String
    var remote: String  // e.g. cindy.cellosig.com: Cloudflare tunnel to the PC, used away from home

    private static let service = "cindy.link.pairing"

    static func load() -> CindyPairing? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "pc", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(CindyPairing.self, from: d)
    }

    func save() {
        Self.clear()
        guard let d = try? JSONEncoder().encode(self) else { return }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                  kSecAttrAccount as String: "pc", kSecValueData as String: d,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "pc"]
        SecItemDelete(q as CFDictionary)
    }

    /// Only a plain DNS name is accepted as the remote address ("" = none).
    static func cleanRemote(_ name: String?) -> String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let ok = n.count <= 253 && n.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#,
                                           options: .regularExpression) != nil
        return ok ? n : ""
    }

    /// Parses celloai://pair?h=..&p=..&fp=..&t=..&n=..&r=..; nil if anything is off.
    static func parse(_ text: String) -> CindyPairing? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "celloai", c.host == "pair" else { return nil }
        func q(_ k: String) -> String? { c.queryItems?.first { $0.name == k }?.value }
        // only plain IPv4 addresses: they go straight into a wss:// URL
        let hosts = (q("h") ?? "").split(separator: ",").map(String.init)
            .filter { $0.range(of: #"^[0-9.]{7,15}$"#, options: .regularExpression) != nil }
        let remote = cleanRemote(q("r"))
        guard let port = Int(q("p") ?? ""), (1...65535).contains(port),
              let fp = q("fp")?.lowercased(), fp.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let token = q("t"), token.count >= 32, !(hosts.isEmpty && remote.isEmpty) else { return nil }
        return CindyPairing(hosts: hosts, port: port, fingerprint: fp, token: token, pcName: q("n") ?? "PC", remote: remote)
    }
}
