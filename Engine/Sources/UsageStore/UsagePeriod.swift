import Foundation

/// A stretch of time for the Apps overview: one day, week, month or year (stepped with arrows),
/// everything so far, or a range of days picked by hand. Periods are whole local days.
public struct UsagePeriod: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case day, week, month, year, allTime, custom

        /// The menu name.
        public var name: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            case .year: "Year"
            case .allTime: "All time"
            case .custom: "Custom range"
            }
        }

        var component: Calendar.Component? {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            case .allTime, .custom: nil
            }
        }
    }

    public var kind: Kind
    /// Any moment inside the period; the first day of a custom range.
    public var anchor: Date
    /// The last day of a custom range (included). Unused by the other kinds.
    public var lastDay: Date

    public init(kind: Kind, anchor: Date = Date()) {
        self.kind = kind
        self.anchor = anchor
        lastDay = anchor
    }

    /// A custom range from one day through another, in either order.
    public static func days(_ first: Date, through last: Date) -> UsagePeriod {
        var period = UsagePeriod(kind: .custom, anchor: min(first, last))
        period.lastDay = max(first, last)
        return period
    }

    // MARK: - Time

    /// The period's whole days. All time runs from `firstDay` (the first day with data) through today.
    public func interval(calendar: Calendar, now: Date = Date(), firstDay: Date? = nil) -> DateInterval {
        if let component = kind.component {
            return calendar.dateInterval(of: component, for: anchor)!
        }
        if kind == .allTime {
            let today = calendar.dateInterval(of: .day, for: now)!
            return DateInterval(start: min(firstDay.map(calendar.startOfDay) ?? today.start, today.start), end: today.end)
        }
        return DateInterval(start: calendar.startOfDay(for: anchor), end: calendar.dateInterval(of: .day, for: lastDay)!.end)
    }

    /// The period before (-1) or after (+1) this one, or nil when there is none: all time does not
    /// step, and nothing steps into the future. A custom range steps by its own length.
    public func stepped(by direction: Int, calendar: Calendar, now: Date = Date()) -> UsagePeriod? {
        var next = self
        if let component = kind.component {
            guard let date = calendar.date(byAdding: component, value: direction, to: anchor) else { return nil }
            next.anchor = date
            next.lastDay = date
        } else if kind == .custom {
            let length = dayCount(calendar: calendar)
            guard let first = calendar.date(byAdding: .day, value: direction * length, to: anchor),
                  let last = calendar.date(byAdding: .day, value: direction * length, to: lastDay) else { return nil }
            next.anchor = first
            next.lastDay = last
        } else {
            return nil
        }
        return next.interval(calendar: calendar, now: now).start <= now ? next : nil
    }

    /// The same place in time seen as another kind of period: a past week switched to Month shows
    /// the month it started in, and a custom range starts out as the days already on screen.
    public func switched(to kind: Kind, calendar: Calendar, now: Date = Date(), firstDay: Date? = nil) -> UsagePeriod {
        let shown = interval(calendar: calendar, now: now, firstDay: firstDay)
        if kind == .custom {
            let last = calendar.date(byAdding: .day, value: -1, to: shown.end)!
            return .days(shown.start, through: min(last, now))
        }
        return UsagePeriod(kind: kind, anchor: shown.contains(now) ? now : shown.start)
    }

    /// Number of days in a custom range.
    func dayCount(calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: anchor)
        let last = calendar.startOfDay(for: lastDay)
        return (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    // MARK: - Words

    /// The header: "Today", "This week", "September 2026", "Oct 4 – 10", "All time".
    public func title(calendar: Calendar, now: Date = Date()) -> String {
        let shown = interval(calendar: calendar, now: now)
        let isCurrent = shown.contains(now)
        let isPrevious = stepped(by: 1, calendar: calendar, now: now)?.interval(calendar: calendar, now: now).contains(now) == true
        switch kind {
        case .day:
            if isCurrent { return "Today" }
            if isPrevious { return "Yesterday" }
            return Self.format(anchor, "EEEEMMMMd", calendar, now: now)
        case .week:
            if isCurrent { return "This week" }
            if isPrevious { return "Last week" }
            return Self.format(shown, calendar, now: now)
        case .month:
            return isCurrent ? "This month" : Self.format(anchor, "MMMMy", calendar, now: now, alwaysYear: true)
        case .year:
            return isCurrent ? "This year" : Self.format(anchor, "y", calendar, now: now, alwaysYear: true)
        case .allTime:
            return "All time"
        case .custom:
            return Self.format(shown, calendar, now: now)
        }
    }

    /// Under the big number: "today", "this week", "in September", "since Oct 21", "over 12 days".
    public func caption(calendar: Calendar, now: Date = Date(), firstDay: Date? = nil) -> String {
        let shown = interval(calendar: calendar, now: now, firstDay: firstDay)
        let isCurrent = shown.contains(now)
        let isPrevious = stepped(by: 1, calendar: calendar, now: now)?.interval(calendar: calendar, now: now).contains(now) == true
        switch kind {
        case .day:
            if isCurrent { return "today" }
            if isPrevious { return "yesterday" }
            return "on " + Self.format(anchor, "MMMd", calendar, now: now)
        case .week:
            if isCurrent { return "this week" }
            if isPrevious { return "last week" }
            return "week of " + Self.format(shown.start, "MMMd", calendar, now: now)
        case .month:
            return isCurrent ? "this month" : "in " + Self.format(anchor, "MMMM", calendar, now: now)
        case .year:
            return isCurrent ? "this year" : "in " + Self.format(anchor, "y", calendar, now: now, alwaysYear: true)
        case .allTime:
            return firstDay.map { "since " + Self.format($0, "MMMd", calendar, now: now) } ?? "so far"
        case .custom:
            let days = dayCount(calendar: calendar)
            return days == 1 ? "on " + Self.format(anchor, "MMMd", calendar, now: now) : "over \(days) days"
        }
    }

    /// A date in the calendar's locale; the year is added when it is not the current one.
    static func format(_ date: Date, _ template: String, _ calendar: Calendar, now: Date, alwaysYear: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        let otherYear = calendar.component(.year, from: date) != calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(otherYear && !alwaysYear && !template.contains("y") ? template + "y" : template)
        return formatter.string(from: date)
    }

    /// A range of whole days ("Oct 4 – 10"), with the year when it is not the current one.
    static func format(_ interval: DateInterval, _ calendar: Calendar, now: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        let year = calendar.component(.year, from: now)
        let otherYear = calendar.component(.year, from: interval.start) != year || calendar.component(.year, from: last) != year
        formatter.dateTemplate = otherYear ? "yMMMd" : "MMMd"
        return formatter.string(from: interval.start, to: last)
    }
}
