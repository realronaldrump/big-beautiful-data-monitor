// Engine probe: prints live per-app usage every second, to prove the numbers before any design work.
//
//   engine-probe                 live view, refreshed every second
//   engine-probe --check         one-shot diagnostics: interfaces, nettop format, attribution of every process
//   engine-probe --duration 90   run for 90 seconds, then print a summary (for the accuracy check)
//   engine-probe --interval 10   sample apps every 10 seconds (the closed-window rate)
//   engine-probe --pids          show which processes rolled into each app
//   engine-probe --resolve 123   show which app a process ID is attributed to
//   engine-probe --record        also save each minute to the app's database
//   engine-probe --report        print what the database holds: today, today by hour, this month
//   engine-probe --db PATH       use another database file (with --record or --report)
//   engine-probe --simulate-month PATH   fill a new database with a worst-case month and a year of hours
//   engine-probe --demo-db PATH  fill a new scratch database with a plausible month, for checking the design

import Foundation
import MonitorEngine
import UsageStore

let arguments = CommandLine.arguments
func value(after flag: String) -> Int? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
}
func string(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let checkMode = arguments.contains("--check")
let recordMode = arguments.contains("--record")
let databaseURL = string(after: "--db").map { URL(filePath: $0) } ?? UsageDatabase.defaultURL
let showPIDs = arguments.contains("--pids")
let duration = value(after: "--duration")
let interval = value(after: "--interval") ?? 1
let interactive = isatty(STDOUT_FILENO) == 1 && duration == nil

setvbuf(stdout, nil, _IOLBF, 0)

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
}
func lpad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}
func both(_ bytes: ByteCounts) -> String {
    "↓ \(lpad(FriendlyBytes.format(bytes.down), 7))  ↑ \(lpad(FriendlyBytes.format(bytes.up), 7))"
}
let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()


// MARK: - Live

final class LiveState: @unchecked Sendable {
    let started = Date()
    var total = ByteCounts.zero
    var apps: [AppIdentity: ByteCounts] = [:]
    var lastSecondApps: [AppIdentity: ByteCounts] = [:]
    var lastSecondTotal = ByteCounts.zero
    var pids: [AppIdentity: [String: ByteCounts]] = [:]
    var methods: [AppIdentity: Set<String>] = [:]
    var status: NettopSampler.Status = .stopped
    var ledger: MinuteLedger
    var minutes: [MinuteSummary] = []
    var savedMinutes = 0
    var network: NetworkKind = .offline

    init(interval: Int) {
        ledger = MinuteLedger(grace: Double(interval) + 3)
    }
}

nonisolated(unsafe) var liveEngine: UsageEngine?
nonisolated(unsafe) var liveRecorder: UsageRecorder?
nonisolated(unsafe) var signalSource: DispatchSourceSignal?

func runLive() {
    let engine = UsageEngine(perAppInterval: interval)
    liveEngine = engine
    let state = LiveState(interval: interval)
    if recordMode {
        do {
            liveRecorder = UsageRecorder(engine: engine, database: try UsageDatabase(url: databaseURL))
        } catch {
            print("Could not open the database at \(databaseURL.path): \(error)")
            exit(1)
        }
        liveRecorder?.onSaved = { minutes in state.savedMinutes += minutes.count }
        liveRecorder?.onError = { error in FileHandle.standardError.write(Data("storage error: \(error)\n".utf8)) }
    }
    // Control-C saves the minutes still in progress before quitting.
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler {
        liveRecorder?.stop()
        exit(0)
    }
    source.resume()
    signalSource = source
    #if DEBUG
    engine.resolver.logUnknown = { name in FileHandle.standardError.write(Data("unknown process → Mac system: \(name)\n".utf8)) }
    #endif
    engine.onPerAppStatus = { status in state.status = status }
    engine.onResolvedRows = { rows in
        for (row, resolution) in rows {
            state.pids[resolution.identity, default: [:]]["\(resolution.executableName) (\(row.pid))", default: .zero] += row.bytes
            state.methods[resolution.identity, default: []].insert(resolution.method.rawValue)
        }
    }
    let onTick: @Sendable (UsageTick) -> Void = { tick in
        state.total += tick.total
        state.lastSecondTotal = tick.total
        state.network = tick.network
        for (app, bytes) in tick.apps { state.apps[app, default: .zero] += bytes }
        if !tick.apps.isEmpty || interval == 1 { state.lastSecondApps = tick.apps }
        state.minutes += state.ledger.add(tick)
        let elapsed = Date().timeIntervalSince(state.started)
        if let duration, elapsed >= Double(duration) {
            state.minutes += state.ledger.close()
            liveRecorder?.flush()
            printSummary(state)
            if recordMode { print("\nSaved \(state.savedMinutes) minute(s) to \(databaseURL.path)") }
            exit(0)
        }
        if interactive { render(state) } else { logLine(tick, state) }
    }
    if let liveRecorder {
        liveRecorder.onTick = onTick
        liveRecorder.start()
    } else {
        engine.onTick = onTick
        engine.start()
    }
}

