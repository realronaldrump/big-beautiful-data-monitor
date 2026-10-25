import SwiftUI
import MonitorEngine
import UsageStore

/// How the Apps overview is ordered. Names run A to Z at first; amounts biggest first.
enum OverviewSort: String {
    case name, down, up, total
}

/// One app in the overview: its stored hours plus the minute in progress.
private struct OverviewRow: Identifiable {
    let identity: AppIdentity
    var bytes: ByteCounts
    var hotspot: ByteCounts
    var id: String { identity.key }
}

/// Shared widths, so the sort header lines up with the rows.
private enum Column {
    static let icon: CGFloat = 28
    static let name: CGFloat = 190
    static let amount: CGFloat = 72
    static let total: CGFloat = 80
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 12
}

/// Every app's data for a chosen period: a day, week, month or year stepped with arrows, all time,
/// or a custom range, with the period's total on top. Click a column to sort; click an app to open it.
struct AppsView: View {
    @Environment(MonitorModel.self) private var model
    @State private var stored: [AppTotal] = []
    @State private var firstDay: Date?
    @State private var loaded = false
    @State private var hovered: String?
    @AppStorage("overviewSort") private var sort = OverviewSort.total
    @AppStorage("overviewAscending") private var ascending = false

    private struct LoadKey: Equatable {
        let period: UsagePeriod
        let version: Int
    }

