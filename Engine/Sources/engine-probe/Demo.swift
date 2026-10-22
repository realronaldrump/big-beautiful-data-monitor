import Foundation
import MonitorEngine
import UsageStore

/// Writes a month of plausible history to a scratch database, using apps installed on this Mac,
/// so the Day and Month views can be checked before real history exists. Never touches the real database.
func runDemo(path: String) {
    let url = URL(filePath: path)
    guard !FileManager.default.fileExists(atPath: url.path) else {
        print("\(url.path) already exists; pick a new path.")
        exit(1)
    }
    guard let database = try? UsageDatabase(url: url) else {
        print("Could not create \(url.path)")
        exit(1)
    }

    func app(_ path: String) -> AppIdentity? {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return AppIdentity(key: id, displayName: name, kind: .app, bundleID: id, bundlePath: path)
    }
    let safari = app("/Applications/Safari.app")
    let chrome = app("/Applications/Google Chrome.app")
    let music = app("/System/Applications/Music.app")
    let messages = app("/System/Applications/Messages.app")
    let facetime = app("/System/Applications/FaceTime.app")
    let claude = app("/Applications/Claude.app")
    let tv = app("/System/Applications/TV.app")
    let icloud = AppIdentity(key: "system.icloud", displayName: "iCloud", kind: .system, symbolName: "icloud")
    let updates = AppIdentity(key: "system.updates", displayName: "macOS updates", kind: .system, symbolName: "arrow.down.app")
    let notifications = AppIdentity(key: "system.notifications", displayName: "Notifications", kind: .system, symbolName: "bell")

    var random = SystemRandomNumberGenerator()
    func mb(_ range: ClosedRange<Double>) -> UInt64 { UInt64(Double.random(in: range, using: &random) * 1_000_000) }

    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    var batch: [MinuteSummary] = []
    for dayOffset in stride(from: 30, through: 0, by: -1) {
        let day = calendar.date(byAdding: .day, value: -dayOffset, to: today)!
        let weekend = calendar.isDateInWeekend(day)
        for hour in 0..<24 {
            var usage: [AppIdentity: ByteCounts] = [:]
            func add(_ identity: AppIdentity?, _ down: UInt64, _ up: UInt64 = 0) {
                guard let identity else { return }
                usage[identity, default: .zero] += ByteCounts(down: down, up: up)
            }
            let idle = hour < 7
            switch hour {
            case 1...4:
                add(icloud, mb(40...260), mb(20...120))
            case 8...17 where !weekend:
                add(chrome, mb(60...420), mb(5...40))
                add(claude, mb(4...30), mb(2...12))
                add(messages, mb(1...12), mb(1...6))
                if hour == 11 && dayOffset % 3 == 0 { add(facetime, mb(380...620), mb(300...480)) }
            case 9...18:
                add(safari, mb(80...500), mb(4...20))
                add(music, mb(20...70))
            case 19...23:
                add(safari, mb(120...700), mb(5...30))
                add(music, mb(30...90))
                if weekend || dayOffset % 4 == 1 { add(tv, mb(900...2_800), mb(5...15)) }
            default:
                break
            }
            if hour >= 7 { add(notifications, mb(0.2...2), mb(0.1...1)) }
            if dayOffset == 9 && hour == 14 { add(updates, mb(6_000...6_300), mb(2...6)) }
            guard !usage.isEmpty else { continue }

            // Spread the hour over a handful of minutes, stopping at the current time.
            let minutes = Array(0..<60).shuffled(using: &random).prefix(12)
            for minute in minutes {
                let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
                guard time < now.addingTimeInterval(-120) else { continue }
                var share: [AppIdentity: ByteCounts] = [:]
                for (identity, bytes) in usage { share[identity] = ByteCounts(down: bytes.down / 12, up: bytes.up / 12) }
                batch.append(MinuteSummary(minute: time, total: share.values.reduce(.zero, +), apps: share,
                                           network: dayOffset == 5 ? .hotspot : .wifi, idle: idle))
            }
        }
        if batch.count > 300 {
            try? database.save(batch)
            batch = []
        }
    }
    try? database.save(batch)
    print("Wrote a month of demo history to \(url.path)")
}
