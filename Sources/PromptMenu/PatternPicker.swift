import Cocoa

// Chooses an agentic pattern: the shortlist for the prompt, or any of the catalog through search.
// The model's pick, when it gives one, is marked ★ and selected.
final class PatternPickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let candidates: [AgenticPattern]
    private let all: [AgenticPattern]
    private let onApply: (AgenticPattern) -> Void
    private var rows: [AgenticPattern]
    private var suggested: String?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")

    init(candidates: [AgenticPattern], all: [AgenticPattern], onApply: @escaping (AgenticPattern) -> Void) {
        self.candidates = candidates
        self.all = all
        self.onApply = onApply
        rows = candidates
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 440))
        let heading = NSTextField(labelWithString: "Restructure the prompt around a workflow pattern")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        search.placeholderString = "Search all \(all.count) patterns"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))

        let column = NSTableColumn(identifier: .init("pattern"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(apply(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 6
        let credit = NSTextField(labelWithString: "From Awesome Agentic Patterns by Nikola Balic and contributors (Apache-2.0).")
        credit.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        credit.textColor = .tertiaryLabelColor
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
        applyButton.keyEquivalent = "\r"

        for subview in [heading, search, scroll, detail, credit, applyButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(equalToConstant: 236),
            detail.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            applyButton.topAnchor.constraint(greaterThanOrEqualTo: detail.bottomAnchor, constant: 8),
            applyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            applyButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            credit.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            credit.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            credit.trailingAnchor.constraint(lessThanOrEqualTo: applyButton.leadingAnchor, constant: -8),
        ])
        self.view = view
        table.reloadData()
        select(0)
    }

    // The model's pick, as an index into the shortlist.
    func suggest(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        suggested = candidates[index].slug
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.slug == suggested }) { select(row) }
    }

    private func select(_ row: Int) {
        guard rows.indices.contains(row) else { detail.stringValue = ""; return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        showDetail(rows[row])
    }

    private func showDetail(_ p: AgenticPattern) {
        detail.stringValue = "Use when: \(p.signals.joined(separator: "; "))\nAvoid when: \(p.antiSignals.joined(separator: "; "))"
    }

    @objc private func searchChanged(_ sender: Any?) {
        rows = search.stringValue.isEmpty ? candidates : searchPatterns(search.stringValue, in: all)
        table.reloadData()
        select(0)
    }

    @objc private func apply(_ sender: Any?) {
        guard rows.indices.contains(table.selectedRow) else { return }
        onApply(rows[table.selectedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if rows.indices.contains(table.selectedRow) { showDetail(rows[table.selectedRow]) }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = rows[row]
        let title = NSTextField(labelWithString: (p.slug == suggested ? "★ " : "") + p.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        let summary = NSTextField(labelWithString: "\(p.category) · \(p.summary)")
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for field in [title, summary] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        stack.toolTip = p.summary
        return stack
    }
}