    var body: some View {
        let calendar = Calendar.current
        let period = model.overviewPeriod
        let interval = period.interval(calendar: calendar, firstDay: firstDay)
        let rows = makeRows(includeUnsaved: interval.contains(Date()))
        let total = rows.reduce(0) { $0 + $1.bytes.total }
        let hoveredRow = hovered.flatMap { key in rows.first { $0.id == key } }

        VStack(spacing: 12) {
            header(period)
            if period.kind == .custom { rangePickers(period) }
            BigNumberView(bytes: hoveredRow?.bytes.total ?? total,
                          caption: period.caption(calendar: calendar, firstDay: firstDay), size: 50,
                          override: hoveredRow.map { share($0, of: total) },
                          topApp: rows.max { $0.bytes.total < $1.bytes.total }?.identity)
                .padding(.bottom, 4)
            if !rows.isEmpty {
                list(sorted(rows), peak: rows.map(\.bytes.total).max() ?? 0)
            } else if loaded {
                emptyState
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 54)
        .frame(maxWidth: .infinity)
        .task(id: LoadKey(period: period, version: model.dataVersion)) { await load(period) }
    }

    // MARK: - Period

    private func header(_ period: UsagePeriod) -> some View {
        let calendar = Calendar.current
        // Back stops at the first day with data; forward stops at the current period.
        let back = period.stepped(by: -1, calendar: calendar).flatMap { previous -> UsagePeriod? in
            guard let firstDay, previous.interval(calendar: calendar).end <= firstDay else { return previous }
            return nil
        }
        let forward = period.stepped(by: 1, calendar: calendar)
        return HStack(spacing: 18) {
            StepButton(symbol: "chevron.left") { step(to: back) }
                .disabled(back == nil)
                .opacity(back == nil ? 0.25 : 1)
            Menu {
                Picker("Period", selection: kindBinding) {
                    ForEach(UsagePeriod.Kind.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 7) {
                    Text(period.title(calendar: calendar))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .fixedSize()
            .help("Choose a period")
            .frame(minWidth: 240)
            StepButton(symbol: "chevron.right") { step(to: forward) }
                .disabled(forward == nil)
                .opacity(forward == nil ? 0.25 : 1)
        }
    }

    /// From and to dates for a custom range. Moving one past the other moves both.
    private func rangePickers(_ period: UsagePeriod) -> some View {
        let first = Binding(get: { period.anchor }, set: { day in
            model.overviewPeriod = .days(day, through: max(day, model.overviewPeriod.lastDay))
        })
        let last = Binding(get: { period.lastDay }, set: { day in
            model.overviewPeriod = .days(min(day, model.overviewPeriod.anchor), through: day)
        })
        return HStack(spacing: 10) {
            DayButton(day: first, label: "First day")
            Text("to")
                .foregroundStyle(.secondary)
            DayButton(day: last, label: "Last day")
        }
        .font(.system(size: 13, design: .rounded))
        .fixedSize()
        .transition(.opacity)
    }

    private var kindBinding: Binding<UsagePeriod.Kind> {
        Binding(get: { model.overviewPeriod.kind }, set: { kind in
            withAnimation(Theme.spring) {
                model.overviewPeriod = model.overviewPeriod.switched(to: kind, calendar: .current, firstDay: firstDay)
            }
        })
    }

    private func step(to period: UsagePeriod?) {
        guard let period else { return }
        withAnimation(Theme.spring) { model.overviewPeriod = period }
    }

    // MARK: - Apps

    private func list(_ rows: [OverviewRow], peak: UInt64) -> some View {
        VStack(spacing: 4) {
            sortHeader(count: rows.count)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        AppRowView(row: row, peak: peak, isHovered: hovered == row.id)
                            .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
                            .onTapGesture { model.detailApp = row.identity }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func sortHeader(count: Int) -> some View {
        HStack(spacing: Column.spacing) {
            sortButton(.name, help: "Sort by name", trailing: false) { Text(count == 1 ? "1 app" : "\(count) apps") }
                .frame(width: Column.icon + Column.spacing + Column.name, alignment: .leading)
            Spacer(minLength: 0)
            sortButton(.down, help: "Sort by downloads", trailing: true) { Image(systemName: "arrow.down") }
                .frame(width: Column.amount, alignment: .trailing)
            sortButton(.up, help: "Sort by uploads", trailing: true) { Image(systemName: "arrow.up") }
                .frame(width: Column.amount, alignment: .trailing)
            sortButton(.total, help: "Sort by total", trailing: true) { Text("Total") }
                .frame(width: Column.total, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, Column.inset)
        .frame(height: 22)
    }

    /// A column title that sorts by it; clicking the current one flips the order.
    /// The arrow sits on the side away from the numbers, so titles stay lined up with them.
    private func sortButton<Label: View>(_ key: OverviewSort, help: String, trailing: Bool,
                                         @ViewBuilder label: () -> Label) -> some View {
        let active = sort == key
        let arrow = Image(systemName: ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
        return Button {
            withAnimation(Theme.spring) {
                if active {
                    ascending.toggle()
                } else {
                    sort = key
                    ascending = key == .name
                }
            }
        } label: {
            HStack(spacing: 4) {
                if active && trailing { arrow }
                label()
                if active && !trailing { arrow }
            }
            .foregroundStyle(active ? .secondary : .tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28, weight: .light))
            Text("Nothing used in this period")
                .font(.system(size: 15, design: .rounded))
        }
        .foregroundStyle(.tertiary)
        .frame(maxHeight: .infinity)
        .transition(.opacity)
    }

    private func share(_ row: OverviewRow, of total: UInt64) -> String {
        let percent = total == 0 ? 0 : Double(row.bytes.total) / Double(total) * 100
        let text = percent < 1 ? "less than 1%" : "\(Int(percent.rounded()))%"
        return "\(row.identity.displayName) · \(text) of all data"
    }

    // MARK: - Data

    private func makeRows(includeUnsaved: Bool) -> [OverviewRow] {
        var rows: [String: OverviewRow] = [:]
        for total in stored {
            rows[total.app.identity.key] = OverviewRow(identity: total.app.identity, bytes: total.bytes, hotspot: total.hotspot)
        }
        if includeUnsaved {
            for (key, bytes) in model.unsavedByApp {
                guard let identity = rows[key]?.identity ?? model.identity(forKey: key) else { continue }
                rows[key, default: OverviewRow(identity: identity, bytes: .zero, hotspot: .zero)].bytes += bytes
            }
        }
        return Array(rows.values)
    }

    private func sorted(_ rows: [OverviewRow]) -> [OverviewRow] {
        rows.sorted { a, b in
            let order = switch sort {
            case .name: a.identity.displayName.localizedStandardCompare(b.identity.displayName)
            case .down: Self.compare(a.bytes.down, b.bytes.down)
            case .up: Self.compare(a.bytes.up, b.bytes.up)
            case .total: Self.compare(a.bytes.total, b.bytes.total)
            }
            if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
            // Ties: busiest first, then a fixed order, so rows never swap places on their own.
            if a.bytes.total != b.bytes.total { return a.bytes.total > b.bytes.total }
            return a.id < b.id
        }
    }

    private static func compare(_ a: UInt64, _ b: UInt64) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    private func load(_ period: UsagePeriod) async {
        let calendar = Calendar.current
        let result = await model.query { db -> (firstDay: Date?, totals: [AppTotal]) in
            let first = try db.firstDay()
            return (first, try db.appTotals(in: period.interval(calendar: calendar, firstDay: first)))
        }
        for total in result?.totals ?? [] { model.visuals.cacheColor(total.app) }
        withAnimation(Theme.softSpring) {
            firstDay = result?.firstDay
            stored = result?.totals ?? []
            loaded = true
        }
    }
}

/// A day in a custom range ("Oct 18"), which opens a small calendar to change it.
private struct DayButton: View {
    @Binding var day: Date
    let label: String
    @State private var picking = false

    var body: some View {
        let sameYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        Button { picking = true } label: {
            Text(sameYear ? day.formatted(.dateTime.month(.abbreviated).day())
                          : day.formatted(.dateTime.month(.abbreviated).day().year()))
                .padding(.horizontal, 2)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("\(label), \(day.formatted(date: .long, time: .omitted))")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            DatePicker(label, selection: $day, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
        }
    }
}

/// One app: icon, name, a bar of its share, and its downloads, uploads and total.
private struct AppRowView: View {
    let row: OverviewRow
    let peak: UInt64
    let isHovered: Bool
    @Environment(MonitorModel.self) private var model

    var body: some View {
        HStack(spacing: Column.spacing) {
            AppIconView(identity: row.identity, size: Column.icon)
            HStack(spacing: 5) {
                Text(row.identity.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !row.hotspot.isZero {
                    Image(systemName: "personalhotspot")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("\(FriendlyBytes.format(row.hotspot.total)) over an iPhone hotspot")
                }
            }
            .frame(width: Column.name, alignment: .leading)
            UsageBar(bytes: row.bytes, peak: peak, color: model.visuals.color(for: row.identity))
            amount(row.bytes.down)
                .frame(width: Column.amount, alignment: .trailing)
            amount(row.bytes.up)
                .frame(width: Column.amount, alignment: .trailing)
            Text(FriendlyBytes.format(row.bytes.total))
                .fontWeight(.medium)
                .contentTransition(.numericText(value: Double(row.bytes.total)))
                .frame(width: Column.total, alignment: .trailing)
        }
        .font(.system(size: 14, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, Column.inset)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(isHovered ? 0.06 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(Theme.spring, value: row.bytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.identity.displayName), \(FriendlyBytes.format(row.bytes.total)): "
                            + "\(FriendlyBytes.format(row.bytes.down)) down, \(FriendlyBytes.format(row.bytes.up)) up")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func amount(_ bytes: UInt64) -> some View {
        if bytes == 0 {
            Text("–").foregroundStyle(.quaternary)
        } else {
            Text(FriendlyBytes.format(bytes)).foregroundStyle(.secondary)
        }
    }
}

/// Downloads in the app's color, then uploads in a lighter shade of it.
/// The busiest app in the list fills the whole width.
private struct UsageBar: View {
    let bytes: ByteCounts
    let peak: UInt64
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = peak == 0 ? 0 : Double(bytes.total) / Double(peak)
            let length = bytes.isZero ? 0 : max(5, geometry.size.width * fraction)
            let downShare = bytes.total == 0 ? 1 : Double(bytes.down) / Double(bytes.total)
            HStack(spacing: 0) {
                Rectangle().fill(color)
                    .frame(width: length * downShare)
                Rectangle().fill(color.uploadShade())
                    .frame(width: length * (1 - downShare))
            }
            .frame(width: length, height: 8)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 60)
        .frame(height: 10)
    }
}