func networkName(_ kind: NetworkKind) -> String {
    switch kind {
    case .wifi: "Wi-Fi"
    case .wired: "Wired"
    case .hotspot: "iPhone hotspot"
    case .other: "Other network"
    case .offline: "Offline"
    }
}

func statusText(_ status: NettopSampler.Status) -> String {
    switch status {
    case .stopped: "starting"
    case .running: "per-app sampling every \(interval) s"
    case .restarting(let delay): "per-app sampler restarting in \(Int(delay)) s"
    case .unsupportedFormat(let header): "UNSUPPORTED nettop format: \(header)"
    }
}

func render(_ state: LiveState) {
    var lines: [String] = []
    let elapsed = Int(Date().timeIntervalSince(state.started))
    lines.append("Engine probe   \(clock.string(from: Date()))   \(networkName(state.network))   \(statusText(state.status))"
                 + (recordMode ? "   saving: \(state.savedMinutes) minute(s) saved" : ""))
    lines.append("")
    lines.append("This second  (true total)   \(both(state.lastSecondTotal))")
    lines.append("Since start  (\(elapsed / 60)m \(elapsed % 60)s)          \(both(state.total))")
    lines.append("")
    lines.append(pad("App", 28) + pad("last sample", 24) + pad("since start", 24) + "share of total")
    let appSum = state.apps.values.reduce(ByteCounts.zero, +)
    let rows = state.apps.sorted { $0.value.total > $1.value.total }.prefix(18)
    for (app, bytes) in rows {
        let last = state.lastSecondApps[app] ?? .zero
        let share = state.total.total > 0 ? Double(bytes.total) / Double(state.total.total) * 100 : 0
        lines.append(pad((app.kind == .system ? "· " : "") + app.displayName, 28) + pad(both(last), 24) + pad(both(bytes), 24) + String(format: "%5.1f%%", share))
        if showPIDs, let pids = state.pids[app] {
            for (label, pidBytes) in pids.sorted(by: { $0.value.total > $1.value.total }).prefix(4) {
                lines.append("      " + pad(label, 40) + both(pidBytes))
            }
        }
    }
    let gap = ByteCounts(down: state.total.down > appSum.down ? state.total.down - appSum.down : 0,
                         up: state.total.up > appSum.up ? state.total.up - appSum.up : 0)
    lines.append(pad("· unexplained (Mac system)", 28) + pad("", 24) + pad(both(gap), 24))
    lines.append("")
    let explained = state.total.total > 0 ? min(100, Double(appSum.total) / Double(state.total.total) * 100) : 0
    lines.append(String(format: "Apps explain %.1f%% of the true total so far (raw, before reconciling).", explained))
    if let minute = state.minutes.last {
        let sum = minute.apps.values.reduce(ByteCounts.zero, +)
        let matches = sum == minute.total ? "adds up exactly" : "MISMATCH"
        lines.append("Last closed minute \(clock.string(from: minute.minute).prefix(5)): total \(both(minute.total)) · apps + Mac system \(both(sum)) · \(matches)")
    }
    print("\u{1B}[H\u{1B}[2J" + lines.joined(separator: "\n"))
}

func logLine(_ tick: UsageTick, _ state: LiveState) {
    let top = tick.apps.sorted { $0.value.total > $1.value.total }.prefix(3)
        .map { "\($0.key.displayName) \(FriendlyBytes.format($0.value.down))" }
        .joined(separator: ", ")
    print("\(clock.string(from: tick.time))  total \(both(tick.total))  \(top)")
}

