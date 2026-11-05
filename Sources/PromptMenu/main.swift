import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settingsWindow: SettingsWindowController?
    private var panels: [ResultPanelController] = []
    private var handledService = false
    private var replacing = false
    private var reading = 0  // Finder items being read for Explain; the app mustn't quit meanwhile.
    private var failurePanels: [FailurePanelController] = []
    private var warm: WarmRunner?
    private var statusItem: NSStatusItem?
    private let modelMenus = NSHashTable<NSMenu>.weakObjects()
    private lazy var services = ServiceProvider(
        onText: { [weak self] text, style in
            self?.handledService = true
            self?.showRewrite(of: text, style: style)
        },
        replace: { [weak self] text in
            self?.replaceInPlace(text) ?? .failure(RewriteError.emptyOutput)
        },
        onFailure: { [weak self] error, files in
            self?.showFailure(error, files: files)
        },
        onFiles: { [weak self] files in
            self?.explain(files)
        })

    // Before the Services request arrives: the result panel's text view needs the Edit menu for ⌘C, ⌘V, ⌘A, ⌘Z.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.servicesProvider = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        // Launched by the Services menu, the request arrives right away; otherwise the user opened the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if showsSettingsAtLaunch(isDefaultLaunch: isDefaultLaunch, handledService: self.handledService, hasWindows: !self.panels.isEmpty || !self.failurePanels.isEmpty) {
                self.showSettings()
            }
        }
        // Launched for a request that never came: don't stay running with nothing on screen.
        if !isDefaultLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.finish() }
        }
    }

    // ⌘Q, or a SIGTERM (see below), while a model runs: don't leave the runner or the worker behind.
    func applicationWillTerminate(_ notification: Notification) {
        panels.forEach { $0.stop() }
        warm?.unload()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func showRewrite(of text: String, style: Style) {
        let panel = ResultPanelController(source: text, style: style) { [weak self] config in self?.warmRunner(for: config) }
        panel.onModelChange = { [weak self] in self?.modelChanged() }
        panel.onClose = { [weak self, weak panel] in
            self?.panels.removeAll { $0 === panel }
            self?.finish()
        }
        panels.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.showWindow(nil)
        // Offset each new panel so they don't stack exactly. After showWindow, which places the window itself.
        if let frame = panels.dropLast().last?.window?.frame {
            panel.window?.setFrame(frame.offsetBy(dx: 24, dy: -24), display: true)
        }
        panel.window?.orderFrontRegardless()
        panel.start()
    }

    // Replace Selection: the app that asked waits for the answer, so block here, but keep the run
    // loop turning so the progress window stays live.
    private func replaceInPlace(_ text: String) -> Result<String, Error> {
        handledService = true
        replacing = true
        defer { replacing = false; finish() }
        let config = loadConfig()
        // No dialog to pick a model from here, so say which is missing and where to choose another.
        if let missing = missingModel(config) { return .failure(missing) }
        let warm = warmRunner(for: config)
        let progress = ProgressWindow(text: "Rewriting with \(config.backend.displayName)…")
        defer { progress.close() }
        var result: Result<String, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                finishedPrompt(try rewrite(text, config: config, warm: warm, timeout: inPlaceTimeout), style: .agentPrompt, source: text,
                               builtInInstructions: config.systemPrompt == agentSystemPrompt, instructions: config.systemPrompt).text
            }
            DispatchQueue.main.async { result = outcome }
        }
        while result == nil { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return result!
    }

    // Explain on items from Finder. Reading a folder, a database or a PDF can take a while, and a
    // broken disk can hang, so it happens off the main thread with a time limit, behind a small
    // window that says what's being read. With `done`, a failure goes to it instead of a new window.
    private func explain(_ files: [URL], done: ((Error?) -> Void)? = nil) {
        handledService = true
        reading += 1
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
        let progress = ProgressWindow(text: "Reading \(name)…")
        readItems(files.map(\.path)) { result in
            DispatchQueue.main.async {
                progress.close()
                self.reading -= 1
                switch result {
                case .success(let text):
                    self.showRewrite(of: text, style: .explain)
                    done?(nil)
                case .failure(let error):
                    if let done { done(error) } else { self.showFailure(error, files: files) }
                }
            }
        }
    }

    // MARK: When a request fails

    // Registered here and now, not later: the in-place item's finish() is already on its way, and
    // would quit the app before this window existed.
    private func showFailure(_ error: Error, files: [URL]) {
        handledService = true
        let panel = FailurePanelController(error: error, files: files) { [weak self] chosen, done in
            self?.explain(chosen, done: done)
        }
        panel.onClose = { [weak self, weak panel] in
            self?.failurePanels.removeAll { $0 === panel }
            self?.finish()
        }
        failurePanels.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.showWindow(nil)
        panel.window?.orderFrontRegardless()
    }

    // MARK: Keeping the model loaded

    // The worker that keeps this config's model loaded, or nil to run the model once: not MLX,
    // turned off in settings, or mlx_lm.generate's Python can't be found.
    private func warmRunner(for config: BackendConfig) -> WarmRunner? {
        let minutes = keepLoadedMinutes()
        guard config.backend == .mlx, minutes > 0,
              let generate = config.executable ?? findExecutable(named: Backend.mlx.executableName, in: standardSearchDirs()),
              let python = interpreter(ofScript: generate),
              let script = Bundle.main.path(forResource: "mlx_worker", ofType: "py") else {
            warm?.unload()
            return nil
        }
        let command = python + [script]
        if let warm, warm.command == command {
            warm.idleTimeout = TimeInterval(minutes * 60)
            return warm
        }
        warm?.unload()
        let runner = WarmRunner(command: command, idleTimeout: TimeInterval(minutes * 60))
        runner.onChange = { [weak self] _ in DispatchQueue.main.async { self?.warmChanged() } }
        warm = runner
        return runner
    }

    private func warmChanged() {
        if warm?.isLoaded == true {
            showStatusItem()
        } else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            finish()
        }
    }

    // In the menu bar only while a model is loaded, so it can be unloaded early.
    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Prompt Menu model loaded")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if modelMenus.contains(menu) {
            modelMenuItems { [weak self] _ in self?.modelChanged() }.forEach(menu.addItem)
            return
        }
        let minutes = max(1, Int(((warm?.unloadsAt?.timeIntervalSinceNow ?? 0) / 60).rounded(.up)))
        let model = (loadConfig().model as NSString).lastPathComponent
        menu.addItem(withTitle: "\(model) loaded · unloads in \(minutes) min", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Unload Model Now", action: #selector(unloadModel(_:)), keyEquivalent: "").target = self
        menu.addItem(modelSubmenu())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "").target = self
    }

    @objc private func unloadModel(_ sender: Any?) {
        warm?.unload()
    }

    // The models on this Mac, rebuilt each time it opens (see menuNeedsUpdate).
    private func modelSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Model")
        modelMenus.add(menu)
        menu.delegate = self
        item.submenu = menu
        return item
    }

    // A different model was chosen: free the old one's memory now. Two models don't fit in 8 GB, and
    // the next rewrite loads the new one.
    private func modelChanged() {
        warm?.unload()
        settingsWindow?.reload()
    }

    // MARK: Windows

    // Opened directly, the app behaves like a regular app (Dock icon, ⌘W, ⌘Q) and quits with its windows.
    private func showSettings() {
        if settingsWindow == nil {
            NSApp.setActivationPolicy(.regular)
            let controller = SettingsWindowController()
            controller.onTryIt = { [weak self] text in self?.showRewrite(of: text, style: .agentPrompt) }
            controller.onSave = { [weak self] in _ = self?.warmRunner(for: loadConfig()) }  // Applies a changed keep-loaded time.
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

    // Quit once nothing is on screen and no model is kept loaded, so no memory is left behind.
    private func finish() {
        DispatchQueue.main.async {
            if self.settingsWindow == nil && self.panels.isEmpty && !self.replacing && self.reading == 0 && self.failurePanels.isEmpty && self.warm?.isLoaded != true {
                NSApp.terminate(nil)
            }
        }
    }

    // Adapted from Finder Menu's helper app.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Unload Model", action: #selector(unloadModel(_:)), keyEquivalent: "").target = self
        appMenu.addItem(modelSubmenu())
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

// A small floating window with a spinner while Replace Selection waits for the model.
private final class ProgressWindow {
    private let panel: NSPanel

    init(text: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
                        styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Prompt Menu"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.usesThreadedAnimation = true
        let label = NSTextField(labelWithString: text)
        let row = NSStackView(views: [spinner, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        spinner.startAnimation(nil)
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
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
