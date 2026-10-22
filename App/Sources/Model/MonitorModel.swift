import AppKit
import Observation
import OSLog
import MonitorEngine
import UsageStore

enum MainTab: String, CaseIterable, Identifiable {
    case now = "Now"
    case day = "Day"
    case month = "Month"
    var id: String { rawValue }
}

/// One second of the popover's live ribbon.
struct RibbonPoint: Sendable {
    let time: Date
    let down: Double
    let up: Double
    /// The app that moved the most around this second, for the ribbon's color.
    let colorKey: String?
}

/// An app moving data right now, with its recent rate in bytes per second.
struct LiveApp: Identifiable, Equatable {
    let identity: AppIdentity
    var down: Double
    var up: Double
    var lastActive: Date
    var id: String { identity.key }
    var rate: Double { down + up }
}

/// Everything the menu bar, popover and window show. Lives on the main thread; the engine,
/// recorder and database do their work on their own queues and are read once a second.
@MainActor @Observable
final class MonitorModel {
    // MARK: Live state

    private(set) var today = ByteCounts.zero
    /// Today per app (stored minutes plus the minute in progress), by app key.
    private(set) var todayByApp: [String: ByteCounts] = [:]
    /// Bytes not yet saved (the minute in progress); added to the current hour by the Day ring.
    private(set) var unsaved = ByteCounts.zero
    private(set) var ribbon: [RibbonPoint] = []
    private(set) var ribbonScale: Double = MonitorModel.ribbonFloor
    /// Apps moving data now, in a stable order (new arrivals join at the end).
    private(set) var liveApps: [LiveApp] = []
    private(set) var menuLevel: Double = 0
    private(set) var currentRate: Double = 0
    /// False when `nettop`'s format changed after a macOS update: totals still work, apps do not.
    private(set) var perAppAvailable = true
    /// Bumps after each saved minute and after a reset, so history views reload.
    private(set) var dataVersion = 0
    private(set) var identities: [String: AppIdentity] = [:]

    // MARK: Navigation

    var mainTab: MainTab = .now
    var shownDay = Date()
    var detailApp: AppIdentity?

    // MARK: Visibility (drives sampling rates and animation)

    var isPopoverOpen = false { didSet { visibilityChanged() } }
    var isWindowVisible = false { didSet { visibilityChanged() } }
    var isAnythingVisible: Bool { isPopoverOpen || isWindowVisible }

    // MARK: Settings (only three)

