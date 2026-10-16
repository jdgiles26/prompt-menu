import Cocoa

// The dialog for one rewrite: a spinner while the model runs, then the result, editable before you
// copy it. Every result is kept as a version, so applying a pattern never loses the first draft.
// Closing the dialog while the model runs stops the model.
final class ResultPanelController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private struct Version {
        var text: String
        var label: String
    }

    // What a run does: the first draft from the highlighted text, or a pattern applied to a version.
    private enum Operation {
        case draft
        case pattern(AgenticPattern, input: String)

        var label: String {
            switch self {
            case .draft: return "First draft"
            case .pattern(let pattern, _): return pattern.title
            }
        }
    }

    private let source: String
    private let style: Style
    private let warmRunner: (BackendConfig) -> WarmRunner?
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let versionPopup = NSPopUpButton()
    private let checkButton = NSButton(title: "", target: nil, action: nil)
    private let patternButton = NSButton(title: "Agentic Pattern…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let againButton = NSButton(title: "Try Again", target: nil, action: nil)
    private var versions: [Version] = []
    private var lastOperation = Operation.draft
    private var stopRunning: (() -> Void)?
    private var isRunning = false
    private var generation = 0
    private var timer: Timer?
    private var startedAt = Date()
    private var runningStatus = ""
    private var notice: String?
    private var popover: NSPopover?
    var onClose: (() -> Void)?

    init(source: String, style: Style, warmRunner: @escaping (BackendConfig) -> WarmRunner?) {
        self.source = source
        self.style = style
        self.warmRunner = warmRunner
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = style.dialogTitle
        panel.minSize = NSSize(width: 520, height: 320)
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
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        versionPopup.target = self
        versionPopup.action = #selector(versionChosen(_:))
        versionPopup.controlSize = .small
        checkButton.bezelStyle = .recessed
        checkButton.controlSize = .small
        checkButton.target = self
        checkButton.action = #selector(showCheck(_:))
        checkButton.toolTip = "A quick check without a model: sections, dropped facts, open questions, a checkable finish."
        patternButton.controlSize = .small
        patternButton.target = self
        patternButton.action = #selector(showPatterns(_:))
        patternButton.toolTip = "Restructure the prompt around a workflow from Awesome Agentic Patterns."

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        againButton.target = self
        againButton.action = #selector(tryAgain(_:))
        copyButton.target = self
        copyButton.action = #selector(copyPrompt(_:))
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = .command // Return alone types a new line.

        for view in [versionPopup, checkButton, patternButton, scroll, spinner, status, closeButton, againButton, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            versionPopup.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            versionPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            versionPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            checkButton.leadingAnchor.constraint(equalTo: versionPopup.trailingAnchor, constant: 8),
            checkButton.centerYAnchor.constraint(equalTo: versionPopup.centerYAnchor),
            patternButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            patternButton.centerYAnchor.constraint(equalTo: versionPopup.centerYAnchor),
            checkButton.trailingAnchor.constraint(lessThanOrEqualTo: patternButton.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: versionPopup.bottomAnchor, constant: 10),
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

    // MARK: Running the model

    func start() { run(.draft) }

    // Runs the model off the main thread. Only the latest run may update the panel.
    private func run(_ operation: Operation) {
        generation += 1
        let mine = generation
        lastOperation = operation
        var config = loadConfig()
        let input: String
        switch operation {
        case .draft:
            config.systemPrompt = systemPrompt(for: style, config: config)
            input = source
        case .pattern(let pattern, let text):
            config.systemPrompt = patternSystemPrompt(pattern, sections: style.sections)
            input = text
        }
        let model = config.model.isEmpty ? (config.executable as NSString?)?.lastPathComponent ?? "" : config.model
        let verb = { if case .pattern(let p, _) = operation { return "Applying \(p.title)" } else { return "Rewriting" } }()
        runningStatus = "\(verb) with \(config.backend.displayName)\(model.isEmpty ? "" : " · \((model as NSString).lastPathComponent)")"
        notice = nil
        setRunning(true, status: runningStatus + "…")
        textView.string = ""
        // Loading a model takes a while before the first word; show that something is happening.
        startedAt = Date()
        timer?.invalidate() // Try Again while running: the old run's timer would outlive it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.status.stringValue = "\(self.runningStatus)… \(Int(Date().timeIntervalSince(self.startedAt)))s"
        }
        let warm = warmRunner(config)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try rewrite(input, config: config, warm: warm, started: { stop in
                // Closed or retried before the runner started: nothing else will stop it.
                DispatchQueue.main.async { if mine == self.generation { self.stopRunning = stop } else { stop() } }
            }, progress: { soFar in
                DispatchQueue.main.async {
                    guard mine == self.generation, self.isRunning else { return }
                    self.textView.string = soFar
                    self.textView.scrollToEndOfDocument(nil)
                }
            }, notice: { message in
                DispatchQueue.main.async { if mine == self.generation { self.notice = message } }
            }) }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.stopRunning = nil
                let seconds = Int(Date().timeIntervalSince(self.startedAt))
                switch result {
                case .success(let text):
                    self.versions.append(Version(text: text, label: "\(self.versions.count + 1) · \(operation.label)"))
                    self.showVersion(self.versions.count - 1)
                    self.setRunning(false, status: self.notice ?? "Done in \(seconds)s. Edit if needed, then copy (⌘↩).")
                    self.window?.makeFirstResponder(self.textView)
                case .failure(let error):
                    self.textView.string = error.localizedDescription
                    self.setRunning(false, status: "Couldn't rewrite the text.", failed: true)
                }
            }
        }
    }

    private func setRunning(_ running: Bool, status text: String, failed: Bool = false) {
        isRunning = running
        if !running { timer?.invalidate(); timer = nil }
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !running
        status.stringValue = text
        let ready = !running && !failed
        textView.isEditable = ready
        copyButton.isEnabled = ready
        patternButton.isEnabled = ready
        checkButton.isHidden = !ready
        versionPopup.isEnabled = !running && !versions.isEmpty
        versionPopup.isHidden = versions.isEmpty
        if ready { updateCheck() }
    }

    // MARK: Versions and the check

    private func showVersion(_ index: Int) {
        versionPopup.removeAllItems()
        versionPopup.addItems(withTitles: versions.map(\.label))
        versionPopup.selectItem(at: index)
        textView.string = versions[index].text
        textView.scrollToBeginningOfDocument(nil)
    }

    @objc private func versionChosen(_ sender: Any?) {
        let index = versionPopup.indexOfSelectedItem
        guard versions.indices.contains(index) else { return }
        saveEdits(selectingAfter: false)
        showVersion(index)
        setRunning(false, status: "Showing version \(versions[index].label).")
    }

    // The text as edited becomes its own version, so switching away or applying a pattern keeps it.
    private func saveEdits(selectingAfter: Bool) {
        let current = versionPopup.indexOfSelectedItem
        guard versions.indices.contains(current), textView.string != versions[current].text,
              !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        versions.append(Version(text: textView.string, label: "\(versions.count + 1) · Edited"))
        if selectingAfter { showVersion(versions.count - 1) } else {
            versionPopup.addItem(withTitle: versions.last!.label)
        }
    }

    func textDidChange(_ notification: Notification) {
        if !isRunning { updateCheck() }
    }

    private func updateCheck() {
        let result = checkPrompt(textView.string, source: source, style: style)
        var title = "Check \(result.score)"
        if result.confirmCount > 0 { title += " · \(result.confirmCount) to confirm" }
        checkButton.title = title
        checkButton.contentTintColor = result.score >= 85 ? .systemGreen : result.score >= 60 ? .systemOrange : .systemRed
    }

    @objc private func showCheck(_ sender: NSButton) {
        let result = checkPrompt(textView.string, source: source, style: style)
        let text = result.problems.isEmpty ? "No problems found." : result.problems.map { "• \($0)" }.joined(separator: "\n")
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 320
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: 320),
        ])
        controller.view = container
        show(controller, from: sender)
    }

    // MARK: Agentic patterns

    @objc private func showPatterns(_ sender: NSButton) {
        guard !bundledPatterns.isEmpty else {
            status.stringValue = "The pattern list is missing from the app. Reinstall Prompt Menu."
            return
        }
        saveEdits(selectingAfter: true)
        let task = textView.string
        let candidates = shortlist(for: task, in: bundledPatterns)
        let picker = PatternPickerController(candidates: candidates, all: bundledPatterns) { [weak self] pattern in
            self?.popover?.close()
            self?.run(.pattern(pattern, input: task))
        }
        show(picker, from: sender)
        suggestPattern(task: task, candidates: candidates, picker: picker)
    }

    // With the model already loaded, ask it which candidate fits (about a second). Otherwise the
    // keyword order stands, rather than making the user wait for a model to load.
    private func suggestPattern(task: String, candidates: [AgenticPattern], picker: PatternPickerController) {
        var config = loadConfig()
        guard let warm = warmRunner(config), warm.isLoaded, candidates.count > 1 else { return }
        config.systemPrompt = patternChoiceSystemPrompt
        config.maxTokens = 8
        config.temperature = 0
        let question = patternChoicePrompt(task: task, options: candidates)
        DispatchQueue.global(qos: .userInitiated).async { [weak picker] in
            let reply = (try? rewrite(question, config: config, warm: warm, timeout: 30)) ?? ""
            let choice = parseChoice(reply, count: candidates.count)
            DispatchQueue.main.async { if let choice { picker?.suggest(choice) } }
        }
    }

    private func show(_ controller: NSViewController, from button: NSButton) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }

    // MARK: Buttons

    @objc private func copyPrompt(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        status.stringValue = "Copied."
        window?.performClose(nil)
    }

    // Runs the last step again: the first draft, or the last pattern.
    @objc private func tryAgain(_ sender: Any?) {
        stopRunning?()
        stopRunning = nil
        run(lastOperation)
    }

    @objc private func closePanel(_ sender: Any?) { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        popover?.close()
        stop()
        onClose?()
    }

    // Stops the model, if one is running, and ignores whatever it still returns.
    func stop() {
        generation += 1
        timer?.invalidate()
        stopRunning?()
        stopRunning = nil
    }
}

// The pattern catalog shipped in the app bundle.
let bundledPatterns: [AgenticPattern] = Bundle.main.path(forResource: "patterns", ofType: "json")
    .flatMap { try? loadPatterns(from: $0) } ?? []
