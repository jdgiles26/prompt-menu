import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: SettingsWindowController?
    private var panels: [ResultPanelController] = []
    private var handledService = false
    private lazy var services = ServiceProvider { [weak self] text in
        self?.handledService = true
        self?.showRewrite(of: text)
    }

    // Before the Services request arrives: the result panel's text view needs the Edit menu for ⌘C, ⌘V, ⌘A, ⌘Z.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.servicesProvider = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched by the Services menu, the request arrives right away; otherwise the user opened the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.handledService && self.panels.isEmpty { self.showSettings() }
        }
    }

    // ⌘Q, or a SIGTERM (see below), while a model runs: don't leave the runner behind.
    func applicationWillTerminate(_ notification: Notification) {
        panels.forEach { $0.stop() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showRewrite(of text: String) {
        let panel = ResultPanelController(source: text)
        panel.onClose = { [weak self, weak panel] in
            self?.panels.removeAll { $0 === panel }
            self?.finish()
        }
        panels.append(panel)
        // Offset each new panel so they don't stack exactly.
        if let frame = panels.dropLast().last?.window?.frame {
            panel.window?.setFrameTopLeftPoint(NSPoint(x: frame.minX + 24, y: frame.maxY - 24))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.showWindow(nil)
        panel.window?.orderFrontRegardless()
        panel.start()
    }

    // Opened directly, the app behaves like a regular app (Dock icon, ⌘W, ⌘Q) and quits with its windows.
    private func showSettings() {
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.regular)
            let controller = SettingsWindowController()
            controller.onTryIt = { [weak self] text in self?.showRewrite(of: text) }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window,
                                                   queue: .main) { [weak self] _ in
                self?.settingsWindow = nil
                self?.finish()
            }
            settingsWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // Quit once nothing is on screen, so no model runner or memory is left behind.
    private func finish() {
        DispatchQueue.main.async {
            if self.settingsWindow == nil && self.panels.isEmpty { NSApp.terminate(nil) }
        }
    }

    // Adapted from Finder Menu's helper app.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Prompt Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    @objc private func openSettings(_ sender: Any?) { showSettings() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// A plain SIGTERM (logout, kill, pkill) would skip applicationWillTerminate and orphan the runner,
// so turn it into a normal quit.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()
app.run()
