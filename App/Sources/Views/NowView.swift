import SwiftUI
import MonitorEngine

/// A calm pond of floating glass bubbles, one per active app. Busy apps swell, idle ones shrink
/// and fade away. Particles drift into a bubble for downloads and out of it for uploads.
/// Today's total rests at the center.
struct NowView: View {
    @Environment(MonitorModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive
    @State private var pond = PondSimulation()
    @State private var hovered: String?

    /// Icons are rendered once at this size and scaled per bubble, so they stay crisp.
    nonisolated private static let iconSize: CGFloat = 96

    var body: some View {
        GeometryReader { geometry in
            let apps = Array(model.liveApps.sorted { $0.rate > $1.rate }.prefix(10))
            let colors = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, model.visuals.color(for: $0.identity)) })
            ZStack {
                // The whole pond is one canvas: cheap enough to stay smooth at 30 frames a second.
                TimelineView(.animation(minimumInterval: reduceMotion ? 1 / 15 : 1 / 24, paused: !animationsActive)) { context in
                    let state = pond.step(apps: apps, colors: colors, size: geometry.size, now: context.date, reduceMotion: reduceMotion)
                    Canvas { canvas, _ in
                        for particle in state.particles {
                            let size = particle.size
                            canvas.fill(Path(ellipseIn: CGRect(x: particle.position.x - size / 2, y: particle.position.y - size / 2,
                                                               width: size, height: size)),
                                        with: .color(particle.color.opacity(particle.alpha)))
                        }
                        for bubble in state.bubbles {
                            Self.draw(bubble, highlighted: hovered == bubble.id, in: &canvas)
                        }
                    } symbols: {
                        ForEach(state.bubbles) { bubble in
                            AppIconView(identity: bubble.identity, size: Self.iconSize, bareSymbol: true)
                                .tag(bubble.id)
                        }
                    }
                }
                // Rasterize on the GPU rather than the CPU.
                .drawingGroup()
                BigNumberView(bytes: model.today.total, caption: "today", size: 68, override: hoverCaption, topApp: model.topAppToday)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 14)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hovered = pond.bubble(at: location)?.id
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let bubble = pond.bubble(at: value.location) { model.detailApp = bubble.identity }
            })
            .animation(Theme.spring, value: hovered)
        }
        .padding(.top, 40)
    }

    /// A glass bubble drawn by hand: a soft glow in the app's color, a translucent body,
    /// a light rim and a highlight, with the app's icon inside.
    nonisolated private static func draw(_ bubble: PondSimulation.Bubble, highlighted: Bool, in canvas: inout GraphicsContext) {
        let radius = bubble.radius * (highlighted ? 1.05 : 1)
        let center = bubble.position
        let color = bubble.color
        canvas.drawLayer { layer in
            layer.opacity = bubble.opacity
            let glow = CGRect(x: center.x - radius * 1.5, y: center.y - radius * 1.5, width: radius * 3, height: radius * 3)
            layer.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(colors: [color.opacity(0.4), color.opacity(0)]), center: center,
                startRadius: radius * 0.6, endRadius: radius * 1.5))

            let body = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            layer.fill(body, with: .radialGradient(
                Gradient(stops: [.init(color: .white.opacity(0.16), location: 0),
                                 .init(color: color.opacity(0.10), location: 0.55),
                                 .init(color: color.opacity(0.26), location: 1)]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35),
                startRadius: 0, endRadius: radius * 1.35))
            layer.stroke(body, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0.08), color.opacity(0.35)]),
                startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
                endPoint: CGPoint(x: center.x + radius, y: center.y + radius)), lineWidth: 1)
            let shine = CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.82, width: radius * 0.9, height: radius * 0.42)
            layer.fill(Path(ellipseIn: shine), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.28), .white.opacity(0)]),
                startPoint: CGPoint(x: shine.midX, y: shine.minY), endPoint: CGPoint(x: shine.midX, y: shine.maxY)))

            if let icon = layer.resolveSymbol(id: bubble.id) {
                let scale = radius * 1.02 / iconSize
                layer.translateBy(x: center.x, y: center.y)
                layer.scaleBy(x: scale, y: scale)
                layer.draw(icon, at: .zero)
            }
        }
    }

    private var hoverCaption: String? {
        guard let hovered, let identity = model.identity(forKey: hovered) else { return nil }
        let live = model.liveApps.first { $0.id == hovered }
        let today = FriendlyBytes.format(model.todayByApp[hovered]?.total ?? 0)
        if let live, live.rate >= 1_000 {
            return "\(identity.displayName) · \(FriendlyBytes.rate(UInt64(live.rate))) now · \(today) today"
        }
        return "\(identity.displayName) · \(today) today"
    }
}

/// Gentle physics for the pond: bubbles drift on a slow current around the center, keep a
/// polite distance from each other and from the total, and grow or shrink with springs.
@MainActor
final class PondSimulation {
    struct Bubble: Identifiable {
        let identity: AppIdentity
        var color: Color
        var position: CGPoint
        var velocity = CGVector.zero
        var radius: CGFloat
        var opacity: Double = 0
        var down: Double = 0
        var up: Double = 0
        var active = true
        let seed: Double
        var id: String { identity.key }
    }

