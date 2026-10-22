import Foundation

/// Makes the per-app split add up to the true total.
///
/// The interface counters are the real number, and they include every packet's headers.
/// `nettop` counts what apps sent and received without those headers, misses very short-lived
/// processes, and can slightly over-count (traffic inside a VPN tunnel is seen inside and
/// outside it). So, for each direction:
/// - if apps add up to more than the total, they are scaled down proportionally;
/// - otherwise the gap is first explained as packet headers (estimated from the packet count),
///   shared among apps by how much each moved, since an app's downloads also cause the
///   acknowledgements sent back;
/// - relays (proxies and VPN tunnels, which resend other apps' traffic) then get whatever is
///   still unexplained, up to the bytes they moved, so relayed traffic is not counted twice;
/// - whatever is still unexplained is "Mac system".
public enum Reconciler {
    /// Average bytes of link, IP and TCP/UDP headers per packet. IPv4 TCP with timestamps is
    /// 66 bytes and IPv6 TCP 86; checked against real downloads on this Mac.
    public static let headerBytesPerPacket: UInt64 = 80

    public struct Result: Sendable, Equatable {
        public var apps: [String: ByteCounts]
        public var unexplained: ByteCounts
    }

    public static func reconcile(total: ByteCounts, packets: PacketCounts = .zero,
                                 apps: [String: ByteCounts], relays: [String: ByteCounts] = [:]) -> Result {
        let weights = apps.mapValues(\.total)
        let down = fit(apps.mapValues(\.down), into: total.down,
                       headers: packets.down &* headerBytesPerPacket, weights: weights)
        let up = fit(apps.mapValues(\.up), into: total.up,
                     headers: packets.up &* headerBytesPerPacket, weights: weights)
        let relayDown = fill(down.gap, from: relays.mapValues(\.down))
        let relayUp = fill(up.gap, from: relays.mapValues(\.up))
        var fitted: [String: ByteCounts] = [:]
        for key in Set(apps.keys).union(relays.keys) {
            let counts = ByteCounts(down: (down.values[key] ?? 0) + (relayDown.values[key] ?? 0),
                                    up: (up.values[key] ?? 0) + (relayUp.values[key] ?? 0))
            if !counts.isZero { fitted[key] = counts }
        }
        return Result(apps: fitted, unexplained: ByteCounts(down: relayDown.gap, up: relayUp.gap))
    }

    /// Gives relays as much of the unexplained gap as they moved themselves; returns what is left.
    static func fill(_ gap: UInt64, from relays: [String: UInt64]) -> (values: [String: UInt64], gap: UInt64) {
        let moved = relays.values.reduce(0, &+)
        guard gap > 0, moved > 0 else { return ([:], gap) }
        if moved <= gap { return (relays, gap - moved) }
        return (share(gap, by: relays), 0)
    }

    /// Returns the values fitted to the total and the unexplained remainder.
    static func fit(_ values: [String: UInt64], into total: UInt64, headers: UInt64,
                    weights: [String: UInt64]) -> (values: [String: UInt64], gap: UInt64) {
        let sum = values.values.reduce(0, &+)
        if sum > total {
            return (share(total, by: values), 0)
        }
        let gap = total - sum
        let explained = min(gap, headers)
        guard explained > 0, weights.values.contains(where: { $0 > 0 }) else { return (values, gap) }
        var result = values
        for (key, extra) in share(explained, by: weights) { result[key, default: 0] += extra }
        return (result, gap - explained)
    }

    /// Splits `amount` in proportion to `weights`, rounding so the parts add up exactly.
    static func share(_ amount: UInt64, by weights: [String: UInt64]) -> [String: UInt64] {
        let sum = weights.values.reduce(0, &+)
        guard sum > 0 else { return weights.mapValues { _ in 0 } }
        let scale = Double(amount) / Double(sum)
        var parts: [String: UInt64] = [:]
        var fractions: [(key: String, fraction: Double)] = []
        for (key, weight) in weights {
            let exact = Double(weight) * scale
            let floored = min(UInt64(exact.rounded(.down)), amount)
            parts[key] = floored
            fractions.append((key, exact - Double(floored)))
        }
        var leftover = amount - min(amount, parts.values.reduce(0, &+))
        for entry in fractions.sorted(by: { $0.fraction > $1.fraction }) where leftover > 0 {
            parts[entry.key]! += 1
            leftover -= 1
        }
        return parts
    }
}
