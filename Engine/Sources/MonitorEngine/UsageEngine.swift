import Foundation

/// One second of live activity.
public struct UsageTick: Sendable {
    public let time: Date
    /// The true total for this second, from the interface counters.
    public let total: ByteCounts
    /// Packets on the physical interfaces this second, used to estimate header bytes.
    public let packets: PacketCounts
    /// Per-app bytes from any `nettop` sample that arrived during this second, before reconciling.
    public let apps: [AppIdentity: ByteCounts]
    /// Bytes seen in relays (proxies and VPN tunnels), which mostly repeat other apps' bytes.
    /// Kept apart: they only count toward what the apps cannot explain.
    public let relays: [AppIdentity: ByteCounts]
    /// The stretch of time those app bytes cover (one sampling interval). Nil when no sample arrived.
    public let appSpan: DateInterval?
    public let network: NetworkKind
    public let secondsSinceInput: TimeInterval
}

/// Ties the sources together and emits a `UsageTick` every second on its own queue:
/// interface counters for the true total, `nettop` for the per-app split, attribution,
/// network kind and idle time. All work happens off the main thread.
public final class UsageEngine: @unchecked Sendable {
    public var onTick: (@Sendable (UsageTick) -> Void)?
    public var onPerAppStatus: (@Sendable (NettopSampler.Status) -> Void)?
    /// Debug detail: every resolved `nettop` row, for the probe.
    public var onResolvedRows: (@Sendable ([(row: NettopRow, resolution: ProcessResolver.Resolution)]) -> Void)?

    public let resolver: ProcessResolver
    private let queue = DispatchQueue(label: "usage.engine", qos: .utility)
    private let sampler: NettopSampler
    private let network = NetworkKindMonitor()
    private var meter = InterfaceMeter()
    private var idle = IdleClock.Cached()
    private var timer: DispatchSourceTimer?
    private var pendingApps: [AppIdentity: ByteCounts] = [:]
    private var pendingRelays: [AppIdentity: ByteCounts] = [:]
    private var pendingSpan: DateInterval?
    private var lastSampleTime: Date?

    public init(perAppInterval: Int = 1, resolver: ProcessResolver = ProcessResolver()) {
        self.resolver = resolver
        sampler = NettopSampler(interval: perAppInterval, queue: queue)
        sampler.onSample = { [weak self] sample, time in self?.receive(sample, at: time) }
        sampler.onStatus = { [weak self] status in
            guard let self else { return }
            if status != .running { lastSampleTime = nil }
            onPerAppStatus?(status)
        }
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            // The meter keeps its last reading across stop and start, so bytes that moved while
            // asleep (Power Nap, iCloud) are counted in the first second after waking.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Generous leeway lets macOS batch this wakeup with others.
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        sampler.start()
    }

    /// Stops sampling and waits until no more ticks can arrive. Do not call from `onTick`.
    public func stop() {
        sampler.stop()
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            lastSampleTime = nil
            pendingApps = [:]
            pendingRelays = [:]
            pendingSpan = nil
        }
    }

    /// 1 s while something is on screen, 10 s otherwise (see the performance budget).
    public func setPerAppInterval(_ seconds: Int) {
        sampler.setInterval(seconds)
    }

    private func receive(_ sample: NettopSample, at time: Date) {
        // The first delta after a (re)start covers roughly one interval.
        let start = lastSampleTime ?? time.addingTimeInterval(-Double(sampler.interval))
        lastSampleTime = time
        var resolved: [(row: NettopRow, resolution: ProcessResolver.Resolution)] = []
        for row in sample.rows where !row.bytes.isZero {
            let resolution = resolver.resolve(pid: row.pid, nettopName: row.name)
            if resolution.isRelay {
                pendingRelays[resolution.identity, default: .zero] += row.bytes
            } else {
                pendingApps[resolution.identity, default: .zero] += row.bytes
            }
            resolved.append((row, resolution))
        }
        let span = DateInterval(start: start, end: max(start, time))
        pendingSpan = pendingSpan.map { DateInterval(start: min($0.start, span.start), end: max($0.end, span.end)) } ?? span
        onResolvedRows?(resolved)
    }

    private func tick() {
        let delta = meter.sample()
        let tick = UsageTick(
            time: Date(),
            total: delta.bytes,
            packets: delta.packets,
            apps: pendingApps,
            relays: pendingRelays,
            appSpan: pendingSpan,
            network: network.current,
            secondsSinceInput: idle.secondsSinceInput()
        )
        pendingApps = [:]
        pendingRelays = [:]
        pendingSpan = nil
        onTick?(tick)
    }
}