    struct Particle {
        let key: String
        var position: CGPoint
        var velocity: CGVector
        var age: Double = 0
        let lifetime: Double
        let inbound: Bool
        let color: Color
        let size: CGFloat
        var alpha: Double = 0
    }

    struct State {
        var bubbles: [Bubble]
        var particles: [Particle]
    }

    private var bubbles: [String: Bubble] = [:]
    private var order: [String] = []
    private var lastDrawn: [Bubble] = []

    /// The bubble under a point, from the last drawn frame.
    func bubble(at point: CGPoint) -> Bubble? {
        lastDrawn.last { bubble in
            bubble.opacity > 0.3 && hypot(bubble.position.x - point.x, bubble.position.y - point.y) <= bubble.radius
        }
    }
    private var particles: [Particle] = []
    private var lastTime: Date?
    private var spawnDebt: [String: Double] = [:]

    func step(apps: [LiveApp], colors: [String: Color], size: CGSize, now: Date, reduceMotion: Bool) -> State {
        let dt = min(1.0 / 20, max(0, now.timeIntervalSince(lastTime ?? now)))
        lastTime = now
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + 14)
        let ring = CGSize(width: size.width * 0.34, height: size.height * 0.33)
        let base = min(size.width, size.height)
        let minRadius: CGFloat = 26
        let maxRadius = max(minRadius + 10, base * 0.13)

        // Arrivals and departures.
        let live = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for app in apps where bubbles[app.id] == nil {
            let angle = freeAngle(center: center, ring: ring)
            bubbles[app.id] = Bubble(identity: app.identity, color: colors[app.id] ?? .gray,
                                     position: CGPoint(x: center.x + ring.width * cos(angle), y: center.y + ring.height * sin(angle)),
                                     radius: minRadius * 0.6, seed: Double(order.count) * 1.7 + Double(abs(app.id.hashValue % 1000)) / 100)
            order.append(app.id)
        }
        for key in order {
            guard var bubble = bubbles[key] else { continue }
            if let app = live[key] {
                bubble.down = app.down
                bubble.up = app.up
                bubble.active = true
                if let color = colors[key] { bubble.color = color }
            } else {
                bubble.active = false
                bubble.down = 0
                bubble.up = 0
            }
            bubbles[key] = bubble
        }

        let time = now.timeIntervalSinceReferenceDate
        let keys = order
        for (index, key) in keys.enumerated() {
            guard var bubble = bubbles[key] else { continue }
            let level = MonitorModel.level(forRate: bubble.down + bubble.up)
            let targetRadius = bubble.active ? minRadius + (maxRadius - minRadius) * CGFloat(pow(level, 0.9)) : minRadius * 0.6
            let targetOpacity = bubble.active ? (level < 0.05 ? 0.75 : 1) : 0
            let ease = 1 - exp(-dt * (reduceMotion ? 3 : 1.6))
            bubble.radius += (targetRadius - bubble.radius) * ease
            bubble.opacity += (targetOpacity - bubble.opacity) * (1 - exp(-dt * 1.4))

            if reduceMotion {
                // Drift becomes stillness: bubbles rest at evenly spaced places on the ring.
                let angle = Double(index) / Double(max(keys.count, 1)) * 2 * .pi - .pi / 2
                bubble.position = CGPoint(x: center.x + ring.width * cos(angle), y: center.y + ring.height * sin(angle))
                bubbles[key] = bubble
                continue
            }

            var force = CGVector.zero
            // A soft spring toward the ring around the total.
            let offset = CGVector(dx: bubble.position.x - center.x, dy: bubble.position.y - center.y)
            let angle = atan2(offset.dy / ring.height, offset.dx / ring.width)
            let onRing = CGPoint(x: center.x + ring.width * cos(angle), y: center.y + ring.height * sin(angle))
            force.dx += (onRing.x - bubble.position.x) * 0.5
            force.dy += (onRing.y - bubble.position.y) * 0.5
            // A slow current around the pond, plus a little wandering.
            force.dx += -sin(angle) * 7 + cos(time * 0.13 + bubble.seed) * 5
            force.dy += cos(angle) * 7 + sin(time * 0.11 + bubble.seed * 1.3) * 5
            // Polite distance from the others.
            for other in keys where other != key {
                guard let neighbor = bubbles[other], neighbor.opacity > 0.05 else { continue }
                let dx = bubble.position.x - neighbor.position.x
                let dy = bubble.position.y - neighbor.position.y
                let distance = max(1, sqrt(dx * dx + dy * dy))
                let comfortable = bubble.radius + neighbor.radius + 22
                if distance < comfortable {
                    let push = (comfortable - distance) * 2.2
                    force.dx += dx / distance * push
                    force.dy += dy / distance * push
                }
            }
            // Keep clear of the total in the middle.
            let ellipse = sqrt(pow(offset.dx / (150 + bubble.radius), 2) + pow(offset.dy / (82 + bubble.radius), 2))
            if ellipse < 1 {
                let length = max(1, sqrt(offset.dx * offset.dx + offset.dy * offset.dy))
                force.dx += offset.dx / length * (1 - ellipse) * 160
                force.dy += offset.dy / length * (1 - ellipse) * 160
            }
            // And inside the window.
            let margin = bubble.radius + 12
            if bubble.position.x < margin { force.dx += (margin - bubble.position.x) * 3 }
            if bubble.position.x > size.width - margin { force.dx -= (bubble.position.x - (size.width - margin)) * 3 }
            if bubble.position.y < margin { force.dy += (margin - bubble.position.y) * 3 }
            if bubble.position.y > size.height - margin { force.dy -= (bubble.position.y - (size.height - margin)) * 3 }

            bubble.velocity.dx = (bubble.velocity.dx + force.dx * dt) * exp(-dt * 1.4)
            bubble.velocity.dy = (bubble.velocity.dy + force.dy * dt) * exp(-dt * 1.4)
            bubble.position.x += bubble.velocity.dx * dt
            bubble.position.y += bubble.velocity.dy * dt
            bubbles[key] = bubble
            if !reduceMotion { spawnParticles(for: bubble, dt: dt) }
        }

