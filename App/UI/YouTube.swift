import SwiftUI
import WebKit

/// YouTube links play inside the chat (as on Android). Privacy: NOTHING is
/// fetched from YouTube until you tap play — not even the thumbnail — so
/// receiving a link doesn't tell Google your IP address. Then it loads the
/// privacy-enhanced embed (youtube-nocookie.com) in a web view that keeps no
/// cookies or history and blocks ads, trackers and watch-history logging.
/// Off in Lockdown mode (a web engine is a big attack surface).
enum YouTubeLinks {
    private static let pattern = #"(?:https?://)?(?:www\.|m\.|music\.)?(?:youtube\.com/(?:watch\?(?:[^\s#]*&)?v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})"#

    /// The first YouTube video id in `text`, if any.
    static func find(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

struct YouTubeCard: View {
    let videoId: String
    var tint: Color = .primary
    @State private var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if playing && !Lockdown.on {
                    YouTubePlayer(videoId: videoId)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(Lockdown.on ? 0.4 : 1))
                        Text(Lockdown.on ? "YouTube video · no in-chat playback in Lockdown mode" : "YouTube video · tap to play")
                            .font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 8)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { if !Lockdown.on { playing = true } }
            HStack {
                Text("Loads from YouTube only when you press play.").font(.caption2).opacity(0.7)
                Spacer(minLength: 4)
                if let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") {
                    Link("Open", destination: url).font(.caption2.bold())
                }
            }
            .foregroundStyle(tint)
            .frame(width: 240)
        }
    }
}

/// The embedded player: a throwaway web view (no cookies, no history kept)
/// with ads and tracking blocked.
struct YouTubePlayer: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        AdBlock.apply(to: cfg.userContentController) {
            // Rules first, then load: nothing slips through before they're in place.
            // The embed refuses to play for a page with no origin; give it the embed's own.
            web.loadHTMLString(Self.page(videoId), baseURL: URL(string: "https://www.youtube-nocookie.com/"))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: ()) {
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)   // stop the audio when the bubble scrolls away
    }

    private static func page(_ id: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&modestbranding=1"
        allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
    }
}

/// Requests the player may not make: ad networks, analytics, and YouTube's
/// ad and watch-history pings (the same list as Android's AdBlock, as WebKit
/// content-blocking rules).
enum AdBlock {
    private static let blocked = [
        #"doubleclick\.net"#, #"googlesyndication\.com"#, #"googleadservices\.com"#, #"google-analytics\.com"#,
        #"googletagmanager\.com"#, #"googletagservices\.com"#, #"adservice\.google\."#, #"imasdk\.googleapis\.com"#,
        #"youtube[a-z-]*\.com/api/stats/"#, #"youtube[a-z-]*\.com/pagead/"#, #"youtube[a-z-]*\.com/ptracking"#,
        #"youtube[a-z-]*\.com/get_midroll_"#, #"youtube[a-z-]*\.com/youtubei/v1/log_event"#, #"/generate_204"#,
    ]

    private static var compiled: WKContentRuleList?

    static func apply(to controller: WKUserContentController, then load: @escaping () -> Void) {
        if let compiled { controller.add(compiled); load(); return }
        let rules = blocked.map { #"{"trigger":{"url-filter":"\#($0.replacingOccurrences(of: "\\", with: "\\\\"))"},"action":{"type":"block"}}"# }
        let json = "[" + rules.joined(separator: ",")
            + #",{"trigger":{"url-filter":".*","load-type":["third-party"],"resource-type":["raw"]},"action":{"type":"block-cookies"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cellosig-adblock", encodedContentRuleList: json) { list, _ in
            DispatchQueue.main.async {
                if let list { compiled = list; controller.add(list) }
                load()
            }
        }
    }
}
