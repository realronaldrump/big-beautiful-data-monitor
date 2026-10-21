// Engine probe: prints live per-app usage every second, to prove the numbers before any design work.
//
//   engine-probe                 live view, refreshed every second
//   engine-probe --check         one-shot diagnostics: interfaces, nettop format, attribution of every process
//   engine-probe --duration 90   run for 90 seconds, then print a summary (for the accuracy check)
//   engine-probe --interval 10   sample apps every 10 seconds (the closed-window rate)
//   engine-probe --pids          show which processes rolled into each app
//   engine-probe --resolve 123   show which app a process ID is attributed to

import Foundation
import MonitorEngine

let arguments = CommandLine.arguments
func value(after flag: String) -> Int? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
}
let checkMode = arguments.contains("--check")
let showPIDs = arguments.contains("--pids")
let duration = value(after: "--duration")
let interval = value(after: "--interval") ?? 1
let interactive = isatty(STDOUT_FILENO) == 1 && duration == nil

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGINT) { _ in exit(0) }

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
    var network: NetworkKind = .offline

    init(interval: Int) {
        ledger = MinuteLedger(grace: Double(interval) + 3)
    }
}

nonisolated(unsafe) var liveEngine: UsageEngine?

func runLive() {
    let engine = UsageEngine(perAppInterval: interval)
    liveEngine = engine
    let state = LiveState(interval: interval)
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
    engine.onTick = { tick in
        state.total += tick.total
        state.lastSecondTotal = tick.total
        state.network = tick.network
        for (app, bytes) in tick.apps { state.apps[app, default: .zero] += bytes }
        if !tick.apps.isEmpty || interval == 1 { state.lastSecondApps = tick.apps }
        state.minutes += state.ledger.add(tick)
        let elapsed = Date().timeIntervalSince(state.started)
        if let duration, elapsed >= Double(duration) {
            state.minutes += state.ledger.close()
            printSummary(state)
            exit(0)
        }
        if interactive { render(state) } else { logLine(tick, state) }
    }
    engine.start()
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
    lines.append("Engine probe   \(clock.string(from: Date()))   \(networkName(state.network))   \(statusText(state.status))")
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

// MARK: - Main

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
