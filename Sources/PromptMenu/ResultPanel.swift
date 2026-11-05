import Cocoa

// The dialog for one rewrite: a spinner while the model runs, then the result, editable before you
// copy it. Every result is kept as a version, so applying a pattern never loses the first draft.
// Closing the dialog while the model runs stops the model.
final class ResultPanelController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate {
    private struct Version {
        var text: String
        var label: String
        var author: String? = nil  // The model that wrote it, for Review's no-self-judging rule.
        var failed = false
    }

    // What a run does: the first draft from the highlighted text, or a pattern applied to a version.
    private enum Operation {
        case draft
        case pattern(AgenticPattern, input: String)
        case polish(input: String)
        case project(name: String, context: String)

        var label: String {
            switch self {
            case .draft: return "First draft"
            case .pattern(let pattern, _): return pattern.title
            case .polish: return "Polished"
            case .project(let name, _): return "With \(name)"
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
    private let modelPopup = NSPopUpButton()
    private let fillButton = NSButton(title: "Fill Gaps…", target: nil, action: nil)
    private let projectButton = NSButton(title: "Add Project…", target: nil, action: nil)
    private var fillSheet: FillGapsSheet?
    private var modelsSheet: ModelsSheet?
    private var logSheet: ReviewLogSheet?
    private var reviewLog = ""
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
    // The follow-up chat under the result. Its turns live here only; nothing is saved.
    private let chatBox = NSStackView()
    private let transcript = NSTextView()
    private let questionField = NSTextField()
    private let askButton = NSButton(title: "Ask", target: nil, action: nil)
    // The answered turns' text is kept, not rebuilt on every streamed chunk.
    private var chatTurns: [ChatTurn] = [] { didSet { answeredTranscript = chatTurns.map(\.text).joined(separator: "\n\n") } }
    private var answeredTranscript = ""
    private var showingFailure = false  // The text view shows an error, not a result.
    private var resultAboveButtons: NSLayoutConstraint!
    private var resultAboveChat: NSLayoutConstraint!
    var onClose: (() -> Void)?
    var onModelChange: (() -> Void)?

    init(source: String, style: Style, warmRunner: @escaping (BackendConfig) -> WarmRunner?) {
        self.source = source
        self.style = style
        self.warmRunner = warmRunner
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 660),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = style.dialogTitle
        panel.minSize = NSSize(width: 520, height: 460)
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
        projectButton.controlSize = .small
        projectButton.target = self
        projectButton.action = #selector(addProject(_:))
        projectButton.toolTip = "Pick a project folder. Its AGENTS.md, CLAUDE.md and README headings and commands go into the prompt's context."
        fillButton.controlSize = .small
        fillButton.target = self
        fillButton.action = #selector(fillGaps(_:))
        fillButton.toolTip = "Answer the [CONFIRM: …] questions. Answers replace them exactly, without a model."
        modelPopup.controlSize = .small
        modelPopup.toolTip = "The models on this Mac. Picking one runs the last step again with it."
        modelPopup.menu?.delegate = self
        modelPopup.menu?.autoenablesItems = false // Otherwise any item with a target shows as enabled.
        refreshModelPopup()

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        againButton.target = self
        againButton.action = #selector(tryAgain(_:))
        copyButton.target = self
        copyButton.action = #selector(copyPrompt(_:))
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = .command // Return alone types a new line.

        // Explain answers questions instead of rewriting, so the rewrite tools don't apply.
        patternButton.isHidden = !style.isRewrite
        projectButton.isHidden = !style.isRewrite
        layoutChat()

        for view in [versionPopup, checkButton, fillButton, projectButton, modelPopup, patternButton, scroll, chatBox, spinner, status, closeButton, againButton, copyButton] as [NSView] {
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
            modelPopup.trailingAnchor.constraint(equalTo: patternButton.leadingAnchor, constant: -8),
            modelPopup.centerYAnchor.constraint(equalTo: versionPopup.centerYAnchor),
            modelPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            fillButton.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 6),
            fillButton.centerYAnchor.constraint(equalTo: versionPopup.centerYAnchor),
            fillButton.trailingAnchor.constraint(lessThanOrEqualTo: modelPopup.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: versionPopup.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            chatBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            chatBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            chatBox.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            againButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            againButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: againButton.leadingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            projectButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            projectButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            // Explain hides Add Project, so there the spinner starts at the edge instead of after a gap.
            style.isRewrite ? spinner.leadingAnchor.constraint(equalTo: projectButton.trailingAnchor, constant: 8)
                            : spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
        ])
        // The result fills the space until the chat appears with the first result.
        resultAboveButtons = scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12)
        resultAboveChat = scroll.bottomAnchor.constraint(equalTo: chatBox.topAnchor, constant: -10)
        resultAboveButtons.isActive = true
        chatBox.isHidden = true
    }

