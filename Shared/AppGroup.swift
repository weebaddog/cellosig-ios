import Foundation

/// The App Group the app shares with its extensions (widget, share sheet,
/// notification service).
///
/// The real build uses group.com.cellosig.app. A sideloaded copy is signed by
/// whoever installs it, and the signing tool may rename the group (it must be
/// unique to that Apple ID), so the actual name is read from this bundle's
/// provisioning profile when there is one. App Store / TestFlight builds have
/// no embedded profile and use the fixed name.
enum AppGroup {
    static let standard = "group.com.cellosig.app"

    static let id: String = fromProvisioningProfile() ?? standard

    /// The shared container, or nil when this install has no App Group
    /// (e.g. sideloaded without one): then nothing can be shared.
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }

    private static func fromProvisioningProfile() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // A CMS envelope around a plain XML plist: just cut the plist out.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return nil }
        return groups.first
    }
}
