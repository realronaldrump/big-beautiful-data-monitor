import Foundation
import GRDB
import MonitorEngine

/// An app (or system group) as stored, with its cached icon color.
public struct AppRecord: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let identity: AppIdentity
    /// 0xRRGGBB from the app's icon; soft gray for system groups. Nil until first computed.
    public let iconColor: UInt32?

    init(row: Row) {
        id = row["id"]
        identity = AppIdentity(
            key: row["key"],
            displayName: row["display_name"],
            kind: AppIdentity.Kind(rawValue: row["kind"]) ?? .system,
            bundleID: row["bundle_id"],
            bundlePath: row["bundle_path"],
            symbolName: row["symbol_name"]
        )
        iconColor = (row["icon_color"] as Int64?).map { UInt32(truncatingIfNeeded: $0) }
    }
}

public struct AppUsage: Sendable, Hashable {
    public let app: AppRecord
    public let bytes: ByteCounts
}

/// One app's usage over a period, for the Apps overview.
public struct AppTotal: Sendable, Hashable {
    public let app: AppRecord
    public let bytes: ByteCounts
    /// The part of `bytes` that went over an iPhone hotspot.
    public let hotspot: ByteCounts
}

/// One hour of a day: a petal of the Day ring.
public struct HourUsage: Sendable {
    public let hour: Date
    public let total: ByteCounts
    /// Apps in this hour, busiest first.
    public let apps: [AppUsage]
    public var topApp: AppRecord? { apps.first?.app }
}

/// One day of a month: a circle of the Month calendar.
public struct DayUsage: Sendable {
    public let day: Date
    public let total: ByteCounts
    /// An iPhone hotspot carried some of this day's data.
    public let usedHotspot: Bool
}

public enum PartOfDay: String, Sendable, CaseIterable {
    case night, morning, afternoon, evening

    init(hour: Int) {
        self = switch hour {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
    }
}

extension UsageDatabase {
    // MARK: - Intervals

    public func day(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }

    public func month(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)!
    }

    // MARK: - Totals

