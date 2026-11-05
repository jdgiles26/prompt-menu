import Cocoa

// macOS calls these when you pick one of Prompt Menu's items under Services with text highlighted
// in any app. Info.plist's NSServices entries name the methods; the highlighted text arrives on
// the pasteboard.
final class ServiceProvider: NSObject {
    private let onText: (String, Style) -> Void
    private let replace: (String) -> Result<String, Error>
    private let onFailure: (Error, [URL]) -> Void

    // `onText` opens a dialog. `replace` returns the rewritten text, blocking until it's ready.
    // `onFailure` shows what went wrong: Finder doesn't show a service's error string, so a failure
    // that only sets it looks like nothing happened. It gets the files involved, if any.
    init(onText: @escaping (String, Style) -> Void, replace: @escaping (String) -> Result<String, Error>,
         onFailure: @escaping (Error, [URL]) -> Void) {
        self.onText = onText
        self.replace = replace
        self.onFailure = onFailure
    }

    @objc func rewriteAsAgentPrompt(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, as: .agentPrompt, error: error)
    }

    @objc func rewriteAsBugReport(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, as: .bugReport, error: error)
    }

    @objc func rewriteAsCodeReviewRequest(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, as: .codeReview, error: error)
    }

    @objc func rewriteAsCommitMessage(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        open(pasteboard, as: .commitMessage, error: error)
    }

    // Highlighted text, or text and code files right-clicked in Finder.
    @objc func explainThisForMe(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { open(pasteboard, as: .explain, error: error); return }
        do {
            onText(try explainInput(files: files.map(\.path)), .explain)
        } catch let failure {
            onFailure(failure, files)
        }
    }

    // Replaces the highlighted text. On failure the text stays as it was.
    @objc func rewriteAsAgentPromptInPlace(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = text(on: pasteboard, error: error) else { return }
        switch replace(text) {
        case .success(let prompt):
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
        case .failure(let failure):
            error.pointee = failure.localizedDescription as NSString
            onFailure(failure, [])
        }
    }

    private func open(_ pasteboard: NSPasteboard, as style: Style, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = text(on: pasteboard, error: error) else { return }
        onText(text, style)
    }

    private func text(on pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString>) -> String? {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = RewriteError.emptyInput.localizedDescription as NSString
            onFailure(RewriteError.emptyInput, [])
            return nil
        }
        return text
    }
}
