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
CONSTRAINTS: what the text says the agent must not do or change, and any limits on tools, time or scope. Never add a limit that blocks the objective.
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
    case modelMissing(String)  // Set, but not on this Mac: deleted, or never downloaded.
    case failed(status: Int32, message: String)
    case timedOut
    case emptyOutput
    case modelError(String)  // The kept-loaded model replied with an error, such as a model that isn't downloaded.
    case unreadableFile(String)  // Something from Finder that's gone, or that couldn't be read.
    case protectedFile(String)   // macOS or the file's permissions refused to open it.
    case emptyFile(String)
}

extension RewriteError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyInput: return "There's no text to rewrite. Highlight some text first."
        case .executableNotFound(let name):
            return "Couldn't find \(name). Install it, or set its full path in Prompt Menu's settings."
        case .modelNotSet: return "No model is set. Choose one in Prompt Menu's settings."
        case .modelMissing(let model):
            return "\(model) isn't on this Mac. It may have been deleted. Choose a model that is from the Model menu, or in Prompt Menu's settings."
        case .failed(let status, let message):
            return "The model runner stopped with exit code \(status).\n\n\(message.isEmpty ? "It printed no error." : message)"
        case .timedOut: return "The model took too long and was stopped. Try a smaller model or shorter text."
        case .emptyOutput: return "The model didn't return any text."
        case .modelError(let message): return "The model couldn't answer.\n\n\(message)"
        case .unreadableFile(let name): return "Couldn't read \(name). It may have been moved or deleted, or the disk it's on may not be available."
        case .protectedFile(let name):
            return "macOS didn't let Prompt Menu open \(name). It's in a protected place, such as a folder that belongs to another app, and macOS blocks this without asking.\n\nIf you choose it yourself, macOS can allow it."
        case .emptyFile(let name): return "\(name) is empty, so there's nothing to explain."
        }
    }
}

extension RewriteError {
    // Whether picking the file by hand can help: choosing it is what macOS treats as the user's consent.
    var offersFileChooser: Bool {
        if case .protectedFile = self { return true }
        return false
    }
}

// When even choosing the file didn't help. Prompt Menu asks for no permissions, so this only says what the user can do.
func protectedFileHelp(_ name: String) -> String {
    "macOS still won't let Prompt Menu open \(name).\n\nTo explain it anyway, open it in another app, highlight the text, and use Explain This for Me on that. Or, if you want Prompt Menu to read protected files, add it under System Settings → Privacy & Security → Full Disk Access. That's your call: the app doesn't need it for anything else, and each rebuild resets it."
}

// Trimmed, non-empty and no longer than maxInputCharacters.
func prepareInput(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RewriteError.emptyInput }
    return String(trimmed.prefix(maxInputCharacters))
}

// Anything chosen in Finder for Explain This for Me: each item's name, then its text or a description
// of it (ItemDescription.swift), all within maxInputCharacters. Items share that limit, so a big first
// one can't crowd the others out. Only what the user picked is read, and nothing is written.
func explainInput(files: [String]) throws -> String {
    guard !files.isEmpty else { throw RewriteError.emptyInput }
    // Past this each share is too small to say anything, so the rest are only named.
    let described = files.prefix(20)
    let leftOver = files.dropFirst(described.count).map { ($0 as NSString).lastPathComponent }
    let reserve = leftOver.isEmpty ? 0 : min(maxInputCharacters / 4, 40 + leftOver.joined(separator: ", ").count)
    var parts: [String] = []
    var used = reserve
    var firstFailure: RewriteError?
    var worked = 0
    for (index, path) in described.enumerated() {
        let share = (maxInputCharacters - used) / (described.count - index)
        do {
            parts.append(try describeItem(path, limit: share))
            worked += 1
        } catch RewriteError.protectedFile(let name) {
            // Stop here: Choose File can grant the whole selection, which beats explaining part of it.
            throw RewriteError.protectedFile(name)
        } catch let failure as RewriteError {
            guard described.count > 1 else { throw failure }
            firstFailure = firstFailure ?? failure
            parts.append("\((path as NSString).lastPathComponent): couldn't be read, or is empty.")
        }
        used += parts[parts.count - 1].count + 2
    }
    if worked == 0, let firstFailure { throw firstFailure }
    if !leftOver.isEmpty { parts.append("Also selected, not looked at: " + leftOver.joined(separator: ", ")) }
    return String(parts.joined(separator: "\n\n").prefix(maxInputCharacters))
}

// For runners that take a single prompt and no separate system prompt.
func combinedPrompt(_ input: String, systemPrompt: String = agentSystemPrompt, label: String = "Text to rewrite") -> String {
    "\(systemPrompt)\n\n\(label):\n\(input)"
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
    // llama.cpp may also put its end marker at the end of the last line.
    if text.hasSuffix("[end of text]") { text = String(text.dropLast("[end of text]".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    // "Here is the rewritten prompt:" on a line of its own, which small models add anyway.
    if let announcement = text.range(of: "^(?:(?:sure|okay|ok|certainly)[!,. ]*)?(?:here is|here's|below is)[^\\n]{0,60}:[ \\t]*\\n",
                                     options: [.regularExpression, .caseInsensitive]) {
        text = text[announcement.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // A reply wrapped whole in one code fence: keep what's inside.
    let lines = text.components(separatedBy: "\n")
    if lines.count >= 2, lines[0].hasPrefix("```"), lines[lines.count - 1] == "```",
       !lines.dropFirst().dropLast().contains(where: { $0.hasPrefix("```") }) {
        text = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}
