import Cocoa

// Which local runner and model to use. Shown when Prompt Menu is opened directly.
final class SettingsWindowController: NSWindowController {
    private let backendPopup = NSPopUpButton()
    private let runnerField = NSTextField()
    private let modelField = NSTextField()
    private let tokensField = NSTextField()
    private let hint = NSTextField(wrappingLabelWithString: "")
    var onTryIt: ((String) -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Prompt Menu"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        layout(in: window)
        show(loadConfig())
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func layout(in window: NSWindow) {
        for backend in Backend.allCases { backendPopup.addItem(withTitle: backend.displayName) }
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged(_:))
        tokensField.formatter = { let f = NumberFormatter(); f.minimum = 16; f.maximum = 8192; return f }()
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.isSelectable = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Runner:"), backendPopup],
            [NSTextField(labelWithString: "Runner path:"), runnerField],
            [NSTextField(labelWithString: "Model:"), modelField],
            [NSTextField(labelWithString: "Max tokens:"), tokensField],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.column(at: 1).width = 400
        tokensField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let note = NSTextField(wrappingLabelWithString:
            "Highlight text in any app, then choose Services → Rewrite as Agent Prompt from its right-click or app menu. The model runs on this Mac; nothing is sent anywhere.")
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
        tokensField.integerValue = config.maxTokens
        updateHints()
    }

    private func updateHints() {
        let backend = selectedBackend
        runnerField.placeholderString = "Search PATH and Homebrew for \(backend.executableName)"
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

    @objc private func save(_ sender: Any?) {
        saveConfig(editedConfig)
        window?.performClose(nil)
    }

    @objc private func tryIt(_ sender: Any?) {
        saveConfig(editedConfig)
        onTryIt?("add a dark mode toggle to the settings page of our react app, it should remember the choice. dont touch the login flow")
    }
}
