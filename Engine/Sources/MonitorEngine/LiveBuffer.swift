import Foundation

/// One second of the live buffer.
public struct LiveSample: Sendable {
    public let time: Date
    public let total: ByteCounts
    public let apps: [AppIdentity: ByteCounts]
}

/// The last 15 minutes at one-second resolution, in memory only.
/// Feeds the popover's live ribbon and the Now view.
public struct LiveBuffer: Sendable {
    public static let duration: TimeInterval = 15 * 60

    private var samples: [LiveSample] = []
    private var start = 0

    public init() {}

    public mutating func append(_ tick: UsageTick) {
        samples.append(LiveSample(time: tick.time, total: tick.total, apps: tick.apps))
        // Drop expired samples in batches rather than shifting the array every second.
        let cutoff = tick.time.addingTimeInterval(-Self.duration)
        while start < samples.count, samples[start].time <= cutoff { start += 1 }
        if start > 120 {
            samples.removeFirst(start)
            start = 0
        }
    }

    /// Samples from the last `seconds`, oldest first.
    public func recent(_ seconds: TimeInterval, now: Date = Date()) -> ArraySlice<LiveSample> {
        let cutoff = now.addingTimeInterval(-seconds)
        let first = samples[start...].firstIndex { $0.time > cutoff } ?? samples.endIndex
        return samples[first...]
    }

    /// Each app's bytes over the last `seconds`, busiest first.
    public func apps(over seconds: TimeInterval, now: Date = Date()) -> [(app: AppIdentity, bytes: ByteCounts)] {
        var totals: [AppIdentity: ByteCounts] = [:]
        for sample in recent(seconds, now: now) {
            for (app, bytes) in sample.apps { totals[app, default: .zero] += bytes }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.bytes.total > $1.bytes.total }
    }

    public var isEmpty: Bool { start == samples.count }
}
