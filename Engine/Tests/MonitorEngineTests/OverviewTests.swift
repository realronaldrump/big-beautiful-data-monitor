import Foundation
import Testing
@testable import MonitorEngine
@testable import UsageStore

@Suite struct OverviewTests {
    let calendar: Calendar = {
        var calendar = pacific()
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()
    /// Saturday, October 24, 2026, mid-afternoon.
    var now: Date { date(2026, 10, 24, hour: 15) }

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func title(_ period: UsagePeriod) -> String {
        period.title(calendar: calendar, now: now).replacingOccurrences(of: "\u{2009}", with: " ")
    }

    // MARK: - Query

    @Test func appTotalsAddUpEveryHourAndSplitOutTheHotspot() throws {
        let db = try UsageDatabase(inMemoryWith: calendar)
        let morning = date(2026, 10, 20, hour: 9)
        try db.save([
            summary(morning, [safari: ByteCounts(down: 1_000, up: 100), chrome: ByteCounts(down: 50, up: 5)]),
            summary(morning.addingTimeInterval(5 * 3600), [safari: ByteCounts(down: 2_000, up: 200)], network: .hotspot),
            summary(date(2026, 10, 23, hour: 22), [chrome: ByteCounts(down: 9_000, up: 0)]),
            // Outside the week: not counted.
            summary(date(2026, 10, 25, hour: 1), [safari: ByteCounts(down: 7, up: 7)]),
        ])
        let week = UsagePeriod(kind: .week, anchor: morning).interval(calendar: calendar, now: now)
        let totals = try db.appTotals(in: week)
        #expect(totals.map(\.app.identity.key) == [chrome.key, safari.key])
        #expect(totals[0].bytes == ByteCounts(down: 9_050, up: 5))
        #expect(totals[0].hotspot == .zero)
        #expect(totals[1].bytes == ByteCounts(down: 3_000, up: 300))
        #expect(totals[1].hotspot == ByteCounts(down: 2_000, up: 200))
        #expect(totals.reduce(ByteCounts.zero) { $0 + $1.bytes } == (try db.total(in: week)))
    }

    // MARK: - Periods

    @Test func eachKindCoversWholeLocalDays() {
        let day = UsagePeriod(kind: .day, anchor: now).interval(calendar: calendar, now: now)
        #expect(day == DateInterval(start: date(2026, 10, 24), end: date(2026, 10, 25)))
        let week = UsagePeriod(kind: .week, anchor: now).interval(calendar: calendar, now: now)
        #expect(week == DateInterval(start: date(2026, 10, 18), end: date(2026, 10, 25)))
        let month = UsagePeriod(kind: .month, anchor: now).interval(calendar: calendar, now: now)
        #expect(month == DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1)))
        let year = UsagePeriod(kind: .year, anchor: now).interval(calendar: calendar, now: now)
        #expect(year == DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1)))
        let all = UsagePeriod(kind: .allTime).interval(calendar: calendar, now: now, firstDay: date(2026, 10, 21, hour: 18))
        #expect(all == DateInterval(start: date(2026, 10, 21), end: date(2026, 10, 25)))
        let range = UsagePeriod.days(date(2026, 10, 20, hour: 8), through: date(2026, 10, 3, hour: 23))
        #expect(range.interval(calendar: calendar, now: now) == DateInterval(start: date(2026, 10, 3), end: date(2026, 10, 21)))
    }

    @Test func stepsBackButNeverIntoTheFuture() throws {
        let week = UsagePeriod(kind: .week, anchor: now)
        #expect(week.stepped(by: 1, calendar: calendar, now: now) == nil)
        let lastWeek = try #require(week.stepped(by: -1, calendar: calendar, now: now))
        #expect(lastWeek.interval(calendar: calendar, now: now).start == date(2026, 10, 11))
        #expect(lastWeek.stepped(by: 1, calendar: calendar, now: now)?.interval(calendar: calendar, now: now)
                == week.interval(calendar: calendar, now: now))
        #expect(UsagePeriod(kind: .allTime).stepped(by: -1, calendar: calendar, now: now) == nil)

        // A custom range moves by its own length.
        let range = UsagePeriod.days(date(2026, 10, 1), through: date(2026, 10, 10))
        let before = try #require(range.stepped(by: -1, calendar: calendar, now: now))
        #expect(before.interval(calendar: calendar, now: now) == DateInterval(start: date(2026, 9, 21), end: date(2026, 10, 1)))
        #expect(range.stepped(by: 1, calendar: calendar, now: now) != nil)
        #expect(range.stepped(by: 3, calendar: calendar, now: now) == nil)
    }

