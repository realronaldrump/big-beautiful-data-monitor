import AppKit
import SwiftUI

/// A borderless glass panel that drops down from the menu bar, like Control Center.
final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopoverController: NSObject, NSWindowDelegate {
    private let panel = PopoverPanel()
    private let model: MonitorModel
    private let openWindow: () -> Void
    private var monitors: [Any] = []
    private weak var button: NSStatusBarButton?
    private var closedAt = Date.distantPast

    init(model: MonitorModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        panel.delegate = self
    }

    func toggle(from button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            // (A click on the menu bar item also closes the panel by taking focus; do not reopen it.)
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton) {
        self.button = button
        let content = PopoverView(model: model,
                                  openWindow: { [weak self] in self?.close(); self?.openWindow() },
                                  openApp: { [weak self] app in
                                      self?.close()
                                      self?.model.detailApp = app
                                      self?.openWindow()
                                  },
                                  dismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: content)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 26
        glass.contentView = hosting
        let size = hosting.fittingSize

        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)

        panel.contentView = glass
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        model.isPopoverOpen = true

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "keepPopoverOpen") { return }
        #endif
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.close() }
            return nil
        } as Any)
    }

    func close() {
        guard panel.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        button?.highlight(false)
        closedAt = Date()
        model.isPopoverOpen = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isPopoverOpen else { return }
                self.panel.orderOut(nil)
                // Tear the SwiftUI content down so nothing animates while closed.
                self.panel.contentView = nil
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "keepPopoverOpen") { return }
        #endif
        // Menus and alerts opened from the panel take focus briefly; only close for real departures.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, NSApp.modalWindow == nil,
                  !(NSApp.keyWindow?.className.contains("Menu") ?? false) else { return }
            self.close()
        }
    }
}
