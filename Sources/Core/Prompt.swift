import Foundation

// What the model is asked to do with the highlighted text. Small local models follow a fixed
// outline far better than an open-ended "improve this", so the sections are spelled out.
let agentSystemPrompt = """
You rewrite rough notes into a prompt for an autonomous AI coding or research agent.

Turn the user's text into a clear, self-contained agentic workflow prompt with these sections, in this order:

ROLE: who the agent should act as, in one line.
OBJECTIVE: the exact outcome wanted, in one or two sentences.
CONTEXT: facts from the text the agent needs (files, tools, systems, people, links). Nothing else.
STEPS: a numbered plan the agent can follow, starting with understanding the current state and ending with checking the result.
CONSTRAINTS: what the agent must not do or change, and any limits on tools, time or scope.
DONE WHEN: concrete, checkable signs that the task is finished.

Rules:
- Keep every fact, name and number from the text. Never invent details.
- Where something the agent would need is missing or unclear, write [CONFIRM: what to ask] instead of guessing.
- Write in the imperative, addressed to the agent. Be concise.
- Reply with only the prompt: no preamble, no explanation, no closing remarks.
"""

// Highlighted text beyond this is cut off. A few pages of notes; much more and small models lose
// the thread, and the context window (and memory) runs out on 8 GB Macs.
let maxInputCharacters = 8000

enum RewriteError: Error, Equatable {
    case emptyInput
    case executableNotFound(String)
    case modelNotSet
    case failed(status: Int32, message: String)
    case timedOut
    case emptyOutput
}

extension RewriteError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyInput: return "There's no text to rewrite. Highlight some text first."
        case .executableNotFound(let name):
            return "Couldn't find \(name). Install it, or set its full path in Prompt Menu's settings."
        case .modelNotSet: return "No model is set. Choose one in Prompt Menu's settings."
        case .failed(let status, let message):
            return "The model runner stopped with exit code \(status).\n\n\(message.isEmpty ? "It printed no error." : message)"
        case .timedOut: return "The model took too long and was stopped. Try a smaller model or shorter text."
        case .emptyOutput: return "The model didn't return any text."
        }
    }
}

// Trimmed, non-empty and no longer than maxInputCharacters.
func prepareInput(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RewriteError.emptyInput }
    return String(trimmed.prefix(maxInputCharacters))
}

// For runners that take a single prompt and no separate system prompt.
func combinedPrompt(_ input: String, systemPrompt: String = agentSystemPrompt) -> String {
    "\(systemPrompt)\n\nText to rewrite:\n\(input)"
}

// The model's reply without the runner's noise around it. Also called on partial output while it
// streams, so it must be cheap and must never show half of a marker it would later remove.
func cleanOutput(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
    // Still thinking (mid-stream): nothing to show yet.
    text = text.replacingOccurrences(of: "(?s)<think>.*$", with: "", options: .regularExpression)
    // mlx_lm.generate's separators and stats, and llama.cpp's end marker.
    let noise = ["^=+$", "^Prompt: \\d+ tokens", "^Generation: \\d+ tokens", "^Peak memory:", "^\\[end of text\\]$"]
    text = text.components(separatedBy: "\n")
        .filter { line in !noise.contains { line.range(of: $0, options: .regularExpression) != nil } }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // A reply wrapped whole in one code fence: keep what's inside.
    let lines = text.components(separatedBy: "\n")
    if lines.count >= 2, lines[0].hasPrefix("```"), lines[lines.count - 1] == "```",
       !lines.dropFirst().dropLast().contains(where: { $0.hasPrefix("```") }) {
        text = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

// The Services menu item's method name, in Info.plist's NSMessage and on the app's services provider.
let serviceMessage = "rewriteAsAgentPrompt"
