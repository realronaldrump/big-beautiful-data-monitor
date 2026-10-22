import AppKit
import SwiftUI
import MonitorEngine
import UsageStore

/// Icons and colors for apps. Each color comes from the app's own icon, computed once
/// (and cached in the database); system groups are a soft neutral gray.
@MainActor
final class AppVisuals {
    private var icons: [String: NSImage] = [:]
    private var colors: [String: NSColor] = [:]

    func preload(_ records: [AppRecord]) {
        for record in records { cacheColor(record) }
    }

    func cacheColor(_ record: AppRecord) {
        guard colors[record.identity.key] == nil, let raw = record.iconColor else { return }
        colors[record.identity.key] = Self.displayColor(raw)
    }

    func nsColor(for identity: AppIdentity) -> NSColor {
        if let cached = colors[identity.key] { return cached }
        let raw = identity.kind == .app && identity.bundlePath != nil
            ? IconColor.dominant(forAppAt: identity.bundlePath!) : IconColor.systemGray
        let color = Self.displayColor(raw)
        colors[identity.key] = color
        return color
    }

    func color(for identity: AppIdentity) -> Color {
        Color(nsColor: nsColor(for: identity))
    }

    func color(forKey key: String?, in identities: [String: AppIdentity]) -> Color {
        guard let key, let identity = identities[key] else { return Color(nsColor: Self.displayColor(IconColor.systemGray)) }
        return color(for: identity)
    }

    /// The app's real icon, or nil for system groups (which use an SF Symbol).
    func icon(for identity: AppIdentity) -> NSImage? {
        guard identity.kind == .app, let path = identity.bundlePath else { return nil }
        if let cached = icons[identity.key] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[identity.key] = icon
        return icon
    }

    /// Icon colors tamed for tinting: never muddy, never neon, always readable in light and dark.
    static func displayColor(_ rgb: UInt32) -> NSColor {
        let raw = NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                          blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        raw.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.12 {
            return NSColor(hue: 0.66, saturation: 0.04, brightness: 0.62, alpha: 1)
        }
        return NSColor(hue: hue, saturation: min(0.78, max(0.42, saturation)), brightness: min(0.92, max(0.68, brightness)), alpha: 1)
    }
}

extension Color {
    /// The lighter shade of the same hue used for uploads.
    func uploadShade() -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: 0.45, of: .white) ?? NSColor(self))
    }
}