    var showSpeedInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showSpeedInMenuBar, forKey: "showSpeedInMenuBar")
            onMenuBarChange?()
        }
    }
    var opensAtLogin: Bool {
        didSet {
            guard opensAtLogin != LoginItem.isEnabled else { return }
            LoginItem.set(opensAtLogin)
            opensAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: Plumbing

    let recorder: UsageRecorder
    let database: UsageDatabase?
    let visuals = AppVisuals()
    var onMenuBarChange: (() -> Void)?

    static let allApps = AppIdentity(key: "system.all", displayName: "All apps", kind: .system, symbolName: "square.grid.2x2")
    static let ribbonFloor: Double = 60_000

    private var storedToday = ByteCounts.zero
    private var storedTodayByApp: [String: ByteCounts] = [:]
    private var storedDay: DateInterval?
    private var timer: Timer?
    private var slowDownItem: DispatchWorkItem?

    init() {
        var url = UsageDatabase.defaultURL
        #if DEBUG
        // Development builds can point at a scratch database: -databasePath /path/to/Usage.sqlite
        if let path = UserDefaults.standard.string(forKey: "databasePath") { url = URL(filePath: path) }
        #endif
        do {
            database = try UsageDatabase(url: url)
        } catch {
            // Degrade quietly: live numbers still work without history.
            Log.storage.error("Could not open the database at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            database = nil
        }
        recorder = UsageRecorder(engine: UsageEngine(perAppInterval: 10), database: database)
        showSpeedInMenuBar = UserDefaults.standard.bool(forKey: "showSpeedInMenuBar")
        opensAtLogin = LoginItem.isEnabled

        recorder.onSaved = { [weak self] _ in
            Task { @MainActor in self?.minutesSaved() }
        }
        recorder.engine.onPerAppStatus = { [weak self] status in
            let available: Bool
            if case .unsupportedFormat = status { available = false } else { available = true }
            Task { @MainActor in
                guard let self, self.perAppAvailable != available else { return }
                self.perAppAvailable = available
                self.onMenuBarChange?()
            }
        }
        #if DEBUG
        recorder.engine.resolver.logUnknown = { name in Log.engine.debug("Unknown process counted as Mac system: \(name, privacy: .public)") }
        #endif
        recorder.onError = { error in Log.storage.error("Storage error: \(String(describing: error), privacy: .public)") }
    }

    func start() {
        if let records = try? database?.allApps() {
            visuals.preload(records)
            for record in records { identities[record.identity.key] = record.identity }
        }
        reloadStored()
        recorder.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Generous tolerance lets macOS batch this wakeup with others.
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// On quit: stop sampling and save the minute in progress.
    func stop() {
        timer?.invalidate()
        recorder.stop()
    }

    /// The Mac is going to sleep: sampling stops (and the minute in progress is saved).
    func sleep() {
        recorder.stop()
    }

    func wake() {
        recorder.start()
        reloadStored()
    }

    func resetData() {
        try? database?.reset()
        storedToday = .zero
        storedTodayByApp = [:]
        dataVersion += 1
        reloadStored()
    }

    func identity(forKey key: String) -> AppIdentity? {
        identities[key]
    }

    /// The app behind most of today's data.
    var topAppToday: AppIdentity? {
        todayByApp.max { $0.value.total < $1.value.total }.flatMap { identities[$0.key] }
    }

    /// Runs a database query off the main thread.
    func query<T: Sendable>(_ body: @escaping @Sendable (UsageDatabase) throws -> T) async -> T? {
        guard let database else { return nil }
        return await Task.detached(priority: .userInitiated) { try? body(database) }.value
    }

    // MARK: - Every second

    private func tick() {
        let now = Date()
        let live = recorder.live

        // Menu bar: the wave eases toward the last couple of seconds' activity.
        let recent = live.recent(2.5, now: now)
        currentRate = recent.isEmpty ? 0 : Double(recent.reduce(0) { $0 + $1.total.total }) / Double(recent.count)
        menuLevel += (Self.level(forRate: currentRate) - menuLevel) * 0.45
        onMenuBarChange?()

        if storedDay?.contains(now) != true { reloadStored() }
        let pending = recorder.unsaved
        unsaved = pending.total
        today = storedToday + pending.total

        guard isAnythingVisible else { return }
        for (app, _) in pending.apps where identities[app.key] == nil { identities[app.key] = app }
        var byApp = storedTodayByApp
        for (app, bytes) in pending.apps { byApp[app.key, default: .zero] += bytes }
        todayByApp = byApp
        updateRibbon(live, now: now)
        updateLiveApps(live, now: now)
    }

    /// 0 when idle, about 0.6 at 1 MB/s, 1 at 50 MB/s: a log scale, so small activity still shows.
    static func level(forRate bytesPerSecond: Double) -> Double {
        min(1, max(0, log10(1 + bytesPerSecond / 1_000) / log10(1 + 50_000)))
    }

    private func updateRibbon(_ live: LiveBuffer, now: Date) {
        let samples = Array(live.recent(62, now: now))
        var points: [RibbonPoint] = []
        points.reserveCapacity(samples.count)
        // A per-app sample covers the seconds before it, so seconds without one take the color of the next one.
        var nextColor: String?
        var colors = [String?](repeating: nil, count: samples.count)
        for index in samples.indices.reversed() {
            if let top = samples[index].apps.max(by: { $0.value.total < $1.value.total })?.key { nextColor = top.key }
            colors[index] = nextColor
        }
        let firstKnown = colors.compactMap { $0 }.last
        for (index, sample) in samples.enumerated() {
            for app in sample.apps.keys where identities[app.key] == nil { identities[app.key] = app }
            points.append(RibbonPoint(time: sample.time, down: Double(sample.total.down), up: Double(sample.total.up),
                                      colorKey: perAppAvailable ? (colors[index] ?? firstKnown) : Self.allApps.key))
        }
        ribbon = points
        let peak = points.reduce(0) { max($0, $1.down, $1.up) }
        let target = max(Self.ribbonFloor, peak * 1.15)
        ribbonScale += (target - ribbonScale) * (target > ribbonScale ? 0.6 : 0.2)
    }

    private func updateLiveApps(_ live: LiveBuffer, now: Date) {
        let window: TimeInterval = 12
        guard perAppAvailable else {
            let total = live.recent(window, now: now).reduce(ByteCounts.zero) { $0 + $1.total }
            liveApps = total.isZero ? [] : [LiveApp(identity: Self.allApps, down: Double(total.down) / window,
                                                    up: Double(total.up) / window, lastActive: now)]
            return
        }
        let recent = Dictionary(live.apps(over: window, now: now).map { ($0.app.key, $0) }, uniquingKeysWith: { a, _ in a })
        var updated: [LiveApp] = []
        for var app in liveApps {
            let bytes = recent[app.id]?.bytes ?? .zero
            app.down = Double(bytes.down) / window
            app.up = Double(bytes.up) / window
            if bytes.total >= 2_000 { app.lastActive = now }
            // Linger a little after going quiet, so icons do not flicker in and out.
            if now.timeIntervalSince(app.lastActive) < 8 { updated.append(app) }
        }
        let present = Set(updated.map(\.id))
        for entry in live.apps(over: window, now: now) where entry.bytes.total >= 2_000 && !present.contains(entry.app.key) {
            updated.append(LiveApp(identity: entry.app, down: Double(entry.bytes.down) / window,
                                   up: Double(entry.bytes.up) / window, lastActive: now))
        }
        liveApps = updated
    }

    // MARK: - Stored totals

    private func minutesSaved() {
        reloadStored()
        dataVersion += 1
    }

    private func reloadStored() {
        guard let database else { return }
        let day = database.day(containing: Date())
        storedDay = day
        storedToday = (try? database.total(in: day)) ?? .zero
        var byApp: [String: ByteCounts] = [:]
        for usage in (try? database.apps(in: day)) ?? [] {
            byApp[usage.app.identity.key] = usage.bytes
            identities[usage.app.identity.key] = usage.app.identity
            visuals.cacheColor(usage.app)
        }
        storedTodayByApp = byApp
        today = storedToday + recorder.unsaved.total
    }

    // MARK: - Sampling rate

    /// Apps are sampled every second while anything is on screen, every 10 seconds otherwise.
    /// Slowing down waits a little, so quickly reopening the popover does not restart nettop twice.
    private func visibilityChanged() {
        slowDownItem?.cancel()
        if isAnythingVisible {
            recorder.engine.setPerAppInterval(1)
            tick()
        } else {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isAnythingVisible else { return }
                    self.recorder.engine.setPerAppInterval(10)
                }
            }
            slowDownItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
        }
    }
}

enum Log {
    static let storage = Logger(subsystem: "com.davisdeaton.BigBeautifulDataMonitor", category: "storage")
    static let engine = Logger(subsystem: "com.davisdeaton.BigBeautifulDataMonitor", category: "engine")
}
