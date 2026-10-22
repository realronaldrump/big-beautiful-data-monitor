import AppKit
import SwiftUI
import MonitorEngine

/// The frosted panel under the menu bar: today's total, a live ribbon of the last minute,
/// and the apps moving data right now.
struct PopoverView: View {
    let model: MonitorModel
    let openWindow: () -> Void
    let openApp: (AppIdentity) -> Void
    let dismiss: () -> Void
    @State private var ribbonHover: String?

    var body: some View {
        VStack(spacing: 12) {
            BigNumberView(bytes: model.today.total, caption: "today", size: 54, override: ribbonHover, topApp: model.topAppToday)
                .padding(.top, 24)
            RibbonView(height: 78, hoverText: $ribbonHover)
            ActiveAppsRow(openApp: openApp)
            HStack {
                Button(action: openWindow) {
                    Label("Open", systemImage: "macwindow")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                Spacer()
                SettingsMenu(model: model, dismiss: dismiss)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 332)
        .environment(model)
        .environment(\.animationsActive, model.isPopoverOpen)
        .developmentOverrides()
    }
}

/// The 3 to 5 apps active right now, as icons with soft halos that pulse with their live usage.
/// When fewer are active, today's busiest apps rest beside them, quietly and without a halo.
struct ActiveAppsRow: View {
    let openApp: (AppIdentity) -> Void
    @Environment(MonitorModel.self) private var model
    @State private var hovered: String?

    private struct Slot: Identifiable {
        let identity: AppIdentity
        let level: Double
        let active: Bool
        var id: String { identity.key }
    }

    private var slots: [Slot] {
        let live = model.liveApps
        // The five busiest, kept in the order they arrived so icons do not jump around.
        let busiest = Set(live.sorted { $0.rate > $1.rate }.prefix(5).map(\.id))
        var slots = live.filter { busiest.contains($0.id) }.map {
            Slot(identity: $0.identity, level: MonitorModel.level(forRate: $0.rate), active: true)
        }
        if slots.count < 3 {
            let present = Set(slots.map(\.id))
            let quiet = model.todayByApp.sorted { $0.value.total > $1.value.total }
                .compactMap { model.identity(forKey: $0.key) }
                .filter { !present.contains($0.key) && $0.key != AppIdentity.macSystem.key }
            for identity in quiet.prefix(3 - slots.count) {
                slots.append(Slot(identity: identity, level: 0, active: false))
            }
        }
        return slots
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                ForEach(slots) { slot in
                    ZStack {
                        HaloView(color: model.visuals.color(for: slot.identity), level: slot.level, diameter: 60, breathes: false)
                        AppIconView(identity: slot.identity, size: 36)
                            .opacity(slot.active ? 1 : 0.5)
                            .scaleEffect(hovered == slot.id ? 1.08 : 1)
                    }
                    .frame(width: 52, height: 60)
                    .contentShape(Circle())
                    .onHover { hovered = $0 ? slot.id : (hovered == slot.id ? nil : hovered) }
                    .onTapGesture { openApp(slot.identity) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: slots.map(\.id))
            .animation(Theme.spring, value: hovered)
            .frame(height: 60)

            Text(caption)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(height: 16)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: caption)
        }
    }

    private var caption: String {
        if let hovered, let identity = model.identity(forKey: hovered) ?? slots.first(where: { $0.id == hovered })?.identity {
            let bytes = model.todayByApp[hovered]?.total ?? 0
            return "\(identity.displayName) · \(FriendlyBytes.format(bytes)) today"
        }
        return slots.isEmpty ? "All quiet" : ""
    }
}

/// The small menu: the only three settings, plus Quit.
struct SettingsMenu: View {
    @Bindable var model: MonitorModel
    let dismiss: () -> Void

    var body: some View {
        Menu {
            Toggle("Open at login", isOn: $model.opensAtLogin)
            Toggle("Show speed in menu bar", isOn: $model.showSpeedInMenuBar)
            Divider()
            Button("Reset data…", action: confirmReset)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
    }

    private func confirmReset() {
        dismiss()
        DispatchQueue.main.async {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Erase all usage history?"
            alert.informativeText = "Counting starts again from now. This can't be undone."
            let erase = alert.addButton(withTitle: "Erase")
            erase.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                model.resetData()
            }
        }
    }
}
