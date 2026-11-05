import Foundation

// The follow-up chat under a result. The runners answer one prompt and exit, so each question is
// sent with everything it needs: the highlighted text, the result shown, and the turns so far.
// They go in the system prompt and the question alone is the prompt: sent together as one message,
// a 3B model repeated the context back instead of answering. The turns live in the dialog only;
// nothing is saved.
struct ChatTurn: Equatable {
    var question: String
    var answer: String

    // How a turn reads, in the dialog and in what the model is sent.
    var text: String { "You: \(question)\nAssistant: \(answer)" }
}

// More than a rewrite's input, since it carries the result and the turns too, but still within
// what a small model's context (and an 8 GB Mac) handles.
let maxChatCharacters = 12000

// Fixed shares of it: the start of the result and the newest turns; the highlighted text gets the
// rest, up to what the first run saw. So a long text can't push the conversation out.
private let resultRoom = 3000
private let turnsRoom = 3000

private func chatFormat(_ style: Style) -> String {
    style.isRewrite
        ? "Be clear and concise. When the user asks for a change to the result, reply with the changed text in full."
        : "Keep answers easy to scan: the point first, then short bullets or numbered steps if needed, **bold** on key terms, jargon defined where it's used."
}

func chatSystemPrompt(style: Style) -> String {
    let format = chatFormat(style)
    return """
    You answer the user's follow-up questions about some text they highlighted and the \(style.dialogTitle.lowercased()) result made from it. Both are below, with the conversation so far.

    Rules:
    - Answer every question. Put the answer itself in the first sentence. Never refuse, skip or change the subject, and never say you can't answer.
    - Answer only what was asked: don't repeat or redo the result unless the user asks for that.
    - Use the text and the result first, and quote names and values from them exactly.
    - For a question about what code does in some case, follow the code line by line for that case before you answer, and quote the line that decides it.
    - If they don't cover the question, answer it anyway from your general knowledge, as any assistant would.
    - If you're unsure, give your best answer first, then one short line on what you're unsure of.
    - Off-topic questions get a real answer too.
    - \(format)
    - Reply with only the answer: no preamble.
    """
}

// The highlighted text, the result and the turns so far, within maxChatCharacters. Goes after
// chatSystemPrompt.
func chatContext(source: String, result: String, history: [ChatTurn]) -> String {
    // Newest first, until turnsRoom is used; the newest is cut to fit rather than dropped.
    var turns: [String] = [], room = turnsRoom
    for turn in history.reversed() {
        let text = turn.text
        guard text.count <= room else {
            if turns.isEmpty { turns.append(String(text.prefix(room))) }
            break
        }
        turns.append(text)
        room -= text.count + 2
    }
    let rest = ["The result:\n\(result.prefix(resultRoom))"]
        + (turns.isEmpty ? [] : ["Conversation so far:\n\(turns.reversed().joined(separator: "\n\n"))"])
    let tail = rest.joined(separator: "\n\n")
    let head = "The highlighted text:\n"
    let sourceRoom = min(maxInputCharacters, maxChatCharacters - head.count - 2 - tail.count)
    return head + source.prefix(max(0, sourceRoom)) + "\n\n" + tail
}

