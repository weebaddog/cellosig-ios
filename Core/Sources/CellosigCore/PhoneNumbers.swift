import Foundation

/// E.164 helpers, same rules as the Android client's `PhoneNumbers.kt`.
public enum PhoneNumbers {
    public static func isE164(_ s: String) -> Bool {
        s.range(of: #"^\+[1-9]\d{6,14}$"#, options: .regularExpression) != nil
    }

    /// E.164 form of `raw`, or nil. Numbers without "+" are national numbers in `countryCode` (e.g. "1", "44").
    public static func normalize(_ raw: String, countryCode: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isASCIIDigit)
        let cc = countryCode.filter(\.isASCIIDigit)
        if digits.isEmpty { return nil }
        let candidate: String
        if trimmed.hasPrefix("+") { candidate = "+" + digits }
        else if digits.hasPrefix("00") { candidate = "+" + digits.dropFirst(2) }
        else if cc == "1" && digits.hasPrefix("011") { candidate = "+" + digits.dropFirst(3) }
        else if cc == "1" && digits.count == 11 && digits.hasPrefix("1") { candidate = "+" + digits }
        else if cc == "1" && digits.count == 10 { candidate = "+1" + digits }
        else if cc == "1" || cc.isEmpty { return nil }
        else { candidate = "+" + cc + (digits.hasPrefix("0") ? String(digits.dropFirst()) : digits) }
        return isE164(candidate) ? candidate : nil
    }

    /// For logs: "+15552340049" -> "+1•••••••49".
    public static func mask(_ p: String) -> String {
        p.count > 4 ? String(p.prefix(2)) + String(repeating: "•", count: p.count - 4) + String(p.suffix(2)) : "?"
    }

    /// "+15551234567" -> "+1 555-123-4567".
    public static func pretty(_ e164: String) -> String {
        guard e164.hasPrefix("+1"), e164.count == 12 else { return e164 }
        let n = Array(e164.dropFirst(2))
        return "+1 \(String(n[0..<3]))-\(String(n[3..<6]))-\(String(n[6...]))"
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Profile name cleaning, same rules as Android's `Profiles.cleanName`.
public enum Profiles {
    public static let maxName = 40
    public static let maxPhotoBytes = 96 * 1024

    public static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var out = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            if s.properties.isWhitespace { out.append(" "); continue }
            switch s.properties.generalCategory {
            case .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator:
                if s.value == 0x200D { out.append(s) } // keep emoji joiners
            default: out.append(s)
            }
        }
        var collapsed = String(out)
        while collapsed.contains("  ") { collapsed = collapsed.replacingOccurrences(of: "  ", with: " ") }
        collapsed = collapsed.trimmingCharacters(in: .whitespaces)
        if collapsed.isEmpty { return nil }
        let capped = String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maxName))).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    /// JPEG or PNG by magic bytes.
    public static func looksLikeImage(_ b: Data) -> Bool {
        let a = [UInt8](b.prefix(4))
        return (a.count > 2 && a[0] == 0xFF && a[1] == 0xD8 && a[2] == 0xFF) ||
            (a.count > 3 && a[0] == 0x89 && a[1] == 0x50 && a[2] == 0x4E && a[3] == 0x47)
    }
}
