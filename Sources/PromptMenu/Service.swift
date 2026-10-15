import Cocoa

// macOS calls this when you pick Services → Rewrite as Agent Prompt with text highlighted in any
// app. Info.plist's NSServices entry names the method; the highlighted text arrives on the pasteboard.
final class ServiceProvider: NSObject {
    private let onText: (String) -> Void

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
    }

    @objc func rewriteAsAgentPrompt(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = RewriteError.emptyInput.localizedDescription as NSString
            return
        }
        onText(text)
    }
}