func printSummary(_ state: LiveState) {
    let elapsed = Date().timeIntervalSince(state.started)
    print("")
    print(String(format: "Summary after %.0f seconds on %@", elapsed, networkName(state.network)))
    print("True total (interface counters):  \(both(state.total))   exact: \(state.total.down) down, \(state.total.up) up")
    print("")
    print("Per app, raw from nettop:")
    for (app, bytes) in state.apps.sorted(by: { $0.value.total > $1.value.total }).prefix(15) {
        print("  " + pad(app.displayName, 30) + both(bytes) + "   exact: \(bytes.down) down" + "   via \(state.methods[app]?.sorted().joined(separator: ", ") ?? "")")
        if showPIDs, let pids = state.pids[app] {
            for (label, pidBytes) in pids.sorted(by: { $0.value.total > $1.value.total }).prefix(4) {
                print("      " + pad(label, 40) + both(pidBytes))
            }
        }
    }
    print("")
    var reconciled: [AppIdentity: ByteCounts] = [:]
    for minute in state.minutes { for (app, bytes) in minute.apps { reconciled[app, default: .zero] += bytes } }
    let reconciledTotal = state.minutes.reduce(ByteCounts.zero) { $0 + $1.total }
    print("Per app, reconciled (what the app will show; adds up to the true total):")
    for (app, bytes) in reconciled.sorted(by: { $0.value.total > $1.value.total }).prefix(10) {
        let share = reconciledTotal.total > 0 ? Double(bytes.total) / Double(reconciledTotal.total) * 100 : 0
        print("  " + pad(app.displayName, 30) + both(bytes) + String(format: "   %5.1f%%", share) + "   exact: \(bytes.down) down")
    }
    print("")
    print("Reconciled minutes (apps + Mac system must equal the true total):")
    for minute in state.minutes {
        let sum = minute.apps.values.reduce(ByteCounts.zero, +)
        let system = minute.apps[.macSystem] ?? .zero
        let share = minute.total.total > 0 ? Double(system.total) / Double(minute.total.total) * 100 : 0
        print("  \(clock.string(from: minute.minute).prefix(5))  total \(both(minute.total))  sum \(both(sum))  \(sum == minute.total ? "✓" : "✗")  Mac system \(String(format: "%.1f", share))%\(minute.idle ? "  idle" : "")")
    }
}

// MARK: - Check

func runCheck() {
    print("Responsibility function (responsibility_get_pid_responsible_for_pid): \(ProcessResolver.hasResponsibilityFunction ? "available" : "MISSING")")
    print("")
    print("Interfaces (64-bit counters from sysctl net.link.generic.ifdata):")
    for reading in InterfaceCounters.readAll() where !reading.bytes.isZero {
        let mark = InterfaceCounters.isPhysical(reading.name) ? "counted" : "skipped"
        print("  " + pad(reading.name, 10) + pad(mark, 9) + "lifetime ↓ \(reading.bytes.down)  ↑ \(reading.bytes.up)")
    }
    let network = NetworkKindMonitor()
    let idle = IdleClock.secondsSinceInput()
    let resolver = ProcessResolver()
    let sampler = NettopSampler(interval: 1)
    sampler.onStatus = { status in print("nettop: \(status)") }
    sampler.onSample = { sample, _ in
        sampler.stop()
        print("")
        print("Network type: \(networkName(network.current))     Seconds since last keyboard/mouse input: \(Int(idle))")
        print("")
        print("Attribution of every process nettop reported (\(sample.rows.count) rows):")
        var byMethod: [ProcessResolver.Method: Int] = [:]
        for row in sample.rows.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            let resolution = resolver.resolve(pid: row.pid, nettopName: row.name)
            byMethod[resolution.method, default: 0] += 1
            print("  " + pad("\(row.name).\(row.pid)", 30) + pad(resolution.executableName, 34) + "→ " + pad(resolution.identity.displayName, 26) + resolution.method.rawValue)
        }
        print("")
        print("By method: " + byMethod.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
        exit(0)
    }
    sampler.start()
}

// MARK: - Report

