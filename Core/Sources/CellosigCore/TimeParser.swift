import Foundation

/// Finds a time in a message ("see you tomorrow at 5", "call me in 2 hours",
/// "dinner friday 7pm") for one-tap reminders. Runs entirely on the phone.
/// Same rules as the Android client's TimeParser: English phrases only, and it
/// only suggests — a wrong guess costs one tap.
public enum TimeParser {
    public struct Suggestion: Equatable {
        public let at: Date
        public let label: String
    }

    private static let unit = "(minutes?|mins?|hours?|hrs?|days?)"
    private static let time = #"(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#
    private static let day = "(today|tonight|tomorrow|tmrw|tmr|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thurs?|fri|sat|sun)"
    private static let inRe = re(#"\bin\s+(\d{1,3}|an?|one|two|three|half an?)\s*"# + unit + #"\b"#)
    private static let dayThenTime = re(#"\b(?:on\s+)?"# + day + #"\b(?:\s+(?:at\s+)?(?:"# + time + #"|(noon|midnight|morning|afternoon|evening|night)))?"#)
    private static let timeThenDay = re(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)\s+(?:on\s+)?"# + day + #"\b"#)
    private static let bareTime = re(#"\b(?:at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?|(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)|(noon|midnight))\b"#)

    private static func re(_ p: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    public static func find(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Suggestion? {
        guard let at = parse(text, now: now, calendar: calendar), at > now.addingTimeInterval(60) else { return nil }
        return Suggestion(at: at, label: label(at, now: now, calendar: calendar))
    }

    /// Groups of the first match ("" for a group that didn't take part, like Kotlin's groupValues).
    private static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let rg = m.range(at: i)
            return rg.location == NSNotFound ? "" : ns.substring(with: rg)
        }
    }

    public static func parse(_ text: String, now: Date, calendar cal: Calendar) -> Date? {
        if let g = match(inRe, text) {
            let q = g[1].lowercased(), u = g[2].lowercased()
            let n: Int
            switch q {
            case "a", "an", "one": n = 1
            case "two": n = 2
            case "three": n = 3
            default:
                if q.hasPrefix("half") { n = 0 } else { guard let v = Int(q) else { return nil }; n = v }
            }
            let at: Date?
            if q.hasPrefix("half") { at = cal.date(byAdding: .minute, value: 30, to: now) }
            else if u.hasPrefix("min") { at = cal.date(byAdding: .minute, value: n, to: now) }
            else if u.hasPrefix("h") { at = cal.date(byAdding: .hour, value: n, to: now) }
            else { at = cal.date(byAdding: .day, value: n, to: now).flatMap { setTime($0, 9, 0, cal) } }
            return at.flatMap { wholeMinute($0, cal) }
        }
        if let g = match(timeThenDay, text), let t = clock(g[1], g[2], g[3]) {
            return dayDate(g[4], now, cal).flatMap { setTime($0, t.h, t.m, cal) }.map { rollForward($0, now, g[4], cal) }
        }
        if let g = match(dayThenTime, text), let date = dayDate(g[1], now, cal) {
            let fallback: (h: Int, m: Int) = g[1].lowercased() == "tonight" ? (20, 0) : (9, 0)
            var t = clock(g[2], g[3], g[4]) ?? part(g[5]) ?? fallback
            // A day word with a time like "5" (no am/pm): "tomorrow at 5" means 5 pm for 1–7.
            if g[4].isEmpty && !g[2].isEmpty && (1...7).contains(t.h) { t.h += 12 }
            return setTime(date, t.h, t.m, cal).map { rollForward($0, now, g[1], cal) }
        }
        if let v = match(bareTime, text) {
            let t: (h: Int, m: Int)?
            if !v[7].isEmpty { t = part(v[7]) }
            else if !v[1].isEmpty {
                t = clock(v[1], v[2], v[3]).map { c in v[3].isEmpty && (1...7).contains(c.h) ? (h: c.h + 12, m: c.m) : c }
            } else { t = clock(v[4], v[5], v[6]) }
            guard let t, let today = setTime(now, t.h, t.m, cal) else { return nil }
            return today > now ? today : cal.date(byAdding: .day, value: 1, to: today)
        }
        return nil
    }

    private static func clock(_ h: String, _ m: String, _ ampm: String) -> (h: Int, m: Int)? {
        guard var hour = Int(h) else { return nil }
        let minute = Int(m) ?? 0
        let ap = ampm.lowercased().replacingOccurrences(of: ".", with: "")
        if hour > 23 || minute > 59 { return nil }
        if ap == "pm" && (1...11).contains(hour) { hour += 12 }
        if ap == "am" && hour == 12 { hour = 0 }
        return (hour, minute)
    }

    private static func part(_ word: String) -> (h: Int, m: Int)? {
        switch word.lowercased() {
        case "noon": return (12, 0)
        case "midnight": return (0, 0)
        case "morning": return (9, 0)
        case "afternoon": return (14, 0)
        case "evening", "night": return (19, 0)
        default: return nil
        }
    }

    private static func dayDate(_ word: String, _ now: Date, _ cal: Calendar) -> Date? {
        let today = cal.startOfDay(for: now)
        let w = word.lowercased()
        if w == "today" || w == "tonight" { return today }
        if w.hasPrefix("tom") || w == "tmrw" || w == "tmr" { return cal.date(byAdding: .day, value: 1, to: today) }
        guard let target = weekday(w) else { return nil }
        let diff = (target - cal.component(.weekday, from: today) + 7) % 7
        return cal.date(byAdding: .day, value: diff, to: today)
    }

    /// Calendar weekday number (Sunday = 1).
    private static func weekday(_ w: String) -> Int? {
        for (prefix, n) in [("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7)] where w.hasPrefix(prefix) {
            return n
        }
        return nil
    }

    /// "Friday 9am" said on a Friday at noon means next Friday.
    private static func rollForward(_ at: Date, _ now: Date, _ dayWord: String, _ cal: Calendar) -> Date {
        if at <= now, weekday(dayWord.lowercased()) != nil { return cal.date(byAdding: .day, value: 7, to: at) ?? at }
        return at
    }

    private static func setTime(_ d: Date, _ h: Int, _ m: Int, _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: h, minute: m, second: 0, of: d)
    }

    private static func wholeMinute(_ d: Date, _ cal: Calendar) -> Date? {
        cal.date(from: cal.dateComponents([.era, .year, .month, .day, .hour, .minute], from: d))
    }

    public static func label(_ at: Date, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        func fmt(_ p: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = cal
            f.timeZone = cal.timeZone
            f.dateFormat = p
            return f.string(from: at)
        }
        let time = fmt("h:mm a")
        let d = cal.startOfDay(for: at), today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: today, to: d).day ?? 0
        switch days {
        case 0: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case ..<7: return "\(fmt("EEEE")) \(time)"
        default: return "\(fmt("MMM d")) \(time)"
        }
    }
}
