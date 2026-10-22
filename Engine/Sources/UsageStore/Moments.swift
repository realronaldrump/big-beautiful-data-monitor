import Foundation
import GRDB
import MonitorEngine

/// A one-line card under the Day ring, generated automatically.
public struct Moment: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        /// The biggest spike, explained: "6.1 GB · macOS updates · 2 PM".
        case spike
        /// What moved while the Mac sat idle, and why.
        case away
        /// Compared to usual: "About a normal Wednesday".
        case usual
    }

    public let kind: Kind
    public let day: Date
    public let text: String
    /// The app the moment is about, if any (its icon leads the card).
    public let app: AppRecord?

    /// Stable per kind and day, so a dismissed card stays dismissed.
    public var id: String { "\(kind.rawValue)-\(Int(day.timeIntervalSince1970))" }
}

extension UsageDatabase {
    /// At most three moments for a day: the biggest spike, what moved while you were away,
    /// and how the day compares to usual. Each appears only when it has something to say.
    public func moments(for date: Date, now: Date = Date()) throws -> [Moment] {
        let day = day(containing: date)
        var moments: [Moment] = []
        if let spike = try spikeMoment(day) { moments.append(spike) }
        if let away = try awayMoment(day) { moments.append(away) }
        if let usual = try usualMoment(day, now: now) { moments.append(usual) }
        return moments
    }

    static let spikeMinimum: UInt64 = 100_000_000
    static let awayMinimum: UInt64 = 25_000_000

    /// The busiest hour, when it clearly stands out from the rest of the day.
    func spikeMoment(_ day: DateInterval) throws -> Moment? {
        let hours = try hours(in: day).filter { $0.total.total > 0 }
        guard let peak = hours.max(by: { $0.total.total < $1.total.total }), peak.total.total >= Self.spikeMinimum else { return nil }
        let others = hours.filter { $0.hour != peak.hour }.map(\.total.total).sorted()
        let typical = others.isEmpty ? 0 : others[others.count / 2]
        guard peak.total.total >= typical * 3 else { return nil }
        let app = peak.topApp
        let name = app?.identity.displayName ?? AppIdentity.macSystem.displayName
        return Moment(kind: .spike, day: day.start,
                      text: "\(FriendlyBytes.format(peak.total.total)) · \(name) · \(Self.hourName(peak.hour, calendar: calendar))",
                      app: app)
    }

    /// Bytes that moved during idle minutes, and the app behind most of them.
    func awayMoment(_ day: DateInterval) throws -> Moment? {
        let (total, top) = try read { db -> (UInt64, AppRecord?) in
            let total = try Int64.fetchOne(db, sql: """
                SELECT coalesce(sum(idle_down + idle_up), 0) FROM total_hour WHERE hour >= ? AND hour < ?
                """, arguments: Self.bounds(day)) ?? 0
            let top = try Row.fetchOne(db, sql: """
                SELECT apps.* FROM usage_hour u JOIN apps ON apps.id = u.app_id
                WHERE u.hour >= ? AND u.hour < ?
                GROUP BY u.app_id HAVING sum(u.idle_down + u.idle_up) > 0
                ORDER BY sum(u.idle_down + u.idle_up) DESC LIMIT 1
                """, arguments: Self.bounds(day)).map(AppRecord.init(row:))
            return (UInt64(max(0, total)), top)
        }
        guard total >= Self.awayMinimum else { return nil }
        let because = top.map { ", mostly \($0.identity.displayName)" } ?? ""
        return Moment(kind: .away, day: day.start,
                      text: "While you were away: \(FriendlyBytes.format(total))\(because)", app: top)
    }

    /// The day against the same weekday over the last four weeks (or, failing that, the last week).
    /// Today is compared up to the current hour, so a morning is not judged against whole days.
    func usualMoment(_ day: DateInterval, now: Date) throws -> Moment? {
        let isToday = day.contains(now)
        let cutoff: TimeInterval = isToday
            ? calendar.dateInterval(of: .hour, for: now)!.start.timeIntervalSince(day.start)
            : day.duration
        guard cutoff >= 3 * 3600 else { return nil }
        func total(ofDayStarting start: Date) throws -> UInt64 {
            try self.total(in: DateInterval(start: start, duration: min(cutoff, calendar.dateInterval(of: .day, for: start)!.duration))).total
        }
        let thisDay = try total(ofDayStarting: day.start)

        let sameWeekday = try (1...4).compactMap { weeks -> UInt64? in
            let start = calendar.date(byAdding: .day, value: -7 * weeks, to: day.start)!
            let value = try total(ofDayStarting: start)
            return value > 0 ? value : nil
        }
        let recent = try (1...7).compactMap { days -> UInt64? in
            let start = calendar.date(byAdding: .day, value: -days, to: day.start)!
            let value = try total(ofDayStarting: start)
            return value > 0 ? value : nil
        }
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: day.start) - 1]
        let (base, noun): ([UInt64], String) = sameWeekday.count >= 2 ? (sameWeekday, weekday) : (recent, "day")
        guard base.count >= (noun == "day" ? 3 : 2) else { return nil }
        let usual = Double(base.reduce(0, +)) / Double(base.count)
        guard usual >= 10_000_000 else { return nil }
        return Moment(kind: .usual, day: day.start, text: Self.comparison(Double(thisDay) / usual, noun: noun), app: nil)
    }

    static func comparison(_ ratio: Double, noun: String) -> String {
        switch ratio {
        case ..<0.4: "Much quieter than a usual \(noun)"
        case ..<0.75: "Quieter than a usual \(noun)"
        case ..<1.33: "About a normal \(noun)"
        case ..<1.75: "Busier than a usual \(noun)"
        case ..<2.5: "Twice your usual"
        default: "\(Int(ratio.rounded())) times your usual"
        }
    }

    static func hourName(_ date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 0: return "midnight"
        case 12: return "noon"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("j")
            return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        }
    }
}

extension UsageDatabase {
    /// Each day's busiest app, for tinting the Month calendar's circles.
    public func topApps(byDayIn interval: DateInterval) throws -> [Date: AppRecord] {
        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.hour, apps.*, sum(u.bytes_down + u.bytes_up) AS bytes
                FROM usage_hour u JOIN apps ON apps.id = u.app_id
                WHERE u.hour >= ? AND u.hour < ? GROUP BY u.hour, u.app_id
                """, arguments: Self.bounds(interval))
        }
        var byDay: [Date: [Int64: (record: AppRecord, bytes: Int64)]] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row["hour"] as Int64)))
            let record = AppRecord(row: row)
            byDay[day, default: [:]][record.id, default: (record, 0)].bytes += row["bytes"] as Int64
        }
        return byDay.compactMapValues { apps in apps.values.max { $0.bytes < $1.bytes }?.record }
    }
}