    // A transcript and a one-line question field with Ask. Return in the field asks.
    private func layoutChat() {
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.font = NSFont.systemFont(ofSize: 12)
        transcript.textContainerInset = NSSize(width: 6, height: 6)
        transcript.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        questionField.placeholderString = style.isRewrite ? "Ask anything about the text or the result…" : "Ask anything about it…"
        questionField.target = self
        questionField.action = #selector(askQuestion(_:))
        askButton.target = self
        askButton.action = #selector(askQuestion(_:))
        let label = NSTextField(labelWithString: "Ask a follow-up")
        label.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [questionField, askButton])
        row.spacing = 8
        questionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chatBox.orientation = .vertical
        chatBox.alignment = .leading
        chatBox.spacing = 6
        for view in [label, scroll, row] as [NSView] { chatBox.addArrangedSubview(view) }
        scroll.widthAnchor.constraint(equalTo: chatBox.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: chatBox.widthAnchor).isActive = true
    }

    // MARK: Running the model

    func start() { run(.draft) }

    // Runs the model off the main thread. Only the latest run may update the panel.
    // `model` runs this once with another model than the saved one (Compare Models); `next` runs after
    // it finishes, whether it worked or not, unless the run was stopped.
    private func run(_ operation: Operation, model chosenModel: LocalModel? = nil, next: (() -> Void)? = nil) {
        generation += 1
        let mine = generation
        lastOperation = operation
        var config = loadConfig()
        if let chosenModel { config = config.choosing(chosenModel) }
        config.maxTokens = style.maxTokens(base: config.maxTokens)
        config.inputLabel = style.inputLabel
        let input: String
        switch operation {
        case .draft:
            config.systemPrompt = systemPrompt(for: style, config: config)
            input = source
        case .pattern(let pattern, let text):
            config.systemPrompt = patternSystemPrompt(pattern, sections: style.sections)
            input = style == .agentPrompt ? removingStandardLines(text) : text
        case .polish(let text):
            config.systemPrompt = polishSystemPrompt(sections: style.sections)
            input = text
        case .project(_, let context):
            config.systemPrompt = systemPrompt(for: style, config: config)
            input = withProjectContext(source, context: context)
        }
        // A deleted or never-downloaded model: offer the ones that are here instead of failing in the runner.
        if let missing = missingModel(config) {
            showMissingModel(missing)
            return
        }
        let model = config.model.isEmpty ? (config.executable as NSString?)?.lastPathComponent ?? "" : config.model
        let verb: String = {
            switch operation {
            case .draft: return style.isRewrite ? "Rewriting" : "Explaining"
            case .pattern(let p, _): return "Applying \(p.title)"
            case .polish: return "Polishing"
            case .project(let name, _): return "Rewriting with \(name)"
            }
        }()
        runningStatus = "\(verb) with \(config.backend.displayName)\(model.isEmpty ? "" : " · \((model as NSString).lastPathComponent)")"
        notice = nil
        setRunning(true, status: runningStatus + "…")
        showTranscript()  // A follow-up this run cut off.
        textView.string = ""
        startClock()
        let warm = warmRunner(config)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                let output = try rewrite(input, config: config, warm: warm, started: { stop in
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
            })
                let finished: (text: String, notice: String?)
                switch operation {
                case .pattern(let pattern, let before):
                    finished = finishedPrompt(output, style: self.style, source: self.source, builtInInstructions: true, pattern: pattern,
                                              before: before, instructions: config.systemPrompt)
                case .project(_, let context):
                    finished = finishedPrompt(output, style: self.style, source: self.source, builtInInstructions: config.systemPrompt == self.style.builtInPrompt,
                                              instructions: config.systemPrompt, context: context)
                case .draft, .polish:
                    finished = finishedPrompt(output, style: self.style, source: self.source, builtInInstructions: config.systemPrompt == self.style.builtInPrompt,
                                              instructions: config.systemPrompt)
                }
                if let notice = finished.notice {
                    DispatchQueue.main.async { if mine == self.generation { self.notice = notice } }
                }
                return finished.text
            }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.stopRunning = nil
                let seconds = Int(Date().timeIntervalSince(self.startedAt))
                switch result {
                case .success(let text) where chosenModel != nil:
                    let score = checkPrompt(text, source: self.source, style: self.style).score
                    self.versions.append(Version(text: text, label: "\(self.versions.count + 1) · \(chosenModel!.name) · \(seconds)s\(self.style.isRewrite ? " · check \(score)" : "")",
                                                 author: chosenModel!.id))
                    self.showVersion(self.versions.count - 1)
                    self.setRunning(false, status: "")
                case .failure(let error) where chosenModel != nil:
                    self.versions.append(Version(text: error.localizedDescription, label: "\(self.versions.count + 1) · \(chosenModel!.name) · failed",
                                                 failed: true))
                    self.showVersion(self.versions.count - 1)
                    self.setRunning(false, status: "")
                case .success(let text):
                    self.versions.append(Version(text: text, label: "\(self.versions.count + 1) · \(operation.label)", author: config.model))
                    self.showVersion(self.versions.count - 1)
                    self.setRunning(false, status: self.notice ?? "Done in \(seconds)s. \(self.style.isRewrite ? "Edit if needed, then copy (⌘↩)." : "Ask a follow-up below.")")
                    self.window?.makeFirstResponder(self.textView)
                case .failure(let error):
                    self.textView.string = error.localizedDescription
                    self.setRunning(false, status: self.style.isRewrite ? "Couldn't rewrite the text." : "Couldn't explain the text.", failed: true)
                }
                next?()
            }
        }
    }

    // Loading a model takes a while before the first word; show that something is happening.
    private func startClock() {
        startedAt = Date()
        timer?.invalidate() // Try Again while running: the old run's timer would outlive it.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.status.stringValue = "\(self.runningStatus)… \(Int(Date().timeIntervalSince(self.startedAt)))s"
        }
    }

    private func setRunning(_ running: Bool, status text: String, failed: Bool = false) {
        isRunning = running
        if !running { showingFailure = failed }
        if !running { timer?.invalidate(); timer = nil }
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        spinner.isHidden = !running
        status.stringValue = text
        let ready = !running && !failed
        textView.isEditable = ready
        copyButton.isEnabled = ready
        patternButton.isEnabled = ready
        modelPopup.isEnabled = !running
        projectButton.isEnabled = !running
        checkButton.isHidden = !ready || !style.isRewrite
        fillButton.isHidden = true
        versionPopup.isEnabled = !running && !versions.isEmpty
        versionPopup.isHidden = versions.isEmpty
        askButton.isEnabled = !running
        questionField.isEnabled = !running
        if !versions.isEmpty && chatBox.isHidden {
            chatBox.isHidden = false
            resultAboveButtons.isActive = false
            resultAboveChat.isActive = true
        }
        if ready { updateCheck() }
    }

    // MARK: Choosing a model

    private func showMissingModel(_ error: RewriteError) {
        refreshModelPopup()
        let found = !modelsOnThisMac().isEmpty
        textView.string = error.localizedDescription + (found ? "" : "\n\nNo models were found on this Mac. Download one in Terminal, for example:\n  mlx_lm.generate --model \(defaultMLXModel) --prompt hi\nor add a folder of GGUF files in Prompt Menu's settings.")
        setRunning(false, status: found ? "Choose a model on this Mac from the Model menu." : "No model to run.", failed: true)
        // The first time (or after a model was deleted), open the list so the choice is one click.
        if found { DispatchQueue.main.async { [weak self] in self?.modelPopup.performClick(nil) } }
    }

    // The pop-up's title is the current model; its menu is rebuilt each time it opens.
    private func refreshModelPopup() {
        guard let menu = modelPopup.menu else { return }
        menuNeedsUpdate(menu)
        if let current = menu.items.first(where: { $0.state == .on }) { modelPopup.select(current) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        modelMenuItems { [weak self] _ in self?.modelPicked() }.forEach(menu.addItem)
        menu.addItem(.separator())
        let compare = ActionMenuItem(title: "Compare Models…") { [weak self] in self?.compareModels() }
        compare.isEnabled = !isRunning && !modelsOnThisMac().isEmpty
        menu.addItem(compare)
        // Review judges and hardens agent prompts; an explanation isn't one.
        guard style.isRewrite else { return }
        let review = ActionMenuItem(title: "Review…") { [weak self] in self?.reviewModels() }
        review.toolTip = "The models judge the versions blind, then harden the winner. Every step is in the Review Log."
        review.isEnabled = compare.isEnabled && versions.contains { !$0.failed }
        menu.addItem(review)
        let log = ActionMenuItem(title: "Review Log") { [weak self] in self?.showReviewLog() }
        log.isEnabled = !reviewLog.isEmpty
        menu.addItem(log)
    }

    // MARK: Comparing models

    private func compareModels() {
        // The pop-up shows the chosen item as its title; put the current model back.
        refreshModelPopup()
        guard let window else { return }
        let sheet = ModelsSheet(models: modelsOnThisMac(), current: loadConfig(),
                                intro: "Each ticked model rewrites the highlighted text with the same instructions, one after another. Each result becomes a version, labeled with its model, time and check score.",
                                action: "Compare", estimate: { models, _ in estimatedSeconds(for: models) }) { [weak self] models, _ in
            self?.saveEdits(selectingAfter: false)
            self?.compare(models, done: 0)
        }
        modelsSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.modelsSheet = nil }
    }

    // One model at a time, each starting when the one before finishes.
    private func compare(_ models: [LocalModel], done: Int) {
        guard done < models.count else {
            setRunning(false, status: "Compared \(models.count) model\(models.count == 1 ? "" : "s"). Pick a result from the versions list.")
            return
        }
        let model = models[done]
        run(.draft, model: model) { [weak self] in self?.compare(models, done: done + 1) }
        runningStatus = "Comparing \(done + 1) of \(models.count) · \(model.name)"
        status.stringValue = runningStatus + "…"
    }

    // MARK: Review

    // The versions so far, failed ones left out and repeats once.
    private func reviewCandidates() -> (candidates: [ReviewCandidate], labels: [String]) {
        var seen = Set<String>()
        let usable = versions.filter { !$0.failed && seen.insert($0.text).inserted }
        return (usable.map { ReviewCandidate(text: $0.text, author: $0.author) }, usable.map(\.label))
    }

    private func reviewModels() {
        refreshModelPopup()
        saveEdits(selectingAfter: false)
        guard let window else { return }
        let count = reviewCandidates().candidates.count
        let intro = "The \(count) version\(count == 1 ? "" : "s") in this dialog are the candidates. With two or more models, each ticked model picks the best one without seeing who wrote it, and the check votes too. Then the models harden the winner as security, scope and verifiability reviewers. An edit is kept only if the check score holds and no fact is lost."
        let sheet = ModelsSheet(models: modelsOnThisMac(), current: loadConfig(), intro: intro, action: "Review",
                                option: "Ask each judge twice, in reverse order (fairer, twice the jury time)",
                                estimate: { models, twice in reviewEstimate(models: models, candidates: count, checkTwice: twice) }) { [weak self] models, twice in
            self?.review(models, checkTwice: twice)
        }
        modelsSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.modelsSheet = nil }
    }

    private func review(_ models: [LocalModel], checkTwice: Bool) {
        let (candidates, labels) = reviewCandidates()
        guard !candidates.isEmpty else { return }
        generation += 1
        let mine = generation
        let stopper = Stopper()
        stopRunning = { stopper.stop() }
        let warmRunner = self.warmRunner
        let pipeline = ReviewPipeline(candidates: candidates, source: source, style: style, models: models, checkTwice: checkTwice,
                                      seed: UInt64.random(in: 0...UInt64.max)) { input, system, model, maxTokens in
            var config = loadConfig().choosing(model)
            config.systemPrompt = system
            if let maxTokens {
                config.maxTokens = maxTokens
                config.temperature = 0
            }
            let warm = DispatchQueue.main.sync { warmRunner(config) }
            return try rewrite(input, config: config, warm: warm, started: { stopper.running($0) })
        }
        pipeline.isStopped = { stopper.isStopped }
        var events: [ReviewEvent] = []
        reviewLog = ""
        runningStatus = models.count > 1 && candidates.count > 1 ? "Judging \(candidates.count) versions" : "Hardening"
        notice = nil
        setRunning(true, status: runningStatus + "…")
        startClock()
        DispatchQueue.global(qos: .userInitiated).async {
            let final = pipeline.run { event in
                DispatchQueue.main.async {
                    guard mine == self.generation else { return }
                    events.append(event)
                    self.reviewLog = reviewLogText(events, labels: labels)
                    self.reviewStep(event, labels: labels)
                }
            }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.stopRunning = nil
                let seconds = Int(Date().timeIntervalSince(self.startedAt))
                let index = self.versions.lastIndex { $0.text == final } ?? 0
                self.showVersion(index)
                let stopped = pipeline.state == .stopped
                self.setRunning(false, status: "\(stopped ? "Stopped" : "Reviewed") in \(seconds)s. Showing \(self.versions[index].label). Steps: Model menu ▸ Review Log.")
            }
        }
    }

    private func reviewStep(_ event: ReviewEvent, labels: [String]) {
        switch event {
        case .note, .vote:
            return
        case .winner(let index, _, _):
            runningStatus = "\(labels[index]) won. Hardening: \(HardenRole.allCases[0].rawValue)"
        case .harden(let step):
            if step.kept, let after = step.after {
                versions.append(Version(text: after, label: "\(versions.count + 1) · Hardened: \(step.role.rawValue)", author: step.model))
                showVersion(versions.count - 1)
            }
            let roles = HardenRole.allCases
            if let i = roles.firstIndex(of: step.role), i + 1 < roles.count { runningStatus = "Hardening: \(roles[i + 1].rawValue)" }
        }
    }

    private func showReviewLog() {
        refreshModelPopup()
        guard let window, !reviewLog.isEmpty else { return }
        let sheet = ReviewLogSheet(text: reviewLog)
        logSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.logSheet = nil }
    }

    private func modelPicked() {
        onModelChange?()
        refreshModelPopup()
        stopRunning?()
        stopRunning = nil
        run(lastOperation)
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
        fillButton.isHidden = result.confirmCount == 0 || !style.isRewrite
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

    // MARK: Project context

    // Nothing is read until the user picks the folder, and only its three instruction files.
    @objc private func addProject(_ sender: Any?) {
        guard let window else { return }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.prompt = "Add Project"
        open.message = "Its AGENTS.md, CLAUDE.md and README headings and commands go into the prompt's context."
        open.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = open.url?.path else { return }
            let name = (folder as NSString).lastPathComponent
            guard let context = projectContext(folder: folder) else {
                self.status.stringValue = "\(name) has no AGENTS.md, CLAUDE.md or README with headings or commands."
                return
            }
            self.saveEdits(selectingAfter: false)
            self.run(.project(name: name, context: context))
        }
    }

    // MARK: Fill gaps

    @objc private func fillGaps(_ sender: Any?) {
        saveEdits(selectingAfter: true)
        let text = textView.string
        let questions = confirmQuestions(in: text)
        guard !questions.isEmpty, let window else { return }
        let sheet = FillGapsSheet(questions: questions) { [weak self] answers, polishing in
            guard let self else { return }
            let filled = fill(text, answers: answers)
            guard filled != text else { return }
            self.versions.append(Version(text: filled, label: "\(self.versions.count + 1) · Filled"))
            self.showVersion(self.versions.count - 1)
            self.setRunning(false, status: "Filled \(questions.count - confirmQuestions(in: filled).count) of \(questions.count) questions.")
            if polishing { self.run(.polish(input: filled)) }
        }
        fillSheet = sheet
        window.beginSheet(sheet.window!) { [weak self] _ in self?.fillSheet = nil }
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

    // MARK: Follow-up chat

    // Asks about the highlighted text and the result as shown now, edits included. Runs like any
    // other step: one model at a time, stopped by Close or Try Again, late replies ignored.
    @objc private func askQuestion(_ sender: Any?) {
        let question = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        generation += 1
        let mine = generation
        var config = loadConfig()
        config.maxTokens = style.maxTokens(base: config.maxTokens)
        if let missing = missingModel(config) {
            showTranscript(adding: "You: \(question)\n\(missing.localizedDescription)")
            return
        }
        runningStatus = "Answering with \(config.backend.displayName)"
        notice = nil
        setRunning(true, status: runningStatus + "…")
        startClock()
        showTranscript(adding: ChatTurn(question: question, answer: "…").text)
        let warm = warmRunner(config)
        // The result as it is now, edits included; after a failure the text view shows the error,
        // so ask about the selected version, or the last one that worked. The failure stays shown.
        let failedShown = showingFailure
        let index = versionPopup.indexOfSelectedItem
        let selected = versions.indices.contains(index) ? versions[index] : nil
        let shown: String
        if !failedShown && selected?.failed != true {
            shown = textView.string
        } else if let selected, !selected.failed {
            shown = selected.text
        } else {
            shown = versions.last { !$0.failed }?.text ?? ""
        }
        let history = chatTurns
        // It may run the model twice; stopping must also keep the second run from starting.
        let stopper = Stopper()
        stopRunning = { stopper.stop() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try answerFollowUp(question, style: self.style, source: self.source, result: shown, history: history,
                                                     config: config, warm: warm, started: { stopper.running($0) }, progress: { soFar in
                DispatchQueue.main.async {
                    guard mine == self.generation, self.isRunning else { return }
                    self.showTranscript(adding: ChatTurn(question: question, answer: soFar).text)
                }
            }, notice: { message in
                DispatchQueue.main.async { if mine == self.generation { self.notice = message } }
            }, isStopped: { stopper.isStopped }) }
            DispatchQueue.main.async {
                guard mine == self.generation else { return }
                self.stopRunning = nil
                let seconds = Int(Date().timeIntervalSince(self.startedAt))
                switch result {
                case .success(let answer):
                    self.chatTurns.append(ChatTurn(question: question, answer: answer))
                    self.questionField.stringValue = ""
                    self.showTranscript()
                    // An answer that changes the result becomes a version, whole, so nothing is copied by hand.
                    if !failedShown, let edited = chatEdit(answer, of: shown, style: self.style) {
                        self.saveEdits(selectingAfter: false)
                        self.versions.append(Version(text: edited, label: "\(self.versions.count + 1) · From the chat"))
                        self.showVersion(self.versions.count - 1)
                        self.updateCheck()
                        self.setRunning(false, status: "Answered in \(seconds)s. The change is version \(self.versions.count); earlier versions are in the menu.")
                    } else {
                        self.setRunning(false, status: self.notice ?? "Answered in \(seconds)s.", failed: failedShown)
                    }
                case .failure(let error):
                    // The question stays in the field, to ask again.
                    self.showTranscript(adding: "You: \(question)\n\(error.localizedDescription)")
                    self.setRunning(false, status: "Couldn't answer. Ask again, or pick another model.", failed: failedShown)
                }
                self.window?.makeFirstResponder(self.questionField)
            }
        }
    }

    // The answered turns, then `pending` (a question being answered, or one that failed).
    private func showTranscript(adding pending: String? = nil) {
        transcript.string = ([answeredTranscript, pending ?? ""].filter { !$0.isEmpty }).joined(separator: "\n\n")
        transcript.scrollToEndOfDocument(nil)
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

// Stops a review: the flag the pipeline checks between calls, and the model call running now.
private final class Stopper {
    private let lock = NSLock()
    private var stopped = false
    private var current: (() -> Void)?

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func running(_ stop: @escaping () -> Void) {
        lock.lock()
        let late = stopped
        if !late { current = stop }
        lock.unlock()
        if late { stop() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let stop = current
        current = nil
        lock.unlock()
        stop?()
    }
}
