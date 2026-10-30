import Foundation

// The follow-up chat under a result. The runners answer one prompt and exit, so each question is
// sent with everything it needs: the highlighted text, the result shown, and the turns so far.
// They go in the system prompt and the question alone is the prompt: sent together as one message,
// a 3B model repeated the context back instead of answering. The turns live in the dialog only;
// nothing is saved.
struct ChatTurn: Equatable {
    var question: String
    var answer: String
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
        : "Answer in the same easy-to-scan way as the explanation: the point first, short bullets or numbered steps, **bold** on key terms, jargon defined where it's used."
}

func chatSystemPrompt(style: Style) -> String {
    let format = chatFormat(style)
    return """
    You answer the user's follow-up questions about some text they highlighted and the \(style.dialogTitle.lowercased()) result made from it. Both are below, with the conversation so far.

    Rules:
    - Answer every question. Put the answer itself in the first sentence. Never refuse, skip or change the subject, and never say you can't answer.
    - Use the text and the result first, and quote names and values from them exactly.
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
        let text = "You: \(turn.question)\nAssistant: \(turn.answer)"
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

// A reply that isn't an answer: a first sentence that refuses or points at the text, or the context
// repeated back. Small models do both on questions the text doesn't cover. Quoting a line of the
// text is fine; that's what an explanation does.
func isNonAnswer(_ reply: String, context: String) -> Bool {
    let first = reply.range(of: "^[^\\n]*?(?:[.!?](?=\\s)|\\n|$)", options: .regularExpression).map { String(reply[$0]) } ?? reply
    let refusals = ["^(?:i'm|i am) sorry", "\\b(?:can't|cannot|unable to) answer",
                    "\\b(?:text|result|context|code|file)\\b[^.\\n]{0,40}\\b(?:does not|doesn't|do not|don't|did not|didn't) (?:contain|mention|include|say|cover)"]
    if refusals.contains(where: { first.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { return true }
    // A heading of the context alone on its line: "The result: 3" is an answer, "The result:\n…" an echo.
    if reply.range(of: "(?m)^(?:The highlighted text|The result|Conversation so far):\\s*$", options: .regularExpression) != nil { return true }
    let opening = String(reply.prefix(200))
    return opening.count == 200 && context.contains(opening)
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
    withContext.systemPrompt = chatSystemPrompt(style: style) + "\n\n" + context
    let answer = try rewrite(question, config: withContext, warm: warm, searchDirs: searchDirs, timeout: timeout,
                             started: started, progress: progress, notice: notice)
    // Stopped meanwhile (a kept-loaded model returns what it wrote so far): don't start another run.
    // A different question answered with an earlier answer word for word is no answer either.
    let repeated = history.contains { $0.answer == answer && $0.question != question }
    guard !isStopped(), repeated || isNonAnswer(answer, context: context) else { return answer }
    notice?("The model didn't answer from the text, so it answered from general knowledge instead.")
    var alone = config
    alone.systemPrompt = """
    Answer the user's question directly from your general knowledge. Put the answer itself in the first sentence. Never refuse or say you can't answer. If you're unsure, give your best answer first, then one short line on what you're unsure of.
    \(chatFormat(style))
    """
    return try rewrite(question, config: alone, warm: warm, searchDirs: searchDirs, timeout: timeout,
                       started: started, progress: progress, notice: notice)
}
