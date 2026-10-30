import Cocoa

// Which local runner and model to use. Shown when Prompt Menu is opened directly.
final class SettingsWindowController: NSWindowController, NSMenuDelegate {
    private let backendPopup = NSPopUpButton()
    private let runnerField = NSTextField()
    private let modelField = NSTextField()
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private let foldersField = NSTextField()
    private let tokensField = NSTextField()
    private let keepLoadedField = NSTextField()
    private let hint = NSTextField(wrappingLabelWithString: "")
    var onTryIt: ((String) -> Void)?
    var onSave: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Prompt Menu"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        layout(in: window)
        show(loadConfig())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // A model was picked from a menu elsewhere; show it here too.
    func reload() { show(loadConfig()) }

    private func layout(in window: NSWindow) {
        for backend in Backend.allCases { backendPopup.addItem(withTitle: backend.displayName) }
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged(_:))
        tokensField.formatter = { let f = NumberFormatter(); f.minimum = 16; f.maximum = 8192; return f }()
        keepLoadedField.formatter = { let f = NumberFormatter(); f.minimum = 0; f.maximum = 120; return f }()
        let keepLoadedNote = NSTextField(labelWithString: "minutes after use, so the next rewrite starts at once (MLX; 0 = unload right away)")
        keepLoadedNote.textColor = .secondaryLabelColor
        keepLoadedNote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.isSelectable = true
        // Re-check the runner path as it's typed.
        NotificationCenter.default.addObserver(self, selector: #selector(updateHints), name: NSControl.textDidChangeNotification, object: runnerField)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHints), name: NSControl.textDidChangeNotification, object: modelField)
        modelPicker.controlSize = .small
        modelPicker.addItem(withTitle: "Found on this Mac")
        modelPicker.menu?.delegate = self
        modelPicker.toolTip = "Models already on this Mac. Picking one also picks a runner that can use it."
        foldersField.placeholderString = "Other folders with .gguf files, separated by :"
        foldersField.toolTip = "Searched as well as the Hugging Face cache, ~/models, ~/llama.cpp/models and LM Studio's folder."
        let addFolder = NSButton(title: "Add…", target: self, action: #selector(addFolder(_:)))
        addFolder.controlSize = .small

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Runner:"), backendPopup],
            [NSTextField(labelWithString: "Runner path:"), runnerField],
            [NSTextField(labelWithString: "Model:"), NSStackView(views: [modelField, modelPicker])],
            [NSTextField(labelWithString: "Model folders:"), NSStackView(views: [foldersField, addFolder])],
            [NSTextField(labelWithString: "Max tokens:"), tokensField],
            [NSTextField(labelWithString: "Keep loaded:"), NSStackView(views: [keepLoadedField, keepLoadedNote])],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.column(at: 1).width = 480
        // In a stack view a text field shrinks to nothing unless given a width.
        modelPicker.widthAnchor.constraint(equalToConstant: 130).isActive = true
        modelField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        foldersField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        tokensField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        keepLoadedField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let note = NSTextField(wrappingLabelWithString:
            "Highlight text in any app, then choose Services → Rewrite as Agent Prompt (or Bug Report, Code Review Request, Commit Message, or Replace Selection), or Explain This for Me, from its right-click or app menu. The model runs on this Mac; nothing is sent anywhere. To change the agent prompt's instructions: defaults write local.promptmenu systemPrompt \"…\"")
        let tryIt = NSButton(title: "Try It", target: self, action: #selector(tryIt(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"

        let content = window.contentView!
        for view in [note, grid, tryIt, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            save.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            tryIt.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            tryIt.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])
    }

    private var selectedBackend: Backend { Backend.allCases[max(backendPopup.indexOfSelectedItem, 0)] }

    private func show(_ config: BackendConfig) {
        backendPopup.selectItem(at: Backend.allCases.firstIndex(of: config.backend) ?? 0)
        runnerField.stringValue = config.executable ?? ""
        modelField.stringValue = config.model
        foldersField.stringValue = modelFolders().joined(separator: ":")
        tokensField.integerValue = config.maxTokens
        keepLoadedField.integerValue = keepLoadedMinutes()
        updateHints()
    }

    @objc private func updateHints() {
        let backend = selectedBackend
        runnerField.placeholderString = "Search PATH and Homebrew for \(backend.executableName)"
        var found = "Runner: "
        let runner = (runnerField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !runner.isEmpty {
            found += FileManager.default.isExecutableFile(atPath: runner) ? "✓ \(runner)" : "✗ no program at \(runner)"
        } else {
            found += findExecutable(named: backend.executableName, in: standardSearchDirs()).map { "✓ found \($0)" }
                ?? "✗ \(backend.executableName) not found"
        }
        found += "\nModel: " + modelStatus(editedConfig)
        defer { hint.stringValue = found + "\n" + hint.stringValue }
        switch backend {
        case .mlx:
            modelField.placeholderString = defaultMLXModel
            hint.stringValue = "Install with: pip install mlx-lm\nThe model must already be downloaded. Run once in Terminal: mlx_lm.generate --model \(modelField.stringValue.isEmpty ? defaultMLXModel : modelField.stringValue) --prompt hi"
        case .llamafile:
            modelField.placeholderString = "/path/to/model.gguf (empty for a model-bundled .llamafile)"
            hint.stringValue = "Needs llamafile 0.10 or later from github.com/mozilla-ai/llamafile. For a model-bundled .llamafile, set it as the runner path and leave Model empty."
        case .llamaCpp:
            modelField.placeholderString = "/path/to/model.gguf"
            hint.stringValue = "Install with: brew install llama.cpp\nModel: an instruct model in GGUF format, such as a Qwen or Llama Q4_K_M file."
        }
    }

    @objc private func backendChanged(_ sender: Any?) {
        // Each runner takes a different kind of model; don't carry an MLX repo id over to llama.cpp.
        let old = loadConfig()
        modelField.stringValue = selectedBackend == old.backend ? old.model : (selectedBackend == .mlx ? defaultMLXModel : "")
        updateHints()
    }

    private func modelStatus(_ config: BackendConfig) -> String {
        switch missingModel(config) {
        case nil: return config.model.isEmpty ? "✓ bundled in the runner" : "✓ on this Mac"
        case .modelMissing?: return "✗ not on this Mac. Pick one from “Found on this Mac”."
        default: return "✗ not set"
        }
    }

    private var editedFolders: [String] {
        foldersField.stringValue.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    @objc private func addFolder(_ sender: Any?) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.prompt = "Add"
        guard open.runModal() == .OK, let url = open.url else { return }
        foldersField.stringValue = (editedFolders + [url.path]).filter { !$0.isEmpty }.joined(separator: ":")
    }

    private var editedConfig: BackendConfig {
        var config = loadConfig()
        config.backend = selectedBackend
        let runner = runnerField.stringValue.trimmingCharacters(in: .whitespaces)
        config.executable = runner.isEmpty ? nil : (runner as NSString).expandingTildeInPath
        config.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        if config.backend != .mlx { config.model = (config.model as NSString).expandingTildeInPath }
        config.maxTokens = max(16, tokensField.integerValue)
        return config
    }

    private func saveAll() {
        saveConfig(editedConfig)
        saveKeepLoadedMinutes(keepLoadedField.integerValue)
        saveModelFolders(editedFolders)
        onSave?()
    }

    @objc private func save(_ sender: Any?) {
        saveAll()
        window?.performClose(nil)
    }

    @objc private func tryIt(_ sender: Any?) {
        saveAll()
        onTryIt?("add a dark mode toggle to the settings page of our react app, it should remember the choice. dont touch the login flow")
    }
}

extension SettingsWindowController {
    // Rebuilt each time it opens, searching the folders as typed, not just as saved.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Found on this Mac", action: nil, keyEquivalent: "")  // A pull-down's title item.
        let config = editedConfig
        let models = localModels(folders: modelSearchFolders(current: config, extra: editedFolders.map { ($0 as NSString).expandingTildeInPath }))
        if models.isEmpty { menu.addItem(withTitle: "No models found", action: nil, keyEquivalent: "").isEnabled = false }
        for model in models {
            let item = ActionMenuItem(title: model.label) { [weak self] in self?.pick(model) }
            item.toolTip = model.id
            item.state = model.isCurrent(in: config) ? .on : .off
            menu.addItem(item)
        }
    }

    private func pick(_ model: LocalModel) {
        let config = editedConfig.choosing(model)
        backendPopup.selectItem(at: Backend.allCases.firstIndex(of: config.backend) ?? 0)
        runnerField.stringValue = config.executable ?? ""
        modelField.stringValue = config.model
        updateHints()
    }
}
