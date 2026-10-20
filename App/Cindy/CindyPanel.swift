import SwiftUI
import UIKit

/// The Cindy button floating over every screen while Cindy is switched on, and the chat panel it opens.
/// It lives in its own transparent window above the app (so it also floats over the app's sheets);
/// touches outside the button go straight through to the app. The button can be dragged out of the way.
final class CindyOverlay {
    static let shared = CindyOverlay()
    private var window: CindyWindow?
    private var observer: NSObjectProtocol?

    /// Shows or hides the overlay to match the Cindy switch.
    func update() {
        if !Cindy.shared.isOn || Cindy.shared.hidden {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            // not on screen yet: try again when the app's window shows up
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in self?.update() }
            }
            return
        }
        let w = CindyWindow(windowScene: scene)
        w.windowLevel = .normal + 1
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: CindyOverlayView(window: w))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }
}

/// Lets touches through except on Cindy's button, or anywhere while her panel is open.
final class CindyWindow: UIWindow {
    var hot: CGRect = .zero
    var open = false {
        didSet {
            if open {
                previousKey = windowScene?.windows.first { $0.isKeyWindow && $0 !== self }
                makeKey()  // so the text field can get the keyboard
            } else {
                previousKey?.makeKey()
                previousKey = nil
            }
        }
    }
    private weak var previousKey: UIWindow?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard open || hot.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct HotRect: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

private let accent = Color(red: 0.56, green: 0.36, blue: 0.97)

struct CindyOverlayView: View {
    let window: CindyWindow
    @ObservedObject private var cindy = Cindy.shared
    @State private var open = false
    @State private var offset = CGSize(width: UserDefaults.standard.double(forKey: "cindy.dx"),
                                       height: UserDefaults.standard.double(forKey: "cindy.dy"))
    @State private var drag = CGSize.zero

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if open {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { setOpen(false) }
                CindyChat(close: { setOpen(false) })
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                bubble
            }
        }
        .onPreferenceChange(HotRect.self) { window.hot = $0 }
        .animation(.spring(duration: 0.25), value: open)
    }

    private var bubble: some View {
        Text("C")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Circle().fill(LinearGradient(colors: [Color(red: 0.70, green: 0.42, blue: 1), Color(red: 0.42, green: 0.24, blue: 0.91)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(alignment: .topTrailing) {
                if cindy.thinking { Circle().fill(.green).frame(width: 12, height: 12).offset(x: 2, y: -2) }
            }
            .shadow(radius: 6, y: 3)
            .accessibilityLabel("Cindy")
            // where the button really is (the offset below moves it without changing its layout frame)
            .background(GeometryReader { g in
                Color.clear.preference(key: HotRect.self, value: g.frame(in: .global)
                    .offsetBy(dx: offset.width + drag.width, dy: offset.height + drag.height).insetBy(dx: -6, dy: -6))
            })
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .padding(.trailing, 16)
            .padding(.bottom, 110)
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    offset.width += v.translation.width
                    offset.height += v.translation.height
                    drag = .zero
                    UserDefaults.standard.set(offset.width, forKey: "cindy.dx")
                    UserDefaults.standard.set(offset.height, forKey: "cindy.dy")
                })
            .onTapGesture { setOpen(true) }
    }

    private func setOpen(_ on: Bool) {
        open = on
        window.open = on
        if !on { cindy.quiet() }
    }
}

/// The panel: what was said, Yes / No for her "Can I...?" questions, and a text box with a mic.
struct CindyChat: View {
    let close: () -> Void
    @ObservedObject private var cindy = Cindy.shared
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cindy").font(.headline)
                    Text(cindy.listening ? "Listening…" : cindy.thinking ? "Thinking…" : cindy.status)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Stop") { cindy.stop() }.font(.subheadline)
                Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                    .accessibilityLabel("Close")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if cindy.lines.isEmpty {
                            Text("Hi! I can do things in \(cindy.appName) for you, or anything else on your PC. Anything that sends, deletes or calls, I'll ask you first.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(cindy.lines) { line in
                            bubble(line).id(line.id)
                        }
                    }
                }
                .onChange(of: cindy.lines) { _, lines in
                    if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if cindy.asking != nil {
                HStack {
                    Spacer()
                    Button("No") { cindy.say("no") }.buttonStyle(.bordered)
                    Button("Yes") { cindy.say("yes") }.buttonStyle(.borderedProminent).tint(accent)
                }
            }
            HStack(spacing: 8) {
                TextField("Ask Cindy to do something in \(cindy.appName)", text: $text)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
                Button { cindy.tapMic() } label: {
                    Image(systemName: cindy.listening ? "stop.fill" : "mic.fill")
                        .foregroundStyle(.white).frame(width: 42, height: 42)
                        .background(Circle().fill(cindy.listening ? Color.red : accent))
                }
                .accessibilityLabel(cindy.listening ? "Stop listening" : "Talk to Cindy")
                Button(action: send) {
                    Image(systemName: "arrow.up").foregroundStyle(.white).frame(width: 42, height: 42)
                        .background(Circle().fill(accent))
                }
                .accessibilityLabel("Send")
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(height: UIScreen.main.bounds.height * 0.55)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.systemBackground)).shadow(radius: 12))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func bubble(_ line: Cindy.Line) -> some View {
        HStack {
            if line.who == .me { Spacer(minLength: 40) }
            Text(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(line.who == .note ? .footnote : .callout)
                .foregroundStyle(line.who == .note ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, line.who == .note ? 2 : 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16).fill(
                    line.who == .me ? accent.opacity(0.18) : line.who == .cindy ? Color(.secondarySystemBackground) : .clear))
            if line.who != .me { Spacer(minLength: 40) }
        }
    }

    private func send() {
        let t = text
        text = ""
        cindy.quiet()
        cindy.say(t)
    }
}

/// The "Cindy" switch for the app's Settings screen (put it inside a Form/List).
struct CindySettingsSection: View {
    @ObservedObject private var cindy = Cindy.shared
    @State private var pairing = false

    var body: some View {
        Section {
            Toggle("Cindy", isOn: Binding(get: { cindy.isOn }, set: { on in
                if !cindy.setOn(on) { pairing = true }
            }))
            if cindy.isOn {
                LabeledContent("Status", value: cindy.status)
            }
            if cindy.linked {
                Button("Unlink from the PC", role: .destructive) { cindy.unlink() }
            }
        } header: {
            Text("Cindy")
        } footer: {
            Text("Talk to Cindy, your assistant on your PC, from a button on every screen, and let her do things in \(cindy.appName) for you. She asks first before sending, deleting or calling. Off = she's cut off from \(cindy.appName). The first time, scan the code from Cindy on your PC (tray icon > Pair a phone or app).")
        }
        .sheet(isPresented: $pairing) {
            CindyPairingScanner { uri in
                if cindy.link(uri: uri) { pairing = false; return true }
                return false
            } cancel: { pairing = false }
        }
    }
}