func runReport() {
    let database: UsageDatabase
    do { database = try UsageDatabase(url: databaseURL) } catch {
        print("Could not open the database at \(databaseURL.path): \(error)")
        exit(1)
    }
    let now = Date()
    let day = database.day(containing: now)
    let hourFormat = DateFormatter()
    hourFormat.dateFormat = "HH:mm"
    let dayFormat = DateFormatter()
    dayFormat.dateFormat = "EEE MMM d"
    do {
        print("Database: \(databaseURL.path)")
        print("File size: \(FriendlyBytes.format(UInt64(database.fileSize)))   first day: \(try database.firstDay().map(dayFormat.string(from:)) ?? "none yet")")
        print("")
        let total = try database.total(in: day)
        print("Today: \(FriendlyBytes.format(total.total))   (\(both(total)))")
        for usage in try database.apps(in: day).prefix(12) {
            let share = total.total > 0 ? Double(usage.bytes.total) / Double(total.total) * 100 : 0
            let color = usage.app.iconColor.map { String(format: "#%06X", $0) } ?? "–"
            print("  " + pad(usage.app.identity.displayName, 28) + both(usage.bytes) + String(format: "  %5.1f%%", share) + "   color \(color)")
        }
        print("")
        print("Today by hour (the Day ring's petals):")
        for hour in try database.hours(in: day) {
            print("  \(hourFormat.string(from: hour.hour))  " + lpad(FriendlyBytes.format(hour.total.total), 8) + "   top app: \(hour.topApp?.identity.displayName ?? "–")")
        }
        print("")
        print("This month by day (the Month calendar's circles):")
        for usage in try database.days(in: database.month(containing: now)) {
            print("  \(pad(dayFormat.string(from: usage.day), 12))" + lpad(FriendlyBytes.format(usage.total.total), 8) + (usage.usedHotspot ? "   hotspot" : ""))
        }
    } catch {
        print("Could not read the database: \(error)")
        exit(1)
    }
}

// MARK: - Size check

func runSimulation(path: String) {
    let url = URL(filePath: path)
    guard !FileManager.default.fileExists(atPath: url.path) else {
        print("\(url.path) already exists; pick a new path.")
        exit(1)
    }
    let database: UsageDatabase
    do { database = try UsageDatabase(url: url) } catch {
        print("Could not create \(url.path): \(error)")
        exit(1)
    }
    // The spec's upper bound: 25 apps active in every single minute.
    let apps = (1...25).map { AppIdentity(key: "sim.app\($0)", displayName: "App \($0)", kind: .system, symbolName: "app") }
    let end = MinuteLedger.minuteStart(Date())
    let started = Date()
    func minute(_ time: Date) -> MinuteSummary {
        var byApp: [AppIdentity: ByteCounts] = [:]
        for (index, app) in apps.enumerated() {
            byApp[app] = ByteCounts(down: UInt64.random(in: 1_000...50_000_000) / UInt64(index + 1), up: UInt64.random(in: 100...2_000_000))
        }
        return MinuteSummary(minute: time, total: byApp.values.reduce(.zero, +), apps: byApp, network: .wifi, idle: false)
    }
    do {
        // A year of hours (one busy minute per hour), then 30 days of every minute.
        var batch: [MinuteSummary] = []
        for hour in stride(from: 365 * 24, to: 30 * 24, by: -1) {
            batch.append(minute(end.addingTimeInterval(-Double(hour) * 3_600)))
            if batch.count >= 240 { try database.save(batch); batch = [] }
        }
        for offset in stride(from: 30 * 1_440, to: 0, by: -1) {
            batch.append(minute(end.addingTimeInterval(-Double(offset) * 60)))
            if batch.count >= 60 { try database.save(batch); batch = [] }
        }
        try database.save(batch)
        try database.runMaintenance(now: end)
    } catch {
        print("Simulation failed: \(error)")
        exit(1)
    }
    print(String(format: "Wrote a worst-case year in %.0f s.", Date().timeIntervalSince(started)))
    print("Data stored: \(FriendlyBytes.format(UInt64(database.dataSize)))   (file on disk: \(FriendlyBytes.format(UInt64(database.fileSize))))")
}

// MARK: - Main

if let path = string(after: "--demo-db") {
    runDemo(path: path)
    exit(0)
}
if let path = string(after: "--simulate-month") {
    runSimulation(path: path)
    exit(0)
}
if arguments.contains("--report") {
    runReport()
    exit(0)
}
if let pid = value(after: "--resolve") {
    let resolution = ProcessResolver().resolve(pid: pid_t(pid), nettopName: "")
    print("\(pid) \(resolution.executableName) → \(resolution.identity.displayName) (\(resolution.method.rawValue))")
    exit(0)
}
if checkMode {
    runCheck()
} else {
    runLive()
}
dispatchMain()
