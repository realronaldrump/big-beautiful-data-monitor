import AppKit
import SwiftUI

/// The main window: Now, Day and Month behind a quiet segmented control.
/// Its SwiftUI content exists only while the window is open, so nothing animates when closed.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: MonitorModel
    private var window: NSWindow?

    init(model: MonitorModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.isWindowVisible = true
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Big Beautiful Data Monitor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 640)
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 880, height: 720))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.isWindowVisible = false
        model.detailApp = nil
        window?.contentViewController = nil
        window = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        model.isWindowVisible = window.isVisible && window.occlusionState.contains(.visible)
    }
}
