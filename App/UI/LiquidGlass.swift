import SwiftUI

/// Apple's Liquid Glass design (iOS 26+). Standard parts — navigation bars,
/// toolbars, menus, sheets, search, switches — take it on by themselves when
/// the app is built with the iOS 26 SDK; this is for cellosig's own floating
/// controls (the message bar, call buttons). Older iOS keeps the previous look.
enum Glass26 {
    static var on: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// Liquid Glass in `shape` on iOS 26+ (optionally tinted, e.g. the send button); a bar material before.
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        liquidGlass(in: shape, tint: tint, fallback: .bar)
    }

    /// Liquid Glass in `shape` on iOS 26+; `fallback` filling the shape before.
    @ViewBuilder
    func liquidGlass<S: Shape, F: ShapeStyle>(in shape: S, tint: Color? = nil, fallback: F) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(), in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}
