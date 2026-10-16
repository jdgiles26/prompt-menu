import Cocoa

// macOS calls these when you pick one of Prompt Menu's items under Services with text highlighted
// in any app. Info.plist's NSServices entries name the methods; the highlighted text arrives on
// the pasteboard.
final class ServiceProvider: NSObject {
    private let onText: (String, Style) -> Void
    private let replace: (String) -> Result<String, Error>

    // `onText` opens a dialog. `replace` returns the rewritten text, blocking until it's ready.
    init(onText: @escaping (String, Style) -> Void, replace: @escaping (String) -> Result<String, Error>) {
        self.onText = onText
        self.replace = replace
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

    // Replaces the highlighted text. On failure the text stays as it was and macOS shows the error.
    @objc func rewriteAsAgentPromptInPlace(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = text(on: pasteboard, error: error) else { return }
        switch replace(text) {
        case .success(let prompt):
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
        case .failure(let failure):
            error.pointee = failure.localizedDescription as NSString
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
            return nil
        }
        return text
    }
}
