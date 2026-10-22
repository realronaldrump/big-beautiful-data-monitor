import AppKit
import MonitorEngine

/// The menu bar item: a small monochrome wave that rises and falls with live activity,
/// redrawn once a second (no animation loop), with the live speed beside it if wanted.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: MonitorModel
    private let onClick: (NSStatusBarButton) -> Void

    private static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
    /// Fixed width for the speed, so the menu bar does not shuffle as the number changes.
    private static let speedWidth = ceil(("888 KB/s" as NSString).size(withAttributes: [.font: speedFont]).width)

    init(model: MonitorModel, onClick: @escaping (NSStatusBarButton) -> Void) {
        self.model = model
        self.onClick = onClick
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Big Beautiful Data Monitor")
            button.toolTip = nil
        }
        refresh()
    }

    var button: NSStatusBarButton? { item.button }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        onClick(sender)
    }

    private var shownStep = -1
    private var shownAttention = false
    private var shownSpeed: String?

    /// Called every second; touches the menu bar only when something visibly changed,
    /// so a quiet Mac costs next to nothing.
    func refresh() {
        guard let button = item.button else { return }
        // Redraw only for a real change: a little hysteresis keeps faint background traffic
        // from nudging the wave (and waking the menu bar) every second.
        let raw = model.menuLevel * Double(MenuBarWave.steps)
        let step = abs(raw - Double(shownStep)) >= 0.75 ? Int(raw.rounded()) : shownStep
        let attention = !model.perAppAvailable
        if step != shownStep || attention != shownAttention {
            button.image = MenuBarWave.image(level: Double(step) / Double(MenuBarWave.steps), attention: attention)
            shownStep = step
            shownAttention = attention
        }
        let speed = model.showSpeedInMenuBar ? FriendlyBytes.rate(UInt64(model.currentRate)) : nil
        guard speed != shownSpeed else { return }
        if let speed {
            button.attributedTitle = NSAttributedString(string: speed, attributes: [.font: Self.speedFont])
            if shownSpeed == nil {
                button.imagePosition = .imageLeading
                item.length = MenuBarWave.size.width + Self.speedWidth + 14
            }
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.variableLength
        }
        shownSpeed = speed
    }
}

/// Draws the menu bar wave as a template image, so it matches the menu bar in light and dark.
enum MenuBarWave {
    static let size = NSSize(width: 22, height: 16)
    /// Levels are drawn in 12 steps: finer changes would not be visible at menu bar size.
    static let steps = 12

    /// `level` is 0 (idle: a calm, nearly flat wave) to 1 (very busy). `attention` adds a small dot,
    /// shown only when per-app numbers are unavailable after a macOS update.
    static func image(level: Double, attention: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let midY = rect.midY
            let inset: CGFloat = 2
            let width = rect.width - inset * 2
            let amplitude = 1.3 + CGFloat(level) * 5.2
            let steps = 44
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                // Two soft crests, tapering at both ends so it reads as a wave, not a line.
                let envelope = sin(t * .pi)
                let y = midY + amplitude * envelope * sin(t * .pi * 3 - .pi / 2 + 0.6)
                let point = NSPoint(x: inset + t * width, y: y)
                step == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            if attention {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
