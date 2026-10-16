import Foundation

// What the highlighted text is rewritten into. Each style is one item in the Services menu.
enum Style: String, CaseIterable {
    case agentPrompt, bugReport, codeReview, commitMessage

    var dialogTitle: String {
        switch self {
        case .agentPrompt: return "Agent Prompt"
        case .bugReport: return "Bug Report"
        case .codeReview: return "Code Review Request"
        case .commitMessage: return "Commit Message"
        }
    }

    // In Info.plist's NSServices: the item's title and the method macOS calls. Users bind keyboard
    // shortcuts to these, so don't rename them.
    var menuTitle: String { "Rewrite as \(dialogTitle)" }
    var serviceMessage: String { "rewriteAs" + dialogTitle.replacingOccurrences(of: " ", with: "") }

    // The headings the instructions ask for, in order. The checker looks for them.
    var sections: [String] {
        switch self {
        case .agentPrompt: return ["ROLE", "OBJECTIVE", "CONTEXT", "STEPS", "CONSTRAINTS", "DONE WHEN"]
        case .bugReport: return ["TITLE", "SUMMARY", "STEPS TO REPRODUCE", "EXPECTED", "ACTUAL", "ENVIRONMENT"]
        case .codeReview: return ["CHANGE", "CONTEXT", "REVIEW FOCUS", "OUT OF SCOPE", "TESTING", "DONE WHEN"]
        case .commitMessage: return []
        }
    }

    var builtInPrompt: String {
        switch self {
        case .agentPrompt: return agentSystemPrompt
        case .bugReport: return bugReportPrompt
        case .codeReview: return codeReviewPrompt
        case .commitMessage: return commitMessagePrompt
        }
    }
}

// The item that replaces the highlighted text instead of opening a dialog.
let inPlaceServiceMessage = "rewriteAsAgentPromptInPlace"
// How long the in-place item waits for the model. The app that asked is blocked meanwhile, and
// NSTimeout in Info.plist must be longer than this.
let inPlaceTimeout: TimeInterval = 110

// The instructions for a style. The systemPrompt setting replaces only the agent prompt's.
func systemPrompt(for style: Style, config: BackendConfig) -> String {
    style == .agentPrompt ? config.systemPrompt : style.builtInPrompt
}

private let rules = """
Rules:
- Keep every fact, name, number and error message from the text. Never invent details.
- Where something needed is missing or unclear, write [CONFIRM: what to ask] instead of guessing.
- Be concise.
- Reply with only the result: no preamble, no explanation, no closing remarks.
"""

private let bugReportPrompt = """
You rewrite rough notes into a clear bug report that a developer or a coding agent can act on.

Use these sections, in this order:

TITLE: the symptom and where it happens, in one line.
SUMMARY: what goes wrong and who it affects, in one or two sentences.
STEPS TO REPRODUCE: a numbered list, starting from a known state.
EXPECTED: what should happen.
ACTUAL: what happens instead, with error messages quoted exactly.
ENVIRONMENT: versions, OS, browser, device, configuration and data named in the text.
SCOPE: the suspected area, and what is known to still work.

\(rules)
"""

private let codeReviewPrompt = """
You rewrite rough notes into a request for a code review, for a human reviewer or a review agent.

Use these sections, in this order:

CHANGE: what changed and why, in two or three sentences.
CONTEXT: files, modules, tickets and links named in the text.
REVIEW FOCUS: a numbered list of what to check, riskiest first: correctness, security, data loss, concurrency, edge cases, compatibility.
OUT OF SCOPE: what not to flag, such as style or code the change didn't touch.
TESTING: what was tested and how, and what wasn't.
DONE WHEN: what an approval needs.

\(rules)
"""

private let commitMessagePrompt = """
You rewrite rough notes into a git commit message.

Format:
- A subject line in the imperative mood ("Fix", "Add", "Remove"), at most 72 characters, with no period at the end.
- A blank line.
- A body wrapped at 72 characters that says what was wrong or missing, why this change fixes it, and anything the reader should know. Leave the body out if the subject says everything.
- If the text mentions tests or checks that were run, end with a line starting "Verified:".
- Where the reason for the change is missing, write [CONFIRM: why] instead of guessing.

\(rules)
"""
