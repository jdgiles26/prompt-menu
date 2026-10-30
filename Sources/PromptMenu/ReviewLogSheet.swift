import Cocoa

// The last review's steps, read-only: who judged what and how sure, and what each hardening pass
// changed. It lives only in the dialog and isn't saved.
final class ReviewLogSheet: NSWindowController {
    init(text: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 420, height: 260)
        super.init(window: window)
        let textView = NSTextView()
        textView.isEditable = false
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let close = NSButton(title: "Close", target: self, action: #selector(close(_:)))
        close.keyEquivalent = "\u{1B}"
        let content = window.contentView!
        for view in [scroll, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func close(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
