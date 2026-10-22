import AppKit

/// Picks an app's color from its own icon: the most prominent vivid hue, ignoring white,
/// black and gray. Icons with no real color get a calm gray drawn from the icon itself.
public enum IconColor {
    /// Soft neutral gray for system activity.
    public static let systemGray: UInt32 = 0x9A9AA0

    public static func dominant(forAppAt path: String) -> UInt32 {
        let image = NSWorkspace.shared.icon(forFile: path)
        let size = 48
        var proposed = NSRect(x: 0, y: 0, width: size, height: size)
        guard let icon = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return systemGray }
        context.draw(icon, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        let bins = 24
        var weights = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        var opaque = 0
        var plain = (r: 0.0, g: 0.0, b: 0.0)
        for index in 0..<(size * size) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.8 else { continue }
            let r = Double(pixels[index * 4]) / 255 / alpha
            let g = Double(pixels[index * 4 + 1]) / 255 / alpha
            let b = Double(pixels[index * 4 + 2]) / 255 / alpha
            opaque += 1
            plain = (plain.r + r, plain.g + g, plain.b + b)
            let (hue, saturation, brightness) = hsb(r, g, b)
            guard saturation > 0.3, brightness > 0.25 else { continue }
            // Vivid, bright pixels say the most about an icon's color.
            let weight = saturation * brightness
            let bin = min(bins - 1, Int(hue * Double(bins)))
            weights[bin] += weight
            sums[bin] = (sums[bin].r + r * weight, sums[bin].g + g * weight, sums[bin].b + b * weight)
        }
        guard opaque > 0 else { return systemGray }

        // A hue counts with half of each neighbor, so a gradient across two bins still wins.
        let scored = (0..<bins).map { weights[$0] + 0.5 * (weights[($0 + bins - 1) % bins] + weights[($0 + 1) % bins]) }
        let best = scored.indices.max { scored[$0] < scored[$1] }!
        let colorful = weights.reduce(0, +)
        guard colorful > Double(opaque) * 0.04, weights[best] > 0 else {
            // A monochrome icon: keep its own tone, kept in a calm middle range.
            let gray = min(0.7, max(0.4, (plain.r + plain.g + plain.b) / Double(3 * opaque)))
            return pack(gray, gray, gray * 1.03)
        }
        return pack(sums[best].r / weights[best], sums[best].g / weights[best], sums[best].b / weights[best])
    }

    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let high = max(r, g, b)
        let low = min(r, g, b)
        let delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Double
        if high == r { hue = (g - b) / delta } else if high == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / high, high)
    }

    static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func channel(_ value: Double) -> UInt32 { UInt32(min(255, max(0, (value * 255).rounded()))) }
        return channel(r) << 16 | channel(g) << 8 | channel(b)
    }
}
