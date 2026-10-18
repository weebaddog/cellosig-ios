import UIKit

/// Blocks screenshots (and screen recordings) of cellosig: what's captured is blank.
/// iOS has no switch for this, but it already keeps whatever is drawn inside a
/// password field out of screenshots; the whole window is drawn inside one.
/// On for the whole app (Settings), or only while a protected chat is open.
@MainActor
enum ScreenShield {
    static let key = "block_screenshots"

    /// Settings → Security: every screen of cellosig.
    static var everywhere: Bool { Shared.defaults.bool(forKey: key) }

    /// The chat on screen has "Block screenshots" on.
    static var chat = false { didSet { refresh() } }

    static var active: Bool { field?.isSecureTextEntry == true }

    private static var field: UITextField?

    static func refresh() {
        let on = everywhere || chat
        // Never touch the window until it's needed the first time.
        if !on && field == nil { return }
        if field == nil && !install() { return }
        if field?.isSecureTextEntry != on { field?.isSecureTextEntry = on }
    }

    private static func install() -> Bool {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let host = window.layer.superlayer else { return false }
        let f = UITextField(frame: .zero)
        f.isUserInteractionEnabled = false
        f.isSecureTextEntry = true
        window.addSubview(f)
        f.layoutIfNeeded()
        // The layer iOS keeps out of captures.
        guard let canvas = f.layer.sublayers?.last else { f.removeFromSuperview(); return false }
        host.addSublayer(f.layer)
        canvas.addSublayer(window.layer)
        field = f
        return true
    }
}
