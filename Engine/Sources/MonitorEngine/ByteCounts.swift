import Foundation

/// Bytes moved in each direction. "Down" is received, "up" is sent.
public struct ByteCounts: Sendable, Hashable, Codable {
    public var down: UInt64
    public var up: UInt64

    public static let zero = ByteCounts(down: 0, up: 0)

    public init(down: UInt64, up: UInt64) {
        self.down = down
        self.up = up
    }

    public var total: UInt64 { down &+ up }
    public var isZero: Bool { down == 0 && up == 0 }

    public static func + (lhs: ByteCounts, rhs: ByteCounts) -> ByteCounts {
        ByteCounts(down: lhs.down &+ rhs.down, up: lhs.up &+ rhs.up)
    }

    public static func += (lhs: inout ByteCounts, rhs: ByteCounts) {
        lhs = lhs + rhs
    }
}

/// Friendly units: KB, MB or GB (decimal, like Finder) with at most one decimal.
public enum FriendlyBytes {
    public static func format(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let (scaled, unit): (Double, String) =
            value >= 1e9 ? (value / 1e9, "GB") :
            value >= 1e6 ? (value / 1e6, "MB") :
            (value / 1e3, "KB")
        if bytes > 0 && scaled < 0.1 { return "0.1 \(unit)" }
        // One decimal only while it adds meaning (under 10), and never a trailing ".0".
        let rounded = scaled < 10 ? (scaled * 10).rounded() / 10 : scaled.rounded()
        if rounded == rounded.rounded() { return "\(Int(rounded)) \(unit)" }
        return String(format: "%.1f %@", rounded, unit)
    }

    public static func rate(_ bytesPerSecond: UInt64) -> String {
        format(bytesPerSecond) + "/s"
    }
}