    @Test func switchingKindKeepsThePlaceInTime() {
        let pastWeek = UsagePeriod(kind: .week, anchor: date(2026, 9, 9))
        let month = pastWeek.switched(to: .month, calendar: calendar, now: now)
        #expect(month.interval(calendar: calendar, now: now).start == date(2026, 9, 1))
        let thisWeek = UsagePeriod(kind: .week, anchor: now).switched(to: .day, calendar: calendar, now: now)
        #expect(title(thisWeek) == "Today")
        let range = UsagePeriod(kind: .month, anchor: now).switched(to: .custom, calendar: calendar, now: now)
        #expect(range.interval(calendar: calendar, now: now) == DateInterval(start: date(2026, 10, 1), end: date(2026, 10, 25)))
        let everything = UsagePeriod(kind: .allTime).switched(to: .custom, calendar: calendar, now: now, firstDay: date(2026, 10, 21))
        #expect(everything.interval(calendar: calendar, now: now) == DateInterval(start: date(2026, 10, 21), end: date(2026, 10, 25)))
    }

    @Test func titlesUsePlainWords() {
        #expect(title(UsagePeriod(kind: .day, anchor: now)) == "Today")
        #expect(title(UsagePeriod(kind: .day, anchor: date(2026, 10, 23))) == "Yesterday")
        #expect(title(UsagePeriod(kind: .day, anchor: date(2026, 10, 14))) == "Wednesday, October 14")
        #expect(title(UsagePeriod(kind: .day, anchor: date(2025, 10, 14))) == "Tuesday, October 14, 2025")
        #expect(title(UsagePeriod(kind: .week, anchor: now)) == "This week")
        #expect(title(UsagePeriod(kind: .week, anchor: date(2026, 10, 12))) == "Last week")
        #expect(title(UsagePeriod(kind: .week, anchor: date(2026, 10, 6))) == "Oct 4 – 10")
        #expect(title(UsagePeriod(kind: .week, anchor: date(2025, 12, 30))) == "Dec 28, 2025 – Jan 3, 2026")
        #expect(title(UsagePeriod(kind: .month, anchor: now)) == "This month")
        #expect(title(UsagePeriod(kind: .month, anchor: date(2026, 9, 9))) == "September 2026")
        #expect(title(UsagePeriod(kind: .year, anchor: now)) == "This year")
        #expect(title(UsagePeriod(kind: .year, anchor: date(2025, 3, 1))) == "2025")
        #expect(title(UsagePeriod(kind: .allTime)) == "All time")
        #expect(title(.days(date(2026, 10, 3), through: date(2026, 10, 20))) == "Oct 3 – 20")
        #expect(title(.days(date(2026, 10, 14), through: date(2026, 10, 14))) == "Oct 14")
    }

    @Test func captionsReadAfterTheNumber() {
        func caption(_ period: UsagePeriod, firstDay: Date? = nil) -> String {
            period.caption(calendar: calendar, now: now, firstDay: firstDay)
        }
        #expect(caption(UsagePeriod(kind: .day, anchor: now)) == "today")
        #expect(caption(UsagePeriod(kind: .day, anchor: date(2026, 10, 23))) == "yesterday")
        #expect(caption(UsagePeriod(kind: .day, anchor: date(2026, 10, 14))) == "on Oct 14")
        #expect(caption(UsagePeriod(kind: .week, anchor: date(2026, 10, 12))) == "last week")
        #expect(caption(UsagePeriod(kind: .week, anchor: date(2026, 10, 6))) == "week of Oct 4")
        #expect(caption(UsagePeriod(kind: .month, anchor: date(2026, 9, 9))) == "in September")
        #expect(caption(UsagePeriod(kind: .month, anchor: date(2025, 9, 9))) == "in September 2025")
        #expect(caption(UsagePeriod(kind: .year, anchor: date(2025, 3, 1))) == "in 2025")
        #expect(caption(UsagePeriod(kind: .allTime), firstDay: date(2026, 10, 21)) == "since Oct 21")
        #expect(caption(.days(date(2026, 10, 3), through: date(2026, 10, 20))) == "over 18 days")
    }
}
