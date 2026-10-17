import PhotosUI
import SwiftUI
import UIKit

/// Theme (light / dark / follow the phone), accent colour (your bubbles,
/// buttons) and chat wallpaper. Stays on this phone; nothing is sent.
enum Appearance {
    static let themes: [(id: String, name: String)] = [("system", "System"), ("light", "Light"), ("dark", "Dark")]

    static let accents: [(id: String, name: String, color: Color)] = [
        ("blue", "Blue", .blue), ("purple", "Purple", .purple), ("pink", "Pink", .pink), ("red", "Red", .red),
        ("orange", "Orange", .orange), ("green", "Green", .green), ("teal", "Teal", .teal),
        ("graphite", "Graphite", Color(white: 0.4)),
    ]

    static func scheme(_ id: String) -> ColorScheme? { id == "light" ? .light : id == "dark" ? .dark : nil }
    static func accent(_ id: String) -> Color { accents.first { $0.id == id }?.color ?? .blue }

    /// Wallpapers drawn in code (no image files), plus "none" and your own "photo".
    static let wallpapers: [(id: String, name: String)] = [
        ("none", "None"), ("sky", "Sky"), ("mint", "Mint"), ("sunset", "Sunset"), ("night", "Night"),
        ("dots", "Dots"), ("grid", "Grid"),
    ]
}

/// The wallpaper behind a chat. In dark mode the light ones are dimmed so bubbles stay readable.
struct ChatWallpaper: View {
    @AppStorage("wallpaper", store: Shared.defaults) private var chosen = "none"
    @AppStorage("wallpaper_version", store: Shared.defaults) private var version = 0
    @Environment(\.colorScheme) private var scheme
    /// Draw this one instead of the chosen one (the swatches in Settings).
    var preset: String? = nil

    var body: some View {
        let id = preset ?? chosen
        ZStack {
            switch id {
            case "sky": gradient([Color(red: 0.78, green: 0.89, blue: 1.0), Color(red: 0.88, green: 0.84, blue: 1.0)])
            case "mint": gradient([Color(red: 0.80, green: 0.96, blue: 0.89), Color(red: 0.70, green: 0.90, blue: 0.92)])
            case "sunset": gradient([Color(red: 1.0, green: 0.86, blue: 0.74), Color(red: 1.0, green: 0.77, blue: 0.84)])
            case "night": LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.22), Color(red: 0.22, green: 0.12, blue: 0.33)],
                                         startPoint: .top, endPoint: .bottom)
            case "dots": pattern(dots: true)
            case "grid": pattern(dots: false)
            case "photo":
                if let img = WallpaperPhoto.image(version: version) {
                    GeometryReader { g in
                        Image(uiImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                    }
                    if scheme == .dark { Color.black.opacity(0.35) }
                }
            default: Color.clear
            }
        }
    }

    private func gradient(_ colors: [Color]) -> some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if scheme == .dark { Color.black.opacity(0.62) }
        }
    }

    private func pattern(dots: Bool) -> some View {
        let ink = scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
        return Canvas { ctx, size in
            let step: CGFloat = dots ? 22 : 28
            if dots {
                var y: CGFloat = 0, row = 0
                while y < size.height + step {
                    var x: CGFloat = row % 2 == 0 ? 0 : step / 2
                    while x < size.width + step {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(ink))
                        x += step
                    }
                    y += step; row += 1
                }
            } else {
                var p = Path()
                var x: CGFloat = 0
                while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(p, with: .color(ink), lineWidth: 1)
            }
        }
        .background(Color(.systemBackground))
    }
}

/// Settings → Appearance.
struct AppearanceSection: View {
    @AppStorage("theme", store: Shared.defaults) private var theme = "system"
    @AppStorage("accent", store: Shared.defaults) private var accent = "blue"
    @AppStorage("wallpaper", store: Shared.defaults) private var wallpaper = "none"
    @AppStorage("wallpaper_version", store: Shared.defaults) private var wallpaperVersion = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var photoFailed = false

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $theme) {
                ForEach(Appearance.themes, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 8) {
                Text("Colour")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Appearance.accents, id: \.id) { a in accentButton(a.id, a.name, a.color) }
                    }
                    .padding(6)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat wallpaper")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Appearance.wallpapers, id: \.id) { w in swatch(w.id, w.name) }
                        if WallpaperPhoto.image(version: wallpaperVersion) != nil { swatch("photo", "Photo") }
                    }
                    .padding(4)
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(wallpaper == "photo" ? "Change photo…" : "Use a photo…", systemImage: "photo")
                }
                if photoFailed { Text("Couldn't use that picture.").font(.caption).foregroundStyle(.red) }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self), WallpaperPhoto.save(d) {
                    wallpaperVersion += 1
                    wallpaper = "photo"
                    photoFailed = false
                } else {
                    photoFailed = true
                }
                photoItem = nil
            }
        }
    }

    private func accentButton(_ id: String, _ name: String, _ color: Color) -> some View {
        Button { accent = id } label: {
            Circle().fill(color).frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.primary, lineWidth: accent == id ? 2.5 : 0).padding(-4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(accent == id ? .isSelected : [])
    }

    private func swatch(_ id: String, _ name: String) -> some View {
        Button { wallpaper = id } label: {
            VStack(spacing: 4) {
                ChatWallpaper(preset: id)
                    .frame(width: 54, height: 80)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(wallpaper == id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: wallpaper == id ? 2.5 : 1))
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(wallpaper == id ? .isSelected : [])
    }
}

/// Your own wallpaper photo: shrunk to at most 2048 px and kept in the app's protected storage.
enum WallpaperPhoto {
    private static var url: URL { Paths.root.appendingPathComponent("wallpaper.jpg") }
    private static var cached: (version: Int, image: UIImage)?

    static func image(version: Int) -> UIImage? {
        if let c = cached, c.version == version { return c.image }
        guard let d = try? Data(contentsOf: url), let img = UIImage(data: d) else { return nil }
        cached = (version, img)
        return img
    }

    static func save(_ data: Data) -> Bool {
        guard let img = ImageDecode.still(data, maxPixels: 2048), let jpeg = img.jpegData(compressionQuality: 0.85) else { return false }
        return (try? jpeg.write(to: url, options: [.atomic, .completeFileProtection])) != nil
    }

    static func remove() { try? FileManager.default.removeItem(at: url); cached = nil }
}
