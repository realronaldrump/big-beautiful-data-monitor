import SwiftUI
import MonitorEngine
import UsageStore

/// Clicking any app icon anywhere opens this: the large icon, today and this month,
/// its own small day ring, and one plain line once a week of data exists.
struct AppDetailView: View {
    let identity: AppIdentity
    @Environment(MonitorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail = Detail()
    @State private var hovered: Int?
    @State private var bloom: Int?

    struct Detail: Sendable {
        var today = ByteCounts.zero
        var month = ByteCounts.zero
        var hours: [Date: ByteCounts] = [:]
        var busiest: PartOfDay?
    }

    var body: some View {
        let color = model.visuals.color(for: identity)
        let unsaved = model.todayByApp[identity.key].map { max(0, Int64($0.total) - Int64(detail.today.total)) } ?? 0
        VStack(spacing: 16) {
            ZStack {
                HaloView(color: color, level: 0.55, diameter: 168)
                AppIconView(identity: identity, size: 96)
            }
            .frame(height: 130)
            Text(identity.displayName)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            HStack(spacing: 56) {
                BigNumberView(bytes: max(detail.today.total, model.todayByApp[identity.key]?.total ?? 0), caption: "today", size: 36)
                BigNumberView(bytes: detail.month.total + UInt64(unsaved), caption: "this month", size: 36)
            }
            DayRingView(petals: petals(color: color), diameter: 220, interactive: false, hovered: $hovered, bloom: $bloom)
                .frame(width: 220, height: 220)
            Text(busiestLine ?? " ")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
                .tint(color)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 30)
        .frame(width: 480)
        .onExitCommand { dismiss() }
        .task(id: model.dataVersion) { await load() }
    }

    private var busiestLine: String? {
        switch detail.busiest {
        case .morning: "Usually busiest in the morning"
        case .afternoon: "Usually busiest in the afternoon"
        case .evening: "Usually busiest in the evening"
        case .night: "Usually busiest at night"
        case nil: nil
        }
    }

    private func petals(color: Color) -> [Petal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentHour = calendar.component(.hour, from: Date())
        var byHour: [Int: ByteCounts] = [:]
        for (hour, bytes) in detail.hours { byHour[calendar.component(.hour, from: hour), default: .zero] += bytes }
        return (0..<24).map { hour in
            let bytes = byHour[hour] ?? .zero
            return Petal(hour: hour, start: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today,
                         down: Double(bytes.down), up: Double(bytes.up), color: color, apps: [],
                         isFuture: hour > currentHour, isCurrent: hour == currentHour)
        }
    }

    private func load() async {
        let key = identity.key
        let loaded = await model.query { db -> Detail in
            guard let record = try db.app(withKey: key) else { return Detail() }
            let now = Date()
            let day = db.day(containing: now)
            return Detail(today: try db.usage(ofApp: record.id, in: day),
                          month: try db.usage(ofApp: record.id, in: db.month(containing: now)),
                          hours: try db.hours(ofApp: record.id, in: day),
                          busiest: try db.busiestPartOfDay(forApp: record.id, now: now))
        }
        withAnimation(Theme.softSpring) { detail = loaded ?? Detail() }
    }
}