        // Faded-out bubbles leave the pond.
        for key in order where bubbles[key].map({ !$0.active && $0.opacity < 0.02 }) ?? true {
            bubbles[key] = nil
        }
        order.removeAll { bubbles[$0] == nil }

        if reduceMotion { particles.removeAll() } else { moveParticles(dt: dt) }
        lastDrawn = order.compactMap { bubbles[$0] }
        return State(bubbles: lastDrawn, particles: particles)
    }

    private func freeAngle(center: CGPoint, ring: CGSize) -> Double {
        let candidates = (0..<16).map { Double($0) / 16 * 2 * .pi + 0.2 }
        return candidates.max { a, b in clearance(a, center: center, ring: ring) < clearance(b, center: center, ring: ring) } ?? 0
    }

    private func clearance(_ angle: Double, center: CGPoint, ring: CGSize) -> CGFloat {
        let point = CGPoint(x: center.x + ring.width * cos(angle), y: center.y + ring.height * sin(angle))
        return bubbles.values.map { hypot($0.position.x - point.x, $0.position.y - point.y) }.min() ?? .greatestFiniteMagnitude
    }

    private func spawnParticles(for bubble: Bubble, dt: Double) {
        guard bubble.active, particles.count < 280 else { return }
        let downRate = 30 * MonitorModel.level(forRate: bubble.down)
        let upRate = 30 * MonitorModel.level(forRate: bubble.up)
        let downKey = bubble.id + ".down"
        let upKey = bubble.id + ".up"
        spawnDebt[downKey, default: 0] += downRate * dt
        spawnDebt[upKey, default: 0] += upRate * dt
        while spawnDebt[downKey, default: 0] >= 1 {
            spawnDebt[downKey]! -= 1
            let angle = Double.random(in: 0..<(2 * .pi))
            let distance = bubble.radius + CGFloat.random(in: 50...110)
            particles.append(Particle(key: bubble.id,
                                      position: CGPoint(x: bubble.position.x + distance * cos(angle), y: bubble.position.y + distance * sin(angle)),
                                      velocity: .zero, lifetime: 4, inbound: true, color: bubble.color,
                                      size: CGFloat.random(in: 2...3.6)))
        }
        while spawnDebt[upKey, default: 0] >= 1 {
            spawnDebt[upKey]! -= 1
            let angle = Double.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: 26...44)
            particles.append(Particle(key: bubble.id,
                                      position: CGPoint(x: bubble.position.x + bubble.radius * cos(angle), y: bubble.position.y + bubble.radius * sin(angle)),
                                      velocity: CGVector(dx: speed * cos(angle), dy: speed * sin(angle)),
                                      lifetime: Double.random(in: 1.4...2.2), inbound: false, color: bubble.color.uploadShade(),
                                      size: CGFloat.random(in: 1.8...3)))
        }
    }

    private func moveParticles(dt: Double) {
        particles = particles.compactMap { particle in
            var particle = particle
            particle.age += dt
            guard particle.age < particle.lifetime else { return nil }
            if particle.inbound {
                guard let target = bubbles[particle.key] else { return nil }
                let dx = target.position.x - particle.position.x
                let dy = target.position.y - particle.position.y
                let distance = max(1, sqrt(dx * dx + dy * dy))
                if distance < target.radius * 0.85 { return nil }
                let speed: CGFloat = 38 + 30 * CGFloat(particle.age)
                particle.velocity = CGVector(dx: dx / distance * speed, dy: dy / distance * speed)
                let fadeIn = min(1, particle.age / 0.5)
                let fadeOut = min(1, (distance - target.radius * 0.85) / 30)
                particle.alpha = 0.75 * fadeIn * fadeOut
            } else {
                particle.velocity.dx *= exp(-dt * 0.6)
                particle.velocity.dy *= exp(-dt * 0.6)
                particle.alpha = 0.7 * min(1, particle.age / 0.25) * (1 - particle.age / particle.lifetime)
            }
            particle.position.x += particle.velocity.dx * dt
            particle.position.y += particle.velocity.dy * dt
            return particle
        }
    }
}
