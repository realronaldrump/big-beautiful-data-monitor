import Foundation
import GRDB
import Testing
@testable import MonitorEngine
@testable import UsageStore

let safari = AppIdentity(key: "com.apple.Safari", displayName: "Safari", kind: .app,
                         bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app")
let chrome = AppIdentity(key: "com.google.Chrome", displayName: "Google Chrome", kind: .app, bundleID: "com.google.Chrome")

func summary(_ minute: Date, _ apps: [AppIdentity: ByteCounts], network: NetworkKind = .wifi, idle: Bool = false) -> MinuteSummary {
    MinuteSummary(minute: minute, total: apps.values.reduce(.zero, +), apps: apps, network: network, idle: idle)
}

func pacific() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    return calendar
}

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "bbdm-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "Usage.sqlite")
}

@Suite struct StorageTests {
    let calendar = pacific()
    var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    @Test func savesMinutesAndAnswersDayQueries() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([
            summary(noon, [safari: ByteCounts(down: 1_000, up: 100), chrome: ByteCounts(down: 50, up: 5)]),
            summary(noon.addingTimeInterval(60), [safari: ByteCounts(down: 2_000, up: 200)]),
            summary(noon.addingTimeInterval(3_600), [chrome: ByteCounts(down: 9_000, up: 0)]),
        ])
        let day = db.day(containing: noon)
        #expect(try db.total(in: day) == ByteCounts(down: 12_050, up: 305))

        let apps = try db.apps(in: day)
        #expect(apps.map(\.app.identity.key) == [chrome.key, safari.key])
        #expect(apps[1].bytes == ByteCounts(down: 3_000, up: 300))

        let hours = try db.hours(in: day)
        #expect(hours.count == 2)
        #expect(hours[0].hour == noon)
        #expect(hours[0].topApp?.identity.key == safari.key)
        #expect(hours[1].topApp?.identity.key == chrome.key)

