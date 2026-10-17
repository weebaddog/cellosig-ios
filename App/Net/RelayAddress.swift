import CellosigCore
import Foundation

/// The relay's current public address, as the relay announces it in pushes:
/// `r = {u: "wss://…", t: <ms>, s: <Ed25519 signature>}` over
/// "cellosig-relay\n<u>\n<t>", made with the same key that signs sender
/// certificates (which we already pinned). Replaces the Tor lookup the Android
/// app uses to follow the quick tunnel when it moves.
enum RelayAddress {
    private static let tsKey = "relay_url_ts"

    /// Verify and adopt it. Returns the new address if the account moved.
    static func accept(_ r: Any?) -> String? {
        guard let d = r as? [String: Any], let u = d["u"] as? String, let tNum = d["t"] as? NSNumber, let s = d["s"] as? String,
              let sig = try? Primitives.unb64(s),
              let key = Vault.shared.readSealed(Paths.keys.appendingPathComponent("relay_cert.bin")),
              let url = URL(string: u), url.scheme == "wss", url.host != nil
        else { return nil }
        let t = tNum.int64Value
        guard Primitives.verify(key, sig, Data("cellosig-relay\n\(u)\n\(t)".utf8)) else { return nil }
        return CrossProcessLock.run { () -> String? in
            // Only ever forward in time: an old (replayed) announcement can't move us back.
            let last = (Shared.defaults.object(forKey: tsKey) as? NSNumber)?.int64Value ?? 0
            guard t > last, var account = Account.load() else { return nil }
            Shared.defaults.set(NSNumber(value: t), forKey: tsKey)
            guard account.relayURL != u else { return nil }
            account.relayURL = u
            try? account.save()
            return u
        }
    }
}
