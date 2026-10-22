import Foundation

/// One reconciled minute: apps plus "Mac system" add up exactly to the interface total.
public struct MinuteSummary: Sendable {
    public let minute: Date
    public let total: ByteCounts
    public let apps: [AppIdentity: ByteCounts]
    public let network: NetworkKind
    /// Nobody touched the keyboard or mouse during this minute.
    public let idle: Bool

    public init(minute: Date, total: ByteCounts, apps: [AppIdentity: ByteCounts], network: NetworkKind, idle: Bool) {
        self.minute = minute
        self.total = total
        self.apps = apps
        self.network = network
        self.idle = idle
    }
}

/// Collects ticks into minutes and reconciles each minute once it can no longer change.
///
/// `nettop` reports app bytes after the fact, covering a whole sampling interval (up to 10 s),
/// so app bytes are spread over the minutes their span covers, and a minute is only closed
/// once a grace period has passed.
public struct MinuteLedger: Sendable {
    private struct Bucket {
        var total = ByteCounts.zero
        var packets = PacketCounts.zero
        var apps: [AppIdentity: ByteCounts] = [:]
        var bytesByNetwork: [NetworkKind: UInt64] = [:]
        var lastNetwork: NetworkKind = .offline
        var idleAtEnd = false
    }

    private var buckets: [Date: Bucket] = [:]
    public var grace: TimeInterval

    public init(grace: TimeInterval = 15) {
        self.grace = grace
    }

    public static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// Adds a tick and returns any minutes that are now complete, oldest first.
    public mutating func add(_ tick: UsageTick) -> [MinuteSummary] {
        // The interface delta covers the second before the tick.
        let totalMinute = Self.minuteStart(tick.time.addingTimeInterval(-0.5))
        buckets[totalMinute, default: Bucket()].total += tick.total
        buckets[totalMinute, default: Bucket()].packets += tick.packets
        buckets[totalMinute, default: Bucket()].bytesByNetwork[tick.network, default: 0] += tick.total.total
        buckets[totalMinute, default: Bucket()].lastNetwork = tick.network
        buckets[totalMinute, default: Bucket()].idleAtEnd = tick.secondsSinceInput >= IdleClock.idleThreshold

        if !tick.apps.isEmpty {
            let span = tick.appSpan ?? DateInterval(start: tick.time, duration: 0)
            for (minute, fraction) in Self.split(span) {
                for (app, bytes) in tick.apps {
                    let share = ByteCounts(down: UInt64((Double(bytes.down) * fraction).rounded()),
                                           up: UInt64((Double(bytes.up) * fraction).rounded()))
                    buckets[minute, default: Bucket()].apps[app, default: .zero] += share
                }
            }
        }
        return close(before: tick.time.addingTimeInterval(-grace))
    }

    /// What the still-open minutes hold so far: the true total and the raw per-app split.
    public var unsaved: (total: ByteCounts, apps: [AppIdentity: ByteCounts]) {
        var total = ByteCounts.zero
        var apps: [AppIdentity: ByteCounts] = [:]
        for bucket in buckets.values {
            total += bucket.total
            for (app, bytes) in bucket.apps { apps[app, default: .zero] += bytes }
        }
        return (total, apps)
    }

    /// Closes every minute that ended before `cutoff` (or all of them, when flushing).
    public mutating func close(before cutoff: Date = .distantFuture) -> [MinuteSummary] {
        let ready = buckets.keys.filter { $0.addingTimeInterval(60) <= cutoff }.sorted()
        return ready.map { minute in
            let bucket = buckets.removeValue(forKey: minute)!
            return Self.summarize(minute: minute, bucket: bucket)
        }
    }

    private static func summarize(minute: Date, bucket: Bucket) -> MinuteSummary {
        var identities: [String: AppIdentity] = [AppIdentity.macSystem.key: .macSystem]
        for app in bucket.apps.keys { identities[app.key] = app }
        let result = Reconciler.reconcile(
            total: bucket.total,
            packets: bucket.packets,
            apps: Dictionary(bucket.apps.map { ($0.key.key, $0.value) }, uniquingKeysWith: +)
        )
        var apps: [AppIdentity: ByteCounts] = [:]
        for (key, bytes) in result.apps { apps[identities[key]!, default: .zero] += bytes }
        if !result.unexplained.isZero { apps[.macSystem, default: .zero] += result.unexplained }
        let network = bucket.bytesByNetwork.max { $0.value < $1.value }?.key ?? bucket.lastNetwork
        return MinuteSummary(minute: minute, total: bucket.total, apps: apps, network: network, idle: bucket.idleAtEnd)
    }

    /// The minutes a span touches, with the fraction of the span in each.
    static func split(_ span: DateInterval) -> [(Date, Double)] {
        guard span.duration > 0 else { return [(minuteStart(span.end), 1)] }
        var pieces: [(Date, Double)] = []
        var cursor = span.start
        while cursor < span.end {
            let minute = minuteStart(cursor)
            let end = min(span.end, minute.addingTimeInterval(60))
            pieces.append((minute, end.timeIntervalSince(cursor) / span.duration))
            cursor = end
        }
        return pieces
    }
}