// A reply that clearly isn't an answer: a first sentence that apologizes, says it can't answer or
// that the text has no information on it, a heading of the context alone on its line (the context
// echoed back), or the result returned unchanged. Small models do these on questions the text
// doesn't cover. Only clear cases count: a false alarm throws away a right answer, such as "The
// code doesn't include any error handling" or an edited result, for a guess without the text.
func isNonAnswer(_ reply: String, result: String) -> Bool {
    let text = reply.replacingOccurrences(of: "\u{2019}", with: "'")  // Typographic apostrophes.
    let first = text.range(of: "^[^\\n]*?(?:[.!?](?=\\s)|\\n|$)", options: .regularExpression).map { String(text[$0]) } ?? text
    let refusals = ["^(?:sorry|i'm sorry|i am sorry)\\b",
                    "\\b(?:can't|cannot|unable to) answer\\b",
                    "\\bi (?:can't|cannot|am unable to|'m unable to|am not able to) help\\b",
                    "\\b(?:unsure|not sure) how to answer\\b",
                    "\\b(?:do|does|did)(?: not|n't) (?:contain|mention|include|cover|provide|have|say) (?:any |enough )?(?:information|instructions|details)\\b",
                    "\\b(?:do|does|did)(?: not|n't) (?:cover|address|answer) (?:the|this|that|your) question\\b"]
    if refusals.contains(where: { first.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return true }
    // "The result: 3" is an answer; "The result:" alone on its line starts an echo.
    if text.range(of: "(?m)^(?:The highlighted text|The result|Conversation so far):\\s*$", options: .regularExpression) != nil { return true }
    return text.trimmingCharacters(in: .whitespacesAndNewlines) == result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// One follow-up: asked with the dialog's context, and if that gets no answer, once more without it,
// so every question gets one. Blocks; call it off the main thread. The callbacks are rewrite's;
// `isStopped` is checked between the two runs.
func answerFollowUp(_ question: String, style: Style, source: String, result: String, history: [ChatTurn],
                    config: BackendConfig, warm: WarmRunner? = nil, searchDirs: [String] = standardSearchDirs(),
                    timeout: TimeInterval = 300, started: ((@escaping () -> Void) -> Void)? = nil,
                    progress: ((String) -> Void)? = nil, notice: ((String) -> Void)? = nil,
                    isStopped: () -> Bool = { false }) throws -> String {
    let context = chatContext(source: source, result: result, history: history)
    var withContext = config
    withContext.inputLabel = "Question"
    withContext.systemPrompt = chatSystemPrompt(style: style) + "\n\n" + context
    let answer = try rewrite(question, config: withContext, warm: warm, searchDirs: searchDirs, timeout: timeout,
                             started: started, progress: progress, notice: notice)
    // Stopped meanwhile (a kept-loaded model returns what it wrote so far): don't start another run.
    // A different question answered with an earlier answer word for word is the model stuck on it.
    // Short answers ("No.") can be right twice.
    let repeated = answer.count >= 40 && history.contains { $0.answer == answer && $0.question != question }
    guard !isStopped(), repeated || isNonAnswer(answer, result: result) else { return answer }
    notice?("The model didn't answer from the text, so it answered from general knowledge instead.")
    var alone = config
    alone.inputLabel = "Question"
    alone.systemPrompt = """
    Answer the user's question directly from your general knowledge. Put the answer itself in the first sentence. Never refuse or say you can't answer. If you're unsure, give your best answer first, then one short line on what you're unsure of.
    \(chatFormat(style))
    """
    return try rewrite(question, config: alone, warm: warm, searchDirs: searchDirs, timeout: timeout,
                       started: started, progress: progress, notice: notice)
}

// A follow-up answer that edits the result, as the whole result to keep as a new version, or nil if
// it isn't an edit. Small models asked to change one line return only that section, so each section
// in the answer replaces the same section of the result, and the rest stays. Text before the first
// heading ("Here's the updated section:") is dropped. Only for styles with sections.
func chatEdit(_ answer: String, of result: String, style: Style) -> String? {
    guard style.isRewrite, !style.sections.isEmpty else { return nil }
    let names = style == .agentPrompt ? style.sections + ["WORKFLOW PATTERN"] : style.sections
    let new = sectionParts(answer, names: names), old = sectionParts(result, names: names)
    guard !new.parts.isEmpty else { return nil }
    var merged: String
    if Set(new.parts.map(\.name)).isSuperset(of: style.sections) {
        merged = new.parts.map(\.text).joined(separator: "\n")
    } else {
        let replacement = Dictionary(new.parts.map { ($0.name, $0.text) }, uniquingKeysWith: { first, _ in first })
        let kept = old.parts.map { replacement[$0.name] ?? $0.text }
        let added = new.parts.filter { part in !old.parts.contains { $0.name == part.name } }.map(\.text)
        merged = ([old.prefix].filter { !$0.isEmpty } + kept + added).joined(separator: "\n")
    }
    merged = merged.trimmingCharacters(in: .whitespacesAndNewlines)
    return merged == result.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : merged
}

// The text before the first heading, then each section from its heading to the next, trimmed.
private func sectionParts(_ text: String, names: [String]) -> (prefix: String, parts: [(name: String, text: String)]) {
    let alternatives = names.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "[ \\t]+") }
    let regex = try! NSRegularExpression(pattern: "(?im)^[ \\t#>*_-]*(\(alternatives.joined(separator: "|")))[ \\t*_]*:")
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard let first = matches.first else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), []) }
    let prefix = ns.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = matches.enumerated().map { i, match -> (name: String, text: String) in
        let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
        let name = ns.substring(with: match.range(at: 1)).uppercased().replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let body = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
        return (name, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return (prefix, parts)
}
