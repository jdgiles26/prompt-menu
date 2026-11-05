import Cocoa

// Says why a Services request failed, and offers the way out when there is one. An ordinary window,
// not a modal alert: a modal alert stops the main thread's work, so other Services requests would
// wait behind it until they time out, and a quit (logout, or scripts/install.sh) would be ignored.
final class FailurePanelController: NSWindowController, NSWindowDelegate {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let files: [URL]
    private let explain: ([URL]) throws -> Void
    private var openPanel: NSOpenPanel?
    var onClose: (() -> Void)?

    // `explain` opens the dialog for the files the user chose, or throws if they still can't be read.
    init(error: Error, files: [URL], explain: @escaping ([URL]) throws -> Void) {
        self.files = files
        self.explain = explain
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Prompt Menu"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false  // Like the result dialog: macOS may not bring this app forward.
        super.init(window: panel)
        panel.delegate = self
        let title = NSTextField(labelWithString: "Prompt Menu couldn't do that")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.stringValue = error.localizedDescription
        label.preferredMaxLayoutWidth = 408
        label.isSelectable = true
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        chooseButton.target = self
        chooseButton.action = #selector(chooseFiles(_:))
        chooseButton.keyEquivalent = "\r"
        chooseButton.isHidden = (error as? RewriteError)?.offersFileChooser != true || files.isEmpty
        let content = panel.contentView!
        for view in [title, label, closeButton, chooseButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            chooseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            chooseButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: chooseButton.isHidden ? content.trailingAnchor : chooseButton.leadingAnchor,
                                                  constant: chooseButton.isHidden ? -16 : -8),
        ])
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // macOS treats picking a file in an Open dialog as the user's consent to read it, where a file
    // merely named on a Services pasteboard isn't.
    @objc private func chooseFiles(_ sender: Any?) {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = files.count > 1
        open.directoryURL = files[0].deletingLastPathComponent()
        open.prompt = "Explain"
        open.message = "Select \(files.map(\.lastPathComponent).joined(separator: ", ")) to let Prompt Menu read it."
        openPanel = open
        open.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK else { return }
            do {
                try self.explain(open.urls)
                self.window?.close()
            } catch RewriteError.protectedFile(let name) {
                self.show(protectedFileHelp(name))
            } catch {
                self.show(error.localizedDescription)
            }
        }
    }

    private func show(_ message: String) {
        label.stringValue = message
        chooseButton.isHidden = true
        window?.layoutIfNeeded()
    }

    @objc private func closeWindow(_ sender: Any?) { window?.close() }

    func windowWillClose(_ notification: Notification) {
        openPanel?.cancel(nil)
        onClose?()
    }
}
