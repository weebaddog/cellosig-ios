import SwiftUI

/// YouTube links get a card that opens the video in the YouTube app (or the
/// browser). Nothing plays inside cellosig, and nothing is fetched from
/// YouTube until you tap it — not even a thumbnail — so receiving a link
/// doesn't tell Google your IP address.
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

    var body: some View {
        if let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") {
            Link(destination: url) {
                Label("Open on YouTube", systemImage: "play.rectangle.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .foregroundStyle(tint)
        }
    }
}
