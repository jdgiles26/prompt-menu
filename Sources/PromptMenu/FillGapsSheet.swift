import Cocoa

// One optional field per [CONFIRM: …] question. Apply hands back the answers and whether to polish.
final class FillGapsSheet: NSWindowController {
    private let questions: [String]
    private let fields: [NSTextField]
    private let polish = NSButton(checkboxWithTitle: "Polish the wording with the model afterwards", target: nil, action: nil)
    private let onApply: ([String: String], Bool) -> Void

    init(questions: [String], onApply: @escaping ([String: String], Bool) -> Void) {
        self.questions = questions
        self.onApply = onApply
        fields = questions.map { _ in NSTextField() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        layout(in: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func layout(in window: NSWindow) {
        let intro = NSTextField(wrappingLabelWithString: "Answer what you can. Unanswered questions stay in the prompt.")
        var rows: [[NSView]] = []
        for (question, field) in zip(questions, fields) {
            let label = NSTextField(wrappingLabelWithString: question)
            label.preferredMaxLayoutWidth = 200
            field.placeholderString = "Optional"
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            rows.append([label, field])
        }
        let grid = NSGridView(views: rows)
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.column(at: 0).width = 200
        polish.toolTip = "One more model run that smooths the wording, keeping every fact and section."
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
        apply.keyEquivalent = "\r"
        // Many questions scroll rather than grow the sheet off the screen.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scroll.documentView = document

        let content = window.contentView!
        for view in [intro, scroll, polish, cancel, apply] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let gridHeight = min(CGFloat(questions.count) * 34, 340)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: gridHeight),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            polish.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            polish.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            apply.topAnchor.constraint(equalTo: polish.bottomAnchor, constant: 16),
            apply.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            apply.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
        ])
        window.initialFirstResponder = fields.first
    }

    @objc private func cancel(_ sender: Any?) { end() }

    @objc private func apply(_ sender: Any?) {
        var answers: [String: String] = [:]
        for (question, field) in zip(questions, fields) { answers[question] = field.stringValue }
        let polishing = polish.state == .on, handler = onApply
        // Ending the sheet lets the dialog release this controller, so nothing after it uses self.
        end()
        handler(answers, polishing)
    }

    private func end() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}

// Scroll views put their document at the bottom unless it's flipped.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
