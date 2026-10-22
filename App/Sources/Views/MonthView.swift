import SwiftUI
import MonitorEngine
import UsageStore

/// A calendar of soft circles, each sized by that day's total and tinted by its busiest app,
/// with today gently pulsing. Clicking a day opens it in Day.
struct MonthView: View {
    @Environment(MonitorModel.self) private var model
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var days: [Date: DayUsage] = [:]
    @State private var tops: [Date: AppRecord] = [:]
    @State private var hovered: Date?

    private struct LoadKey: Equatable {
        let month: Date
        let version: Int
    }

    var body: some View {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: month)!
        let isCurrentMonth = interval.contains(Date())
        let dates = Self.dates(in: interval)
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let peak = max(1, days.values.map(\.total.total).max() ?? 1)
        let monthTotal = days.values.reduce(0) { $0 + $1.total.total } + (isCurrentMonth ? model.unsaved.total : 0)

        GeometryReader { geometry in
            let cell = min(72, max(52, (min(geometry.size.width - 120, geometry.size.height - 290) / 6.2)))
            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    StepButton(symbol: "chevron.left") { step(-1) }
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .frame(minWidth: 200)
                    StepButton(symbol: "chevron.right") { step(1) }
                        .disabled(isCurrentMonth)
                        .opacity(isCurrentMonth ? 0.25 : 1)
                }
                BigNumberView(bytes: hovered.flatMap { days[$0]?.total.total } ?? monthTotal,
                              caption: isCurrentMonth ? "this month" : "in \(month.formatted(.dateTime.month(.wide)))",
                              size: 50, override: hovered.map(hoverCaption))
                    .padding(.bottom, 6)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 6), count: 7), spacing: 2) {
                    ForEach(Self.weekdayInitials(calendar), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(height: 18)
                    }
                    ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: cell) }
                    ForEach(dates, id: \.self) { date in
                        DayCell(date: date, usage: days[date],
                                color: tops[date].map { model.visuals.color(for: $0.identity) } ?? model.visuals.color(forKey: nil, in: [:]),
                                peak: peak, cell: cell,
                                isToday: calendar.isDateInToday(date), isFuture: date > Date())
                            .onHover { inside in hovered = inside ? date : (hovered == date ? nil : hovered) }
                            .onTapGesture {
                                guard date <= Date() else { return }
                                model.shownDay = date
                                model.mainTab = .day
                            }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)
        }
        .task(id: LoadKey(month: month, version: model.dataVersion)) { await load(interval) }
        .onAppear {
            month = Calendar.current.dateInterval(of: .month, for: model.shownDay)!.start
        }
    }

    private func hoverCaption(_ date: Date) -> String {
        let name = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard let top = tops[date] else { return name }
        return "\(name) · mostly \(top.identity.displayName)"
    }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month), next <= Date() else { return }
        withAnimation(Theme.spring) { month = next }
    }

    private func load(_ interval: DateInterval) async {
        async let loadedDays = model.query { try $0.days(in: interval) }
        async let loadedTops = model.query { try $0.topApps(byDayIn: interval) }
        let (newDays, newTops) = await (loadedDays, loadedTops)
        for record in (newTops ?? [:]).values { model.visuals.cacheColor(record) }
        withAnimation(Theme.softSpring) {
            days = Dictionary((newDays ?? []).map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            tops = newTops ?? [:]
        }
    }

    static func dates(in interval: DateInterval) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        var date = interval.start
        while date < interval.end {
            dates.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return dates
    }

    static func weekdayInitials(_ calendar: Calendar) -> [(offset: Int, element: String)] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array((symbols[start...] + symbols[..<start]).enumerated())
    }
}

private struct DayCell: View {
    let date: Date
    let usage: DayUsage?
    let color: Color
    let peak: UInt64
    let cell: CGFloat
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        let area = cell - 16
        let total = usage?.total.total ?? 0
        let diameter = total > 0 ? 9 + (area - 9) * CGFloat((Double(total) / Double(peak)).squareRoot()) : 0
        VStack(spacing: 1) {
            ZStack {
                if total > 0 {
                    Circle()
                        .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.62)], center: .init(x: 0.35, y: 0.3),
                                             startRadius: 0, endRadius: diameter * 0.7))
                        .frame(width: diameter, height: diameter)
                        .shadow(color: color.opacity(0.35), radius: 6, y: 2)
                        .breathing(scale: 0.06, enabled: isToday)
                } else {
                    Circle()
                        .strokeBorder(.secondary.opacity(isFuture ? 0.12 : 0.22), lineWidth: 1)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: cell, height: area)
            HStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 10, weight: isToday ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isToday ? .secondary : .tertiary)
                if usage?.usedHotspot == true {
                    Image(systemName: "personalhotspot")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("An iPhone hotspot was used")
                }
            }
            .frame(height: 14)
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)), \(FriendlyBytes.format(total))")
    }
}
