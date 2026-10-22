import SwiftUI
import MonitorEngine

/// A live ribbon of the last 60 seconds: downloads flow above a center line, uploads mirror
/// below in a lighter shade of the same hue. Its color follows whichever app was busiest.
/// No axes or labels; hovering shows that second's numbers.
struct RibbonView: View {
    let height: CGFloat
    /// The hovered second's numbers, shown by the parent in place of its caption.
    @Binding var hoverText: String?
    @Environment(MonitorModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive
    @State private var hoverX: CGFloat?
    @State private var shownScale = MonitorModel.ribbonFloor
    @State private var previousScale = MonitorModel.ribbonFloor
    @State private var scaleChanged = Date.distantPast
    @State private var currentWidth: CGFloat = 0

    static let window: TimeInterval = 60

    var body: some View {
        let points = model.ribbon
        let colors = points.map { model.visuals.color(forKey: $0.colorKey, in: model.identities) }
        // Worked out once per second here, not on every frame.
        let lighterColors = colors.map { $0.uploadShade() }
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !animationsActive || reduceMotion)) { context in
            let now = context.date
            let progress = min(1, now.timeIntervalSince(scaleChanged) / 0.9)
            let scale = previousScale + (shownScale - previousScale) * progress
            Canvas { canvas, size in
                Self.draw(in: &canvas, size: size, points: points, colors: colors, lighterColors: lighterColors, scale: scale,
                          now: reduceMotion ? (points.last?.time ?? now).addingTimeInterval(1) : now, hoverX: hoverX)
            }
        }
        // Rasterize on the GPU rather than the CPU.
        .drawingGroup()
        .frame(height: height)
        .onChange(of: model.ribbonScale, initial: true) { _, new in
            previousScale = shownScale
            shownScale = new
            scaleChanged = Date()
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverX = location.x
                if let point = Self.point(at: location.x, width: currentWidth, points: points) {
                    hoverText = "↓ \(FriendlyBytes.rate(UInt64(point.down)))   ↑ \(FriendlyBytes.rate(UInt64(point.up)))"
                }
            case .ended:
                hoverX = nil
                hoverText = nil
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { currentWidth = $0 }
        .accessibilityElement()
        .accessibilityLabel("Live activity over the last minute")
    }

    /// A soft triangular blur over five seconds: calm swells rather than a jittery line.
    static func smoothed(_ values: [Double]) -> [Double] {
        let weights: [Double] = [1, 2, 3, 2, 1]
        return values.indices.map { index in
            var sum = 0.0
            var weight = 0.0
            for (offset, w) in weights.enumerated() {
                let source = index + offset - 2
                guard values.indices.contains(source) else { continue }
                sum += values[source] * w
                weight += w
            }
            return weight > 0 ? sum / weight : 0
        }
    }

    static func point(at x: CGFloat, width: CGFloat, points: [RibbonPoint]) -> RibbonPoint? {
        guard let last = points.last, width > 0 else { return nil }
        let right = last.time
        let time = right.addingTimeInterval(-window * Double(1 - x / width))
        return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    static func draw(in canvas: inout GraphicsContext, size: CGSize, points: [RibbonPoint], colors: [Color],
                     lighterColors: [Color], scale: Double, now: Date, hoverX: CGFloat?) {
        let mid = size.height / 2
        let half = mid - 3
        // Trail a second behind now, so the newest second is already on screen as it slides in.
        let left = now.addingTimeInterval(-1 - window)
        func x(_ time: Date) -> CGFloat { CGFloat(time.timeIntervalSince(left) / window) * size.width }
        func height(_ value: Double) -> CGFloat { CGFloat(pow(min(max(value, 0) / scale, 1), 0.62)) * half }

        guard points.count >= 2 else {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: size.width, y: mid))
            canvas.stroke(line, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            return
        }
        let downs = smoothed(points.map(\.down))
        let ups = smoothed(points.map(\.up))
        let tops = points.indices.map { CGPoint(x: x(points[$0].time), y: mid - max(0.6, height(downs[$0]))) }
        let bottoms = points.indices.map { CGPoint(x: x(points[$0].time), y: mid + max(0.6, height(ups[$0]))) }

        var stops: [Gradient.Stop] = []
        var lighterStops: [Gradient.Stop] = []
        for index in points.indices {
            let location = x(points[index].time) / size.width
            guard (-0.1...1.1).contains(location) else { continue }
            stops.append(Gradient.Stop(color: colors[index], location: min(1, max(0, location))))
            lighterStops.append(Gradient.Stop(color: lighterColors[index], location: min(1, max(0, location))))
        }
        guard !stops.isEmpty else { return }
        let across = Gradient(stops: stops)
        let lighter = Gradient(stops: lighterStops)
        let horizontal = (start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: 0))

        canvas.drawLayer { layer in
            // Downloads, above the line.
            let downShape = Path.ribbon(edge: tops, baseline: mid, above: true)
            layer.drawLayer { band in
                band.fill(downShape, with: .linearGradient(across, startPoint: horizontal.start, endPoint: horizontal.end))
                band.blendMode = .destinationIn
                band.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: mid)),
                          with: .linearGradient(Gradient(colors: [.white.opacity(0.95), .white.opacity(0.3)]),
                                                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: mid)))
            }
            layer.stroke(Path.smoothLine(through: tops, baseline: mid, above: true),
                         with: .linearGradient(across, startPoint: horizontal.start, endPoint: horizontal.end), lineWidth: 1.3)

            // Uploads, mirrored below in a lighter shade.
            let upShape = Path.ribbon(edge: bottoms, baseline: mid, above: false)
            layer.drawLayer { band in
                band.fill(upShape, with: .linearGradient(lighter, startPoint: horizontal.start, endPoint: horizontal.end))
                band.blendMode = .destinationIn
                band.fill(Path(CGRect(x: 0, y: mid, width: size.width, height: mid)),
                          with: .linearGradient(Gradient(colors: [.white.opacity(0.25), .white.opacity(0.8)]),
                                                startPoint: CGPoint(x: 0, y: mid), endPoint: CGPoint(x: 0, y: size.height)))
            }

            if let hoverX {
                var marker = Path()
                marker.move(to: CGPoint(x: hoverX, y: 4))
                marker.addLine(to: CGPoint(x: hoverX, y: size.height - 4))
                layer.stroke(marker, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }

            // The oldest seconds fade out at the left edge, so the ribbon flows in from nowhere.
            layer.blendMode = .destinationIn
            layer.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .linearGradient(Gradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.16),
                                                              .init(color: .white, location: 0.97), .init(color: .clear, location: 1)]),
                                             startPoint: horizontal.start, endPoint: horizontal.end))
        }
    }
}

extension Path {
    /// A smooth curve through `points` (Catmull-Rom), never crossing the baseline.
    static func smoothLine(through points: [CGPoint], baseline: CGFloat, above: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        path.addSmoothCurve(through: points, baseline: baseline, above: above)
        return path
    }

    /// The area between a smooth edge and the baseline.
    static func ribbon(edge points: [CGPoint], baseline: CGFloat, above: Bool) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: baseline))
        path.addLine(to: first)
        path.addSmoothCurve(through: points, baseline: baseline, above: above)
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.closeSubpath()
        return path
    }

    mutating func addSmoothCurve(through points: [CGPoint], baseline: CGFloat, above: Bool) {
        guard points.count > 1 else { return }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: above ? min(point.y, baseline) : max(point.y, baseline))
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[Swift.max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[Swift.min(index + 2, points.count - 1)]
            let control1 = clamp(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
            let control2 = clamp(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            addCurve(to: p2, control1: control1, control2: control2)
        }
    }
}