    /// The true total for an interval (whole hours).
    public func total(in interval: DateInterval) throws -> ByteCounts {
        try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(bytes_down), 0) AS down, coalesce(sum(bytes_up), 0) AS up
                FROM total_hour WHERE hour >= ? AND hour < ?
                """, arguments: Self.bounds(interval))!
            return ByteCounts(row)
        }
    }

    /// Every app's usage in an interval, busiest first.
    public func apps(in interval: DateInterval) throws -> [AppUsage] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT apps.*, sum(u.bytes_down) AS down, sum(u.bytes_up) AS up
                FROM usage_hour u JOIN apps ON apps.id = u.app_id
                WHERE u.hour >= ? AND u.hour < ?
                GROUP BY u.app_id
                ORDER BY sum(u.bytes_down + u.bytes_up) DESC
                """, arguments: Self.bounds(interval))
            .map { AppUsage(app: AppRecord(row: $0), bytes: ByteCounts($0)) }
        }
    }

    /// Every app's usage in an interval with the part carried by an iPhone hotspot, busiest first.
    public func appTotals(in interval: DateInterval) throws -> [AppTotal] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT apps.*, sum(u.bytes_down) AS down, sum(u.bytes_up) AS up,
                    sum(CASE WHEN u.network = ? THEN u.bytes_down ELSE 0 END) AS hotspot_down,
                    sum(CASE WHEN u.network = ? THEN u.bytes_up ELSE 0 END) AS hotspot_up
                FROM usage_hour u JOIN apps ON apps.id = u.app_id
                WHERE u.hour >= ? AND u.hour < ?
                GROUP BY u.app_id
                ORDER BY sum(u.bytes_down + u.bytes_up) DESC
                """, arguments: [NetworkKind.hotspot.storageCode, NetworkKind.hotspot.storageCode] + Self.bounds(interval))
            .map { row in
                AppTotal(app: AppRecord(row: row), bytes: ByteCounts(row),
                         hotspot: ByteCounts(down: UInt64(max(0, row["hotspot_down"] as Int64)),
                                             up: UInt64(max(0, row["hotspot_up"] as Int64))))
            }
        }
    }

    /// The hours of an interval that saw any data, each with its apps.
    public func hours(in interval: DateInterval) throws -> [HourUsage] {
        try read { db in
            let totals = try Row.fetchAll(db, sql: """
                SELECT hour, sum(bytes_down) AS down, sum(bytes_up) AS up
                FROM total_hour WHERE hour >= ? AND hour < ? GROUP BY hour ORDER BY hour
                """, arguments: Self.bounds(interval))
            var appsByHour: [Int64: [AppUsage]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT u.hour, apps.*, sum(u.bytes_down) AS down, sum(u.bytes_up) AS up
                FROM usage_hour u JOIN apps ON apps.id = u.app_id
                WHERE u.hour >= ? AND u.hour < ?
                GROUP BY u.hour, u.app_id
                """, arguments: Self.bounds(interval)) {
                appsByHour[row["hour"], default: []].append(AppUsage(app: AppRecord(row: row), bytes: ByteCounts(row)))
            }
            return totals.map { row in
                let hour: Int64 = row["hour"]
                return HourUsage(hour: Date(timeIntervalSince1970: TimeInterval(hour)),
                                 total: ByteCounts(row),
                                 apps: (appsByHour[hour] ?? []).sorted { $0.bytes.total > $1.bytes.total })
            }
        }
    }

    /// Daily totals for the days of an interval that saw any data.
    public func days(in interval: DateInterval) throws -> [DayUsage] {
        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT hour, network, bytes_down AS down, bytes_up AS up
                FROM total_hour WHERE hour >= ? AND hour < ?
                """, arguments: Self.bounds(interval))
        }
        var totals: [Date: ByteCounts] = [:]
        var hotspot: Set<Date> = []
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(row["hour"] as Int64)))
            let bytes = ByteCounts(row)
            totals[day, default: .zero] += bytes
            if NetworkKind(storageCode: row["network"]) == .hotspot, !bytes.isZero { hotspot.insert(day) }
        }
        return totals.keys.sorted().map { DayUsage(day: $0, total: totals[$0]!, usedHotspot: hotspot.contains($0)) }
    }

    // MARK: - One app

    /// Every app ever seen, with its cached icon color.
    public func allApps() throws -> [AppRecord] {
        try read { db in try Row.fetchAll(db, sql: "SELECT * FROM apps").map(AppRecord.init(row:)) }
    }

    public func app(withKey key: String) throws -> AppRecord? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM apps WHERE key = ?", arguments: [key]).map(AppRecord.init(row:))
        }
    }

    public func usage(ofApp appID: Int64, in interval: DateInterval) throws -> ByteCounts {
        try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(bytes_down), 0) AS down, coalesce(sum(bytes_up), 0) AS up
                FROM usage_hour WHERE app_id = ? AND hour >= ? AND hour < ?
                """, arguments: [appID] + Self.bounds(interval))!
            return ByteCounts(row)
        }
    }

    /// One app's usage by hour, for its small day ring.
    public func hours(ofApp appID: Int64, in interval: DateInterval) throws -> [Date: ByteCounts] {
        try read { db in
            var result: [Date: ByteCounts] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT hour, sum(bytes_down) AS down, sum(bytes_up) AS up
                FROM usage_hour WHERE app_id = ? AND hour >= ? AND hour < ? GROUP BY hour
                """, arguments: [appID] + Self.bounds(interval)) {
                result[Date(timeIntervalSince1970: TimeInterval(row["hour"] as Int64))] = ByteCounts(row)
            }
            return result
        }
    }

    /// When an app is usually busiest, for "Usually busiest in the evening". Nil until a week of
    /// data exists for it, or when no part of the day clearly stands out.
    public func busiestPartOfDay(forApp appID: Int64, now: Date = Date()) throws -> PartOfDay? {
        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT hour, sum(bytes_down + bytes_up) AS bytes FROM usage_hour
                WHERE app_id = ? AND hour >= ? GROUP BY hour
                """, arguments: [appID, Int64(now.addingTimeInterval(-28 * 24 * 3600).timeIntervalSince1970)])
        }
        guard let first = rows.map({ $0["hour"] as Int64 }).min(),
              now.timeIntervalSince1970 - TimeInterval(first) >= 7 * 24 * 3600 else { return nil }
        var byPart: [PartOfDay: Int64] = [:]
        for row in rows {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(row["hour"] as Int64)))
            byPart[PartOfDay(hour: hour), default: 0] += row["bytes"]
        }
        let sum = byPart.values.reduce(0, +)
        guard sum > 0, let (part, bytes) = byPart.max(by: { $0.value < $1.value }),
              Double(bytes) / Double(sum) >= 0.4 else { return nil }
        return part
    }

    /// The first day with any data.
    public func firstDay() throws -> Date? {
        try read { db in
            try Int64.fetchOne(db, sql: "SELECT min(hour) FROM total_hour")
                .map { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0))) }
        }
    }

    static func bounds(_ interval: DateInterval) -> StatementArguments {
        [Int64(interval.start.timeIntervalSince1970), Int64(interval.end.timeIntervalSince1970)]
    }
}

extension ByteCounts {
    /// Reads the `down` and `up` columns of a query row.
    init(_ row: Row) {
        self.init(down: UInt64(max(0, row["down"] as Int64)), up: UInt64(max(0, row["up"] as Int64)))
    }
}
