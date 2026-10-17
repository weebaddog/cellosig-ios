import Foundation

/// Lockdown mode, for people who may be targeted by spyware (same as the
/// Android client): cellosig does as little as possible with what others send
/// until you ask it to.
///  - nothing is downloaded automatically;
///  - pictures aren't decoded until you tap them;
///  - only contacts whose safety number you verified can call you;
///  - no in-chat YouTube player (a web engine is a big attack surface);
///  - with a cellosig password set, Face ID can't unlock the app (nobody can
///    be forced to look at the phone).
enum Lockdown {
    static var on: Bool {
        get { Shared.defaults.bool(forKey: "lockdown") }
        set { Shared.defaults.set(newValue, forKey: "lockdown") }
    }
}