        let safariID = try #require(try db.app(withKey: safari.key)).id
        #expect(try db.usage(ofApp: safariID, in: day) == ByteCounts(down: 3_000, up: 300))
        #expect(try db.hours(ofApp: safariID, in: day) == [noon: ByteCounts(down: 3_000, up: 300)])
    }

    @Test func hourlyRowsAlwaysEqualTheMinutesTheyHold() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        var minutes: [MinuteSummary] = []
        for index in 0..<180 {
            minutes.append(summary(noon.addingTimeInterval(Double(index) * 60),
                                   [safari: ByteCounts(down: UInt64(index * 7), up: 3), chrome: ByteCounts(down: 11, up: UInt64(index))]))
        }
        try db.save(minutes)
        let (minuteSum, hourSum) = try db.read { db in
            (try Row.fetchOne(db, sql: "SELECT sum(bytes_down) AS down, sum(bytes_up) AS up FROM usage_minute")!,
             try Row.fetchOne(db, sql: "SELECT sum(bytes_down) AS down, sum(bytes_up) AS up FROM usage_hour")!)
        }
        #expect(ByteCounts(minuteSum) == ByteCounts(hourSum))
        #expect(try db.hours(in: db.day(containing: noon)).count == 3)
    }

    @Test func aMinuteSavedInTwoPiecesAddsUp() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(noon, [safari: ByteCounts(down: 100, up: 10)], idle: true)])
        try db.save([summary(noon, [safari: ByteCounts(down: 50, up: 5)], idle: false)])
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT bytes_down AS down, bytes_up AS up, idle FROM total_minute")! }
        #expect(ByteCounts(row) == ByteCounts(down: 150, up: 15))
        #expect(row["idle"] as Int == 0)
    }

    @Test func idleBytesAreKeptPerHour() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(noon, [safari: ByteCounts(down: 700, up: 0)], idle: true),
                     summary(noon.addingTimeInterval(60), [safari: ByteCounts(down: 300, up: 0)], idle: false)])
        let row = try db.read { try Row.fetchOne($0, sql: "SELECT idle_down, idle_minutes FROM total_hour")! }
        #expect(row["idle_down"] as Int64 == 700)
        #expect(row["idle_minutes"] as Int == 1)
    }

    @Test func maintenanceTrimsOldMinutesButKeepsHours() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        let old = noon.addingTimeInterval(-40 * 24 * 3600)
        try db.save([summary(old, [safari: ByteCounts(down: 500, up: 0)]), summary(noon, [safari: ByteCounts(down: 1, up: 0)])])
        try db.runMaintenance(now: noon)
        let minuteRows = try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM usage_minute")! }
        #expect(minuteRows == 1)
        #expect(try db.total(in: db.day(containing: old)) == ByteCounts(down: 500, up: 0))
        #expect(try db.apps(in: db.day(containing: old)).first?.bytes == ByteCounts(down: 500, up: 0))
    }

    @Test func daysSplitAtLocalMidnightEvenWithHalfHourTimeZones() throws {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let db = try UsageDatabase(inMemoryWith: india)
        let beforeMidnight = india.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 59))!
        let afterMidnight = beforeMidnight.addingTimeInterval(60)
        try db.save([summary(beforeMidnight, [safari: ByteCounts(down: 10, up: 0)], network: .hotspot),
                     summary(afterMidnight, [safari: ByteCounts(down: 20, up: 0)])])
        let days = try db.days(in: db.month(containing: beforeMidnight))
        #expect(days.map(\.total.down) == [10, 20])
        #expect(days.map(\.usedHotspot) == [true, false])
        #expect(days[1].day == india.startOfDay(for: afterMidnight))
    }

    @Test func busiestPartOfDayWaitsForAWeekOfData() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 20))!
        try db.save([summary(evening, [safari: ByteCounts(down: 5_000, up: 0)])])
        let safariID = try #require(try db.app(withKey: safari.key)).id
        #expect(try db.busiestPartOfDay(forApp: safariID, now: evening.addingTimeInterval(3 * 24 * 3600)) == nil)
        for day in 1...8 {
            let morning = evening.addingTimeInterval(Double(day) * 24 * 3600 - 11 * 3600)
            try db.save([summary(evening.addingTimeInterval(Double(day) * 24 * 3600), [safari: ByteCounts(down: 5_000, up: 0)]),
                         summary(morning, [safari: ByteCounts(down: 100, up: 0)])])
        }
        #expect(try db.busiestPartOfDay(forApp: safariID, now: evening.addingTimeInterval(9 * 24 * 3600)) == .evening)
    }

    @Test func resetEmptiesEverything() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(noon, [safari: ByteCounts(down: 1, up: 1)])])
        try db.reset()
        #expect(try db.total(in: db.day(containing: noon)) == .zero)
        #expect(try db.app(withKey: safari.key) == nil)
        try db.save([summary(noon, [safari: ByteCounts(down: 2, up: 0)])])
        #expect(try db.total(in: db.day(containing: noon)) == ByteCounts(down: 2, up: 0))
    }

    @Test func aCorruptFileIsSetAsideAndAFreshOneStarted() throws {
        let url = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8_192).write(to: url)
        let db = try UsageDatabase(url: url, calendar: calendar)
        try db.save([summary(noon, [safari: ByteCounts(down: 42, up: 0)])])
        #expect(try db.total(in: db.day(containing: noon)) == ByteCounts(down: 42, up: 0))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("Usage.sqlite.corrupt-") })
    }

    @Test func aFileOnDiskSurvivesReopening() throws {
        let url = temporaryDatabaseURL()
        do {
            let db = try UsageDatabase(url: url, calendar: calendar)
            try db.save([summary(noon, [safari: ByteCounts(down: 7, up: 0)])])
        }
        let reopened = try UsageDatabase(url: url, calendar: calendar)
        #expect(try reopened.total(in: reopened.day(containing: noon)) == ByteCounts(down: 7, up: 0))
        #expect(reopened.fileSize > 0)
    }
}

@Suite struct IconColorTests {
    func hue(_ color: UInt32) -> Double {
        IconColor.hsb(Double(color >> 16 & 0xFF) / 255, Double(color >> 8 & 0xFF) / 255, Double(color & 0xFF) / 255).hue * 360
    }

    @Test func safariIsBlue() {
        let color = IconColor.dominant(forAppAt: "/Applications/Safari.app")
        #expect((180...250).contains(hue(color)), "Safari came out as #\(String(color, radix: 16))")
    }

    @Test func messagesIsGreen() {
        let color = IconColor.dominant(forAppAt: "/System/Applications/Messages.app")
        #expect((90...160).contains(hue(color)), "Messages came out as #\(String(color, radix: 16))")
    }

    @Test func colorsAreCachedWithTheApp() throws {
        let db = try UsageDatabase(inMemoryWith: pacific())
        try db.save([summary(Date(), [safari: ByteCounts(down: 1, up: 0), .macSystem: ByteCounts(down: 1, up: 0)])])
        #expect(try db.app(withKey: safari.key)?.iconColor != nil)
        #expect(try db.app(withKey: AppIdentity.macSystem.key)?.iconColor == IconColor.systemGray)
    }
}

