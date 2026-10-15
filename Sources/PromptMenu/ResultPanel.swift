import Cocoa

// The dialog for one rewrite: a spinner while the model runs, then the prompt, editable before you
// copy it. Closing it while the model runs stops the model.
final class ResultPanelController: NSWindowController, NSWindowDelegate {
    private let source: String
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let againButton = NSButton(title: "Try Again", target: nil, action: nil)
    private var running: Process?
    private var generation = 0
    var onClose: (() -> Void)?

    init(source: String) {
        self.source = source
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Agent Prompt"
        panel.minSize = NSSize(width: 420, height: 300)
        panel.isReleasedWhenClosed = false
        // Panels hide when their app isn't frontmost, and macOS may not bring this app forward when
        // the service is called from another app. Stay visible; it's the only thing on screen.
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        layout(in: panel)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func layout(in panel: NSPanel) {
        let content = panel.contentView!

        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        againButton.target = self
        againButton.action = #selector(tryAgain(_:))
        copyButton.target = self
        copyButton.action = #selector(copyPrompt(_:))
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = .command // Return alone types a new line.

        for view in [scroll, spinner, status, closeButton, againButton, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            againButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            againButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: againButton.leadingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
        ])
    }

    // Runs the model off the main thread. Only the latest run may update the panel.
    func start() {
        generation += 1
        let mine = generation
        let config = loadConfig()
        let model = config.model.isEmpty ? (config.executable as NSString?)?.lastPathComponent ?? "" : config.model
        setRunning(true, status: "Rewriting with \(config.backend.displayName)\(model.isEmpty ? "" : " · \((model as NSString).lastPathComponent)")…")
        textView.string = ""
        let text = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try rewrite(text, config: config, started: { process in
                DispatchQueue.main.async { if mine == self.generation { self.running = process } }
            }) }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.running = nil
                switch result {
                case .success(let prompt):
                    self.textView.string = prompt
                    self.setRunning(false, status: "Edit if needed, then copy.")
                    self.window?.makeFirstResponder(self.textView)
                case .failure(let error):
                    self.textView.string = error.localizedDescription
                    self.setRunning(false, status: "Couldn't rewrite the text.", failed: true)
                }
            }
        }
    }

    private func setRunning(_ isRunning: Bool, status text: String, failed: Bool = false) {
        isRunning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !isRunning
        status.stringValue = text
        textView.isEditable = !isRunning && !failed
        copyButton.isEnabled = !isRunning && !failed
        againButton.isEnabled = !isRunning
    }

    @objc private func copyPrompt(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        status.stringValue = "Copied."
        window?.performClose(nil)
    }

    @objc private func tryAgain(_ sender: Any?) { start() }

    @objc private func closePanel(_ sender: Any?) { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        generation += 1 // Ignore whatever the running model returns.
        running?.terminate()
        running = nil
        onClose?()
    }
}
