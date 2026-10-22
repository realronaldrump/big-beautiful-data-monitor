import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    private var statusItem: StatusItemController?
    private var popover: PopoverController?
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainWindow = MainWindowController(model: model)
        self.mainWindow = mainWindow
        let popover = PopoverController(model: model) { [weak self] in self?.mainWindow?.show() }
        self.popover = popover
        statusItem = StatusItemController(model: model) { button in popover.toggle(from: button) }
        model.onMenuBarChange = { [weak self] in self?.statusItem?.refresh() }
        NSApp.mainMenu = Self.makeMainMenu(target: self)

        model.start()
        LoginItem.enableOnFirstLaunch()
        model.opensAtLogin = LoginItem.isEnabled
        Log.engine.info("Started. Opens at login: \(LoginItem.isEnabled, privacy: .public)")

        // The very first time, show where the app lives. After that it stays quiet.
        if !UserDefaults.standard.bool(forKey: "didShowWelcome"), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.popover?.show(from: button)
            }
        }

        // Stop on sleep, restart on wake. Sampling continues when only the display is off,
        // since overnight iCloud and update traffic is part of the story.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.sleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.wake() }
        }
        #if DEBUG
        runDevelopmentSwitches()
        #endif
    }

    #if DEBUG
    /// Launch switches for checking the design: -showPopover YES, -showWindow day, -showApp <key>,
    /// -showDay 2026-10-14, -dumpMenuBarIcons /folder.
    private func runDevelopmentSwitches() {
        let defaults = UserDefaults.standard
        if let appearance = defaults.string(forKey: "forceAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let folder = defaults.string(forKey: "dumpMenuBarIcons") {
            for level in [0.0, 0.35, 0.7, 1.0] {
                let image = MenuBarWave.image(level: level, attention: level == 1)
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(filePath: folder).appending(path: "wave-\(Int(level * 100)).png"))
                }
            }
        }
        let sleepAfter = defaults.double(forKey: "simulateSleepAfter")
        if sleepAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + sleepAfter) { [weak self] in
                print("Simulated sleep")
                self?.model.sleep()
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    print("Simulated wake")
                    self?.model.wake()
                }
            }
        }
        if let day = defaults.string(forKey: "showDay"), let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) {
            model.shownDay = date
        }
        if let tab = defaults.string(forKey: "showWindow") {
            model.mainTab = MainTab(rawValue: tab.capitalized) ?? .now
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.mainWindow?.show()
                if let key = defaults.string(forKey: "showApp") {
                    self?.model.detailApp = self?.model.identity(forKey: key)
                }
            }
        }
        if let path = defaults.string(forKey: "renderPopoverTo") {
            // Renders the panel's content off screen (works even with the display asleep).
            model.isPopoverOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                let content = PopoverView(model: self.model, openWindow: {}, openApp: { _ in }, dismiss: {})
                    .background(Color(nsColor: defaults.string(forKey: "forceAppearance") == "light" ? .white : NSColor(white: 0.16, alpha: 1)))
                    .environment(\.colorScheme, defaults.string(forKey: "forceAppearance") == "light" ? .light : .dark)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(filePath: path))
                }
            }
        }
        if defaults.bool(forKey: "showPopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.popover?.show(from: button)
            }
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    // MARK: - Menu (invisible for a menu bar app, but gives the window its keyboard shortcuts)

    @objc func showNow() { show(.now) }
    @objc func showDay() { show(.day) }
    @objc func showMonth() { show(.month) }

    private func show(_ tab: MainTab) {
        model.mainTab = tab
        mainWindow?.show()
    }

    private static func makeMainMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Big Beautiful Data Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (title, action, key) in [("Now", #selector(showNow), "1"), ("Day", #selector(showDay), "2"), ("Month", #selector(showMonth), "3")] {
            let item = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = target
        }
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        return menu
    }
}