@Suite struct LiveBufferTests {
    @Test func keepsFifteenMinutesAtOneSecond() {
        var buffer = LiveBuffer()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in 0..<1_200 {
            buffer.append(UsageTick(time: start.addingTimeInterval(Double(second)), total: ByteCounts(down: 1, up: 0), packets: .zero,
                                    apps: second % 2 == 0 ? [safari: ByteCounts(down: 10, up: 0)] : [:],
                                    appSpan: nil, network: .wifi, secondsSinceInput: 0))
        }
        let now = start.addingTimeInterval(1_199)
        #expect(buffer.recent(60, now: now).count == 60)
        #expect(buffer.recent(3_600, now: now).count == 900)
        #expect(buffer.apps(over: 10, now: now).first?.bytes == ByteCounts(down: 50, up: 0))
    }
}

@Suite struct MomentTests {
    let calendar = pacific()
    var day: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))! }
    let updates = AppIdentity(key: "system.updates", displayName: "macOS updates", kind: .system, symbolName: "arrow.down.app")
    let icloud = AppIdentity(key: "system.icloud", displayName: "iCloud", kind: .system, symbolName: "icloud")

    @Test func explainsTheBiggestSpike() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        var minutes: [MinuteSummary] = []
        for hour in 8..<20 { minutes.append(summary(day.addingTimeInterval(Double(hour) * 3600), [safari: ByteCounts(down: 20_000_000, up: 0)])) }
        minutes.append(summary(day.addingTimeInterval(14 * 3600 + 60), [updates: ByteCounts(down: 6_100_000_000, up: 0)]))
        try db.save(minutes)
        let spike = try #require(try db.spikeMoment(db.day(containing: day)))
        #expect(spike.text == "6.1 GB · macOS updates · 2 PM")
        #expect(spike.app?.identity.key == updates.key)
    }

    @Test func noSpikeOnAnEvenDay() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save((8..<20).map { summary(day.addingTimeInterval(Double($0) * 3600), [safari: ByteCounts(down: 150_000_000, up: 0)]) })
        #expect(try db.spikeMoment(db.day(containing: day)) == nil)
    }

    @Test func saysWhatMovedWhileAway() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(day.addingTimeInterval(3 * 3600), [icloud: ByteCounts(down: 900_000_000, up: 300_000_000)], idle: true),
                     summary(day.addingTimeInterval(3 * 3600 + 60), [safari: ByteCounts(down: 50_000_000, up: 0)], idle: true),
                     summary(day.addingTimeInterval(10 * 3600), [safari: ByteCounts(down: 2_000_000_000, up: 0)], idle: false)])
        let away = try #require(try db.awayMoment(db.day(containing: day)))
        #expect(away.text == "While you were away: 1.3 GB, mostly iCloud")
    }

    @Test func comparesToTheSameWeekday() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        var minutes: [MinuteSummary] = []
        for weeks in 1...3 {
            minutes.append(summary(day.addingTimeInterval(Double(-7 * weeks) * 86_400 + 10 * 3600), [safari: ByteCounts(down: 1_000_000_000, up: 0)]))
        }
        minutes.append(summary(day.addingTimeInterval(10 * 3600), [safari: ByteCounts(down: 2_100_000_000, up: 0)]))
        try db.save(minutes)
        let endOfDay = day.addingTimeInterval(86_399)
        let usual = try #require(try db.usualMoment(db.day(containing: day), now: endOfDay.addingTimeInterval(86_400)))
        #expect(usual.text == "Twice your usual")
        #expect(UsageDatabase.comparison(1.05, noun: "Wednesday") == "About a normal Wednesday")
    }

    @Test func atMostThreeMoments() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(day.addingTimeInterval(3 * 3600), [icloud: ByteCounts(down: 900_000_000, up: 0)], idle: true)])
        #expect(try db.moments(for: day, now: day.addingTimeInterval(2 * 86_400)).count <= 3)
    }

    @Test func busiestAppPerDay() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        try db.save([summary(day.addingTimeInterval(3600), [safari: ByteCounts(down: 10, up: 0), chrome: ByteCounts(down: 5, up: 0)]),
                     summary(day.addingTimeInterval(7200), [chrome: ByteCounts(down: 20, up: 0)]),
                     summary(day.addingTimeInterval(86_400 + 3600), [safari: ByteCounts(down: 1, up: 0)])])
        let tops = try db.topApps(byDayIn: db.month(containing: day))
        #expect(tops[day]?.identity.key == chrome.key)
        #expect(tops[day.addingTimeInterval(86_400)]?.identity.key == safari.key)
    }
}
