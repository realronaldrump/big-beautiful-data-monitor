import AppKit
import SwiftUI
import MonitorEngine

extension EnvironmentValues {
    /// False while this view's window or panel cannot be seen; every animation loop pauses then.
    @Entry var animationsActive = true
}

enum Theme {
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .rounded) }
    static func unit(_ size: CGFloat) -> Font { .system(size: size * 0.38, weight: .regular, design: .rounded) }
    /// Springs everywhere; nothing linear or jumpy.
    static let spring = Animation.spring(duration: 0.8, bounce: 0.18)
    static let softSpring = Animation.spring(duration: 1.2, bounce: 0.1)
    /// Slow breathing for pulses: a few seconds per cycle.
    static let pulsePeriod: TimeInterval = 3.4
}

/// One big number in rounded numerals ("2.4 GB") with a small caption beneath.
/// Hovering trades the caption for a relatable equivalent.
struct BigNumberView: View {
    let bytes: UInt64
    let caption: String
    var size: CGFloat = 56
    /// Shown instead of the caption while something else (a petal, a day) is hovered.
    var override: String?
    /// The app behind most of the number, shown by its icon after the caption ("today · mostly [icon]").
    var topApp: AppIdentity?
    @State private var hovering = false

    var body: some View {
        let text = FriendlyBytes.format(bytes)
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        VStack(spacing: size * 0.04) {
            HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
                Text(parts[0])
                    .font(Theme.number(size))
                    .contentTransition(.numericText(value: Double(bytes)))
                Text(parts.count > 1 ? parts[1] : "")
                    .font(Theme.unit(size))
                    .foregroundStyle(.secondary)
            }
            .animation(Theme.spring, value: text)
            let captionSize = max(12, size * 0.22)
            HStack(spacing: captionSize * 0.35) {
                Text(override ?? (hovering ? Equivalent.hdVideo(bytes) : (topApp == nil ? caption : "\(caption) · mostly")))
                    .contentTransition(.opacity)
                if override == nil, !hovering, let topApp {
                    AppIconView(identity: topApp, size: captionSize * 1.4)
                        .transition(.opacity)
                        .help(topApp.displayName)
                }
            }
            .font(.system(size: captionSize, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.35), value: hovering)
            .animation(.easeInOut(duration: 0.25), value: override)
        }
        .monospacedDigit()
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// An app's real icon, or for system groups a soft SF Symbol in a gray circle.
struct AppIconView: View {
    let identity: AppIdentity
    let size: CGFloat
    /// For system groups: just the symbol, larger, without its own gray circle (e.g. inside a bubble).
    var bareSymbol = false
    @Environment(MonitorModel.self) private var model

    var body: some View {
        Group {
            if let icon = model.visuals.icon(for: identity) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if bareSymbol {
                Image(systemName: identity.symbolName ?? "circle.dotted")
                    .font(.system(size: size * 0.5, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: identity.symbolName ?? "circle.dotted")
                    .font(.system(size: size * 0.42, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: size * 0.84, height: size * 0.84)
                    .background(Circle().fill(.gray.opacity(0.18)))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(identity.displayName)
    }
}

/// A soft glow in the app's color that swells with `level` (0–1) and breathes slowly.
struct HaloView: View {
    let color: Color
    let level: Double
    let diameter: CGFloat
    /// Live halos pulse with their usage as it changes each second; resting ones breathe instead.
    var breathes = true

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.18 + 0.5 * level), color.opacity(0)],
                                 center: .center, startRadius: diameter * 0.18, endRadius: diameter * 0.5))
            .scaleEffect(0.75 + 0.35 * level)
            .opacity(level < 0.02 ? 0 : 1)
            .animation(Theme.softSpring, value: level)
            .breathing(scale: 0.07 * level, enabled: breathes && level >= 0.05)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

/// A slow pulse, a few seconds per cycle, run as one repeating animation rather than a frame
/// loop. It stops while its window cannot be seen, and with Reduce Motion on.
struct Breathing: ViewModifier {
    var scale: CGFloat = 0
    var fade: Double = 0
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive
    @State private var resting = true

    private var active: Bool { enabled && animationsActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(resting ? 1 : 1 + scale)
            .opacity(resting ? 1 : 1 - fade)
            .onAppear { if active { start() } }
            .onChange(of: active) { _, isActive in isActive ? start() : stop() }
    }

    private func start() {
        withAnimation(.easeInOut(duration: Theme.pulsePeriod / 2).repeatForever(autoreverses: true)) { resting = false }
    }

    private func stop() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { resting = true }
    }
}

extension View {
    func breathing(scale: CGFloat = 0, fade: Double = 0, enabled: Bool = true) -> some View {
        modifier(Breathing(scale: scale, fade: fade, enabled: enabled))
    }
}

/// Small glass circle button with a symbol (for stepping days and months).
struct StepButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

extension View {
    /// Development builds can preview Reduce Motion with -forceReduceMotion YES.
    func developmentOverrides() -> some View {
        #if DEBUG
        return environment(\._accessibilityReduceMotion,
                           UserDefaults.standard.bool(forKey: "forceReduceMotion") ? true : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        #else
        return self
        #endif
    }
}
