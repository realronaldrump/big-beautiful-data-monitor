import SwiftUI
import MonitorEngine
import UsageStore

/// One day as a ring of hours, with today's total at the center and up to three Moments beneath.
struct DayView: View {
    @Environment(MonitorModel.self) private var model
    @State private var hours: [HourUsage] = []
    @State private var moments: [Moment] = []
    @State private var hovered: Int?
    @State private var bloom: Int?
    @AppStorage("dismissedMoments") private var dismissedMoments = ""

    private struct LoadKey: Equatable {
        let day: Date
        let version: Int
    }

    var body: some View {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: model.shownDay)
        let isToday = calendar.isDateInToday(day)
        let petals = makePetals(day: day, isToday: isToday)
        let dayTotal = UInt64(petals.reduce(0) { $0 + $1.total })
        let dismissed = Set(dismissedMoments.split(separator: ",").map(String.init))

        GeometryReader { geometry in
            let ring = max(280, min(geometry.size.width * 0.6, geometry.size.height - 330, 450))
            VStack(spacing: 14) {
                header(day: day, isToday: isToday)
                ZStack {
                    DayRingView(petals: petals, diameter: ring, hovered: $hovered, bloom: $bloom,
                                openApp: { model.detailApp = $0 })
                    BigNumberView(bytes: hoveredPetal(petals).map { UInt64($0.total) } ?? dayTotal,
                                  caption: caption(day: day, isToday: isToday), size: ring * 0.13,
                                  override: hoveredPetal(petals).map(hourCaption),
                                  topApp: isToday ? model.topAppToday : topApp(of: hours))
                        .allowsHitTesting(false)
                }
                .frame(width: ring, height: ring)
                .padding(.vertical, 6)
                MomentsView(moments: moments.filter { !dismissed.contains($0.id) },
                            dismiss: { moment in
                                withAnimation(Theme.spring) {
                                    dismissedMoments = (dismissed.union([moment.id])).sorted().joined(separator: ",")
                                }
                            },
                            openApp: { model.detailApp = $0 })
                    .frame(maxWidth: 520)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)
        }
        .task(id: LoadKey(day: day, version: model.dataVersion)) { await load(day) }
        .onChange(of: day) { bloom = nil }
    }

    private func header(day: Date, isToday: Bool) -> some View {
        HStack(spacing: 18) {
            StepButton(symbol: "chevron.left") { step(-1) }
            Text(title(day: day, isToday: isToday))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .frame(minWidth: 240)
                .contentTransition(.opacity)
            StepButton(symbol: "chevron.right") { step(1) }
                .disabled(isToday)
                .opacity(isToday ? 0.25 : 1)
        }
    }

    private func step(_ days: Int) {
        let next = Calendar.current.date(byAdding: .day, value: days, to: model.shownDay) ?? model.shownDay
        guard next <= Date() || Calendar.current.isDateInToday(next) else { return }
        withAnimation(Theme.spring) { model.shownDay = next }
    }

    private func title(day: Date, isToday: Bool) -> String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func caption(day: Date, isToday: Bool) -> String {
        isToday ? "today" : day.formatted(.dateTime.weekday(.wide))
    }

    private func topApp(of hours: [HourUsage]) -> AppIdentity? {
        var totals: [String: (identity: AppIdentity, bytes: UInt64)] = [:]
        for usage in hours.flatMap(\.apps) {
            totals[usage.app.identity.key, default: (usage.app.identity, 0)].bytes += usage.bytes.total
        }
        return totals.values.max { $0.bytes < $1.bytes }?.identity
    }

    private func hoveredPetal(_ petals: [Petal]) -> Petal? {
        guard let hovered = hovered ?? bloom else { return nil }
        return petals.first { $0.hour == hovered }
    }

    private func hourCaption(_ petal: Petal) -> String {
        let hour = petal.start.hourName
        guard let top = petal.apps.first else { return hour }
        return "\(hour) · mostly \(top.app.identity.displayName)"
    }

    private func makePetals(day: Date, isToday: Bool) -> [Petal] {
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        var byHour: [Int: HourUsage] = [:]
        for usage in hours where calendar.isDate(usage.hour, inSameDayAs: day) {
            byHour[calendar.component(.hour, from: usage.hour)] = usage
        }
        return (0..<24).map { hour in
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            let stored = byHour[hour]
            var down = Double(stored?.total.down ?? 0)
            var up = Double(stored?.total.up ?? 0)
            let isCurrent = isToday && hour == currentHour
            if isCurrent {
                // The current hour grows live with the minute in progress.
                down += Double(model.unsaved.down)
                up += Double(model.unsaved.up)
            }
            let topIdentity = stored?.topApp?.identity
                ?? (isCurrent ? model.liveApps.max { $0.rate < $1.rate }?.identity : nil)
            let color = topIdentity.map { model.visuals.color(for: $0) } ?? model.visuals.color(forKey: nil, in: [:])
            return Petal(hour: hour, start: start, down: down, up: up, color: color, apps: stored?.apps ?? [],
                         isFuture: isToday && hour > currentHour, isCurrent: isCurrent)
        }
    }

    private func load(_ day: Date) async {
        let interval = Calendar.current.dateInterval(of: .day, for: day)!
        async let loadedHours = model.query { try $0.hours(in: interval) }
        async let loadedMoments = model.query { try $0.moments(for: day) }
        let (newHours, newMoments) = await (loadedHours, loadedMoments)
        withAnimation(Theme.softSpring) {
            hours = newHours ?? []
            moments = newMoments ?? []
        }
        for usage in hours.flatMap(\.apps) { model.visuals.cacheColor(usage.app) }
    }
}

/// At most three one-line cards, generated automatically and dismissible.
struct MomentsView: View {
    let moments: [Moment]
    let dismiss: (Moment) -> Void
    let openApp: (AppIdentity) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(moments.prefix(3)) { moment in
                MomentCard(moment: moment, dismiss: { dismiss(moment) }, openApp: openApp)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                            removal: .opacity.combined(with: .scale(scale: 0.92))))
            }
        }
        .animation(Theme.spring, value: moments.map(\.id))
    }
}

private struct MomentCard: View {
    let moment: Moment
    let dismiss: () -> Void
    let openApp: (AppIdentity) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let app = moment.app {
                    AppIconView(identity: app.identity, size: 22)
                        .onTapGesture { openApp(app.identity) }
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            Text(moment.text)
                .font(.system(size: 14, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: hovering)
    }

    private var symbol: String {
        switch moment.kind {
        case .spike: "arrow.up.right"
        case .away: "moon.zzz"
        case .usual: "calendar"
        }
    }
}
