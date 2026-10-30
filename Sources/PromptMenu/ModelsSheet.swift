import Cocoa

// Tick the models for Compare Models or Review. They run one at a time, since two rarely fit in
// memory together. `option` adds one more checkbox (on by default), passed to `estimate` and `onStart`.
final class ModelsSheet: NSWindowController {
    private let models: [LocalModel]
    private let boxes: [NSButton]
    private let optionBox: NSButton?
    private let intro: String
    private let estimate = NSTextField(labelWithString: "")
    private let start: NSButton
    private let estimateFor: ([LocalModel], Bool) -> ClosedRange<Int>
    private let onStart: ([LocalModel], Bool) -> Void

    init(models: [LocalModel], current: BackendConfig, intro: String, action: String, option: String? = nil,
         estimate: @escaping ([LocalModel], Bool) -> ClosedRange<Int>, onStart: @escaping ([LocalModel], Bool) -> Void) {
        self.models = models
        self.intro = intro
        self.estimateFor = estimate
        self.onStart = onStart
        start = NSButton(title: action, target: nil, action: nil)
        let box = option.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        box?.state = .on
        optionBox = box
        boxes = models.map { model in
            let box = NSButton(checkboxWithTitle: model.label + (fitsInMemory(model) ? "" : " · may not fit in memory"), target: nil, action: nil)
            box.state = model.isCurrent(in: current) ? .on : .off
            box.toolTip = model.id
            return box
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        (boxes + [optionBox].compactMap { $0 }).forEach { $0.target = self; $0.action = #selector(update(_:)) }
        layout(in: window)
        update(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func layout(in window: NSWindow) {
        let intro = NSTextField(wrappingLabelWithString: self.intro)
        let list = NSStackView(views: boxes + [optionBox].compactMap { $0 })
        list.orientation = .vertical
        list.alignment = .leading
        estimate.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1B}"
        start.target = self
        start.action = #selector(begin(_:))
        start.keyEquivalent = "\r"
        let content = window.contentView!
        for view in [intro, list, estimate, cancel, start] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            intro.widthAnchor.constraint(equalToConstant: 480),
            list.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            list.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            estimate.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 12),
            estimate.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            start.topAnchor.constraint(equalTo: estimate.bottomAnchor, constant: 16),
            start.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            start.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: start.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: start.centerYAnchor),
        ])
    }

    private var chosen: [LocalModel] { zip(models, boxes).filter { $0.1.state == .on }.map(\.0) }

    @objc private func update(_ sender: Any?) {
        let range = estimateFor(chosen, optionBox?.state == .on)
        start.isEnabled = !chosen.isEmpty
        estimate.stringValue = chosen.isEmpty ? "Tick at least one model."
            : "About \(minutesAndSeconds(range.lowerBound))–\(minutesAndSeconds(range.upperBound)). Close or Try Again stops it."
    }

    private func minutesAndSeconds(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    @objc private func cancel(_ sender: Any?) { end() }

    @objc private func begin(_ sender: Any?) {
        let models = chosen, option = optionBox?.state == .on, handler = onStart
        // Ending the sheet lets the dialog release this controller, so nothing after it uses self.
        end()
        handler(models, option)
    }

    private func end() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
