import SwiftUI
import MonitorEngine
import UsageStore

/// One hour of the ring.
struct Petal: Identifiable, Equatable {
    let hour: Int
    let start: Date
    var down: Double
    var up: Double
    var color: Color {
        didSet { upColor = color.uploadShade() }
    }
    /// The lighter shade for uploads, worked out once rather than on every frame.
    private(set) var upColor: Color
    var apps: [AppUsage]
    var isFuture: Bool
    var isCurrent: Bool
    var id: Int { hour }
    var total: Double { down + up }

    init(hour: Int, start: Date, down: Double, up: Double, color: Color, apps: [AppUsage], isFuture: Bool, isCurrent: Bool) {
        self.hour = hour
        self.start = start
        self.down = down
        self.up = up
        self.color = color
        self.upColor = color.uploadShade()
        self.apps = apps
        self.isFuture = isFuture
        self.isCurrent = isCurrent
    }
}

/// A 24-hour ring like a clock face, midnight at the top. Each hour is a petal whose length is
/// that hour's usage: downloads reach outward, uploads reach inward in a lighter shade.
struct DayRingView: View {
    let petals: [Petal]
    let diameter: CGFloat
    var interactive = true
    @Binding var hovered: Int?
    @Binding var bloom: Int?
    var openApp: (AppIdentity) -> Void = { _ in }
    private var baseRadius: CGFloat { diameter * 0.3 }
    private var outward: CGFloat { diameter * 0.18 }
    private var inward: CGFloat { baseRadius * 0.34 }
    private var petalWidth: CGFloat { 2 * .pi * baseRadius / 24 * 0.56 }

    var body: some View {
        let peak = max(1, petals.map { max($0.down, $0.up) }.max() ?? 1)
        ZStack {
            // Four faint dots mark midnight, 6, noon and 18; no numbers at rest.
            ForEach([0, 6, 12, 18], id: \.self) { hour in
                Circle()
                    .fill(.secondary.opacity(hour == 0 ? 0.5 : 0.28))
                    .frame(width: hour == 0 ? 4 : 3, height: hour == 0 ? 4 : 3)
                    .offset(y: -min(baseRadius + outward + 13, diameter / 2 - 2))
                    .rotationEffect(.degrees(Double(hour) * 15))
            }
            ForEach(petals) { petal in
                petalView(petal, peak: peak)
                    .breathing(fade: 0.24, enabled: petal.isCurrent)
            }
            if let bloom, let petal = petals.first(where: { $0.hour == bloom }), !petal.apps.isEmpty {
                bloomView(petal, peak: peak)
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onContinuousHover { phase in
            guard interactive else { return }
            switch phase {
            case .active(let location): hovered = hour(at: location)
            case .ended: hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            guard interactive else { return }
            let hour = hour(at: value.location)
            withAnimation(Theme.spring) { bloom = (hour == nil || hour == bloom) ? nil : hour }
        })
        .animation(Theme.softSpring, value: petals.map { [$0.down, $0.up] })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage by hour")
    }

    @ViewBuilder
    private func petalView(_ petal: Petal, peak: Double) -> some View {
        let angle = Angle.degrees(Double(petal.hour) * 15 + 7.5)
        let dimmed = (hovered != nil && hovered != petal.hour) || (bloom != nil && bloom != petal.hour)
        let opacity = petal.isFuture ? 0.12 : (dimmed ? 0.4 : 1)
        if petal.total <= 0 {
            Circle()
                .fill(.secondary.opacity(petal.isFuture ? 0.35 : 0.3))
                .frame(width: petalWidth * 0.32, height: petalWidth * 0.32)
                .offset(y: -baseRadius)
                .rotationEffect(angle)
                .opacity(opacity)
        } else {
            // One petal per hour, crossing the ring's line: downloads reach outward, uploads inward
            // in a lighter shade of the same hue (only when there is enough to see).
            let outLength = petal.down > 0 ? max(petalWidth, outward * CGFloat((petal.down / peak).squareRoot())) : 0
            let showsUp = petal.up / peak > 0.02
            let inLength = showsUp ? min(inward, outward * CGFloat((petal.up / peak).squareRoot())) : 0
            let length = max(petalWidth, outLength + inLength)
            let split = length > 0 ? outLength / length : 1
            Capsule()
                .fill(LinearGradient(stops: [
                    .init(color: petal.color, location: 0),
                    .init(color: petal.color.opacity(0.82), location: max(0, split - 0.001)),
                    .init(color: petal.upColor, location: split),
                    .init(color: petal.upColor.opacity(0.85), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .frame(width: petalWidth, height: length)
                .offset(y: -(baseRadius - inLength + length / 2))
            .rotationEffect(angle)
            .opacity(opacity)
            .shadow(color: petal.color.opacity(hovered == petal.hour ? 0.5 : 0), radius: 8)
        }
    }

    /// Clicking a petal blooms that hour's app icons around its tip.
    private func bloomView(_ petal: Petal, peak: Double) -> some View {
        let apps = Array(petal.apps.prefix(5))
        let center = Double(petal.hour) * 15 + 7.5
        let reach = baseRadius + outward + 34
        return ZStack {
            ForEach(Array(apps.enumerated()), id: \.element.app.id) { index, usage in
                let degrees = center + (Double(index) - Double(apps.count - 1) / 2) * 12
                let radians = (degrees - 90) * .pi / 180
                BloomIcon(usage: usage)
                    .offset(x: reach * cos(radians), y: reach * sin(radians))
                    .onTapGesture { openApp(usage.app.identity) }
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    private func hour(at location: CGPoint) -> Int? {
        let dx = location.x - diameter / 2
        let dy = location.y - diameter / 2
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > baseRadius * 0.55, distance < baseRadius + outward + 26 else { return nil }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let hour = Int(degrees / 15) % 24
        return petals.contains { $0.hour == hour && !$0.isFuture } ? hour : nil
    }
}

private struct BloomIcon: View {
    let usage: AppUsage
    @Environment(MonitorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        ZStack {
            HaloView(color: model.visuals.color(for: usage.app.identity), level: 0.45, diameter: 50)
            AppIconView(identity: usage.app.identity, size: 30)
        }
        .scaleEffect(hovering ? 1.12 : 1)
        .animation(Theme.spring, value: hovering)
        .onHover { hovering = $0 }
        .help("\(usage.app.identity.displayName) · \(FriendlyBytes.format(usage.bytes.total))")
    }
}
