import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets. They only read widget.json, which the
/// app writes (see ExtensionBridge): the unread count, and the latest chats
/// only when notification previews are on and App lock is off.
@main
struct CellosigWidgets: WidgetBundle {
    var body: some Widget {
        ChatsWidget()
        UnreadWidget()
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var data: WidgetData?
    /// No App Group in this install: the widget can't hear from the app at all.
    var unavailable = false
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, data: WidgetData(unread: 2, chats: [
            .init(id: "a", title: "Alex", text: "See you at 6!", ts: 0, unread: 1),
            .init(id: "b", title: "Family", text: "Photo", ts: 0, unread: 1),
        ], showContent: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    /// The app reloads the widget whenever this changes, so no schedule is needed.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> Entry {
        guard AppGroup.container != nil else { return Entry(date: .now, data: nil, unavailable: true) }
        return Entry(date: .now, data: SharedFiles.read(WidgetData.self, from: SharedFiles.widget))
    }
}

// MARK: - Chats (Home Screen)

struct ChatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "chats", provider: Provider()) { ChatsView(entry: $0) }
            .configurationDisplayName("cellosig")
            .description("Unread messages, and your latest chats when notification previews are on.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ChatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        content
            .containerBackground(for: .widget) { Color(.systemBackground) }
            .widgetURL(URL(string: "cellosig://open"))
    }

    @ViewBuilder private var content: some View {
        if entry.unavailable {
            message("Not available in this install", "Reinstall cellosig with an App Group to use widgets.")
        } else if let data = entry.data {
            if family == .systemSmall || !data.showContent || data.chats.isEmpty {
                summary(data)
            } else {
                list(data)
            }
        } else {
            message("cellosig", "Open the app once to set up the widget.")
        }
    }

    private func summary(_ data: WidgetData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer()
            Text("\(data.unread)").font(.system(size: 44, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
            Text(data.unread == 1 ? "unread message" : "unread messages").font(.caption).foregroundStyle(.secondary)
            if family == .systemSmall, data.showContent, let first = data.chats.first(where: { $0.unread > 0 }) {
                Text(first.title).font(.caption.bold()).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ data: WidgetData) -> some View {
        let rows = family == .systemLarge ? 6 : 3
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                header
                Spacer()
                if data.unread > 0 { badge(data.unread) }
            }
            ForEach(data.chats.prefix(rows)) { c in
                Link(destination: AppLinks.chat(c.id) ?? URL(string: "cellosig://open")!) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.subheadline.weight(c.unread > 0 ? .bold : .regular)).lineLimit(1)
                            Text(c.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if c.unread > 0 { badge(c.unread) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        Label("cellosig", systemImage: "lock.shield.fill").font(.caption.bold()).foregroundStyle(.tint)
    }

    private func badge(_ n: Int) -> some View {
        Text(n > 99 ? "99+" : "\(n)").font(.caption2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.blue))
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer()
            Text(title).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Unread (Lock Screen)

struct UnreadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "unread", provider: Provider()) { UnreadView(entry: $0) }
            .configurationDisplayName("Unread")
            .description("How many messages are waiting. Never shows who or what.")
            .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct UnreadView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let n = entry.data?.unread ?? 0
        Group {
            switch family {
            case .accessoryInline:
                Label(n == 0 ? "No new messages" : "\(n) new", systemImage: "bubble.left.fill")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("cellosig").font(.headline)
                    Text(n == 0 ? "No new messages" : n == 1 ? "1 new message" : "\(n) new messages")
                }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "bubble.left.fill").font(.caption)
                        Text("\(n)").font(.title3.bold()).minimumScaleFactor(0.5)
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "cellosig://open"))
    }
}
