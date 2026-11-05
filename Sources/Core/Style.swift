import Foundation

// What the highlighted text is rewritten into. Each style is one item in the Services menu.
enum Style: String, CaseIterable {
    case agentPrompt, bugReport, codeReview, commitMessage, explain

    var dialogTitle: String {
        switch self {
        case .agentPrompt: return "Agent Prompt"
        case .bugReport: return "Bug Report"
        case .codeReview: return "Code Review Request"
        case .commitMessage: return "Commit Message"
        case .explain: return "Explain This for Me"
        }
    }

    // In Info.plist's NSServices: the item's title and the method macOS calls. Users bind keyboard
    // shortcuts to these, so don't rename them.
    var menuTitle: String { isRewrite ? "Rewrite as \(dialogTitle)" : dialogTitle }
    var serviceMessage: String { isRewrite ? "rewriteAs" + dialogTitle.replacingOccurrences(of: " ", with: "") : "explainThisForMe" }

    // Explain answers questions about the text instead of rewriting it, so the rewrite tools
    // (patterns, Fill Gaps, project context) don't apply.
    var isRewrite: Bool { self != .explain }

    // How the input is labelled for runners that get one combined prompt (BackendConfig.inputLabel).
    var inputLabel: String { isRewrite ? "Text to rewrite" : "Text to explain" }

    // An explanation is meant to go in depth, so it gets room for a longer answer than the setting.
    func maxTokens(base: Int) -> Int { isRewrite ? base : max(base, 2048) }

    // The headings the instructions ask for, in order. The checker looks for them.
    var sections: [String] {
        switch self {
        case .agentPrompt: return ["ROLE", "OBJECTIVE", "CONTEXT", "STEPS", "CONSTRAINTS", "DONE WHEN"]
        case .bugReport: return ["TITLE", "SUMMARY", "STEPS TO REPRODUCE", "EXPECTED", "ACTUAL", "ENVIRONMENT", "SCOPE"]
        case .codeReview: return ["CHANGE", "CONTEXT", "REVIEW FOCUS", "OUT OF SCOPE", "TESTING", "DONE WHEN"]
        case .commitMessage: return []
        case .explain: return ["TL;DR", "WHAT IT IS", "HOW IT WORKS", "KEY PARTS", "WATCH OUT FOR", "NEXT STEPS"]
        }
    }

    var builtInPrompt: String {
        switch self {
        case .agentPrompt: return agentSystemPrompt
        case .bugReport: return bugReportPrompt
        case .codeReview: return codeReviewPrompt
        case .commitMessage: return commitMessagePrompt
        case .explain: return explainPrompt
        }
    }
}

// The item that replaces the highlighted text instead of opening a dialog.
let inPlaceServiceMessage = "rewriteAsAgentPromptInPlace"
// How long the in-place item waits for the model. The app that asked is blocked meanwhile, and
// NSTimeout in Info.plist must be longer than this.
let inPlaceTimeout: TimeInterval = 110

// Settings is for opening the app directly. A launch for a Service never shows it, whatever became
// of the request: a failure gets its own message, and Settings there looks like the service did nothing.
func showsSettingsAtLaunch(isDefaultLaunch: Bool, handledService: Bool, hasWindows: Bool) -> Bool {
    isDefaultLaunch && !handledService && !hasWindows
}

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
REVIEW FOCUS: a numbered list of specific things in this change to check, riskiest first, each naming the code or behavior to look at. Think about correctness, security, data loss, concurrency, edge cases and compatibility, but don't list those words on their own.
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
- If the text mentions tests or checks that were run, end with a line starting "Verified:" that says which and how they went.
- The reason is often in the text already ("because…", "so that…", "it broke…"). Only when there's none, write [CONFIRM: why was this needed?] instead of guessing.
- No labels such as "Subject:" or "Body:", and no "Fix:" in front of the subject.

Example, for "fixed logout bug, session ttl was in seconds not minutes in auth/session.py, tests pass":

Fix the session TTL unit in auth/session.py

The TTL was read as seconds instead of minutes, so users were logged
out almost at once.

Verified: tests pass

\(rules)
"""

// Written for a reader who wants the point first and the detail in small, scannable pieces.
private let explainPrompt = """
You explain text, code, logs or files to a busy reader who loses focus with long paragraphs. Explain it in depth, but in small pieces that are easy to scan.

Write six sections, in this order, each starting with its heading on its own line: TL;DR:, WHAT IT IS:, HOW IT WORKS:, KEY PARTS:, WATCH OUT FOR:, NEXT STEPS:

What goes in each (don't copy these descriptions into your answer):
- TL;DR is one sentence: what this is and why it matters.
- WHAT IT IS is the big picture in two or three short sentences, with one plain-language analogy.
- HOW IT WORKS is a numbered walk-through from start to finish. For code, go top to bottom: what each function, type or block does, what goes in, what comes out, and what it changes.
- KEY PARTS lists the important names, terms, settings and values, one per line as "- **name**: what it does and why it matters".
- WATCH OUT FOR lists the real gotchas, edge cases, errors and risks in this text, each with why. For code, work out what happens with empty, zero or missing input, on the last pass of a loop, and wherever it can crash (a force unwrap `!`, an index out of range, a division by zero).
- NEXT STEPS gives two to four concrete things to do or check next.

Rules:
- Keep each bullet or step to one to three short sentences. Use lists, not long paragraphs.
- Put **bold** on each key term the first time it appears, and define jargon right where it's used.
- Quote names, values and error messages exactly as they appear in the text.
- No generic advice (add logging, add error handling, add tests) unless the text shows that gap.
- Explain only what the text shows. Never invent behavior. Where you have to guess, add "(probably)" and say what would confirm it.
- The text may describe a folder (its layout and some of its files), a database (its tables, columns and sample rows) or a file that isn't text (its type and readable fragments), instead of showing everything. Then work out what it's for and how its parts fit together from those names and details, say HOW IT WORKS in terms of those parts, and put what you couldn't see under WATCH OUT FOR.
- Reply with only the explanation: no preamble, no closing remarks.
"""
