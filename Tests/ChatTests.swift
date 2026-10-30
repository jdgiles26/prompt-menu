import Foundation

// The follow-up chat under a result: every question gets an answer, with the dialog's text in context.
func testChatSystemPrompt() throws {
    for style in Style.allCases {
        let prompt = chatSystemPrompt(style: style).lowercased()
        check(prompt.contains("answer every question"), "\(style): the chat must answer every question")
        check(prompt.contains("general knowledge"), "\(style): questions the text doesn't cover still get an answer")
        check(prompt.contains("unsure"), "\(style): uncertainty is said, not used as a reason not to answer")
        check(prompt.contains("off-topic"), "\(style): off-topic questions are answered too")
        // A small model otherwise says it will use general knowledge and then doesn't answer.
        check(prompt.contains("first sentence"), "\(style): the answer itself comes first")
        check(prompt.contains("never say you can't answer"), "\(style): no non-answers")
        // With Qwen 2.5 3B, a "(general knowledge)" tag rule got the tag back instead of an answer.
        check(!prompt.contains("(general knowledge)"), "\(style): no tag for the model to reply with alone")
        // Seen with Qwen 2.5 3B: an off-topic question answered by writing the explanation again.
        check(prompt.contains("don't repeat or redo the result"), "\(style): answer the question, not the original task")
    }
    check(chatSystemPrompt(style: .explain).contains("**bold**"), "explain's follow-ups keep its easy-to-scan format")
}

// The context goes in the system prompt and the question alone is the prompt: sent together as one
// message, a 3B model repeated the context back instead of answering.
func testChatContext() throws {
    let history = [ChatTurn(question: "what is retries?", answer: "How many tries."),
                   ChatTurn(question: "why 3?", answer: "A guess.")]
    let context = chatContext(source: "retries = 3", result: "TL;DR: a setting", history: history)
    for part in ["retries = 3", "TL;DR: a setting", "You: what is retries?", "Assistant: How many tries.", "You: why 3?"] {
        check(context.contains(part), "the chat context is missing \(part)")
    }
    check(context.range(of: "what is retries?")!.lowerBound < context.range(of: "why 3?")!.lowerBound, "turns stay in order")
    check(!chatContext(source: "s", result: "r", history: []).contains("Conversation so far"), "no empty conversation heading")

    // Fixed budgets: the newest turns (oldest dropped first), the start of the result, and the
    // source in what's left. A long source must not wipe the conversation: explaining a big file
    // with every turn forgotten is the case this exists for.
    let longTurns = (1...40).map { ChatTurn(question: "question \($0)", answer: String(repeating: "a", count: 500)) }
    let trimmed = chatContext(source: "retries = 3", result: "TL;DR: a setting", history: longTurns)
    check(trimmed.count <= maxChatCharacters, "got \(trimmed.count) characters")
    check(!trimmed.contains("question 1\n") && trimmed.contains("question 40"), "the oldest turns are dropped first")
    check(trimmed.contains("retries = 3"), "the source stays")

    let bigFile = String(repeating: "s", count: maxInputCharacters)
    let full = chatContext(source: bigFile, result: String(repeating: "r", count: 5000), history: history)
    check(full.count <= maxChatCharacters, "got \(full.count) characters")
    check(full.contains("You: why 3?") && full.contains("You: what is retries?"), "a big file keeps the conversation")
    check(full.contains(String(repeating: "r", count: 2000)), "the start of the result stays")
    // Without turns, the source gets the room: everything the first run saw.
    check(chatContext(source: bigFile, result: "TL;DR: a setting", history: []).contains(bigFile), "the whole source fits")
    // An answer longer than the turns' room: the newest turn is cut, not dropped.
    let huge = chatContext(source: "s", result: "r", history: [ChatTurn(question: "newest?", answer: String(repeating: "b", count: 9000))])
    check(huge.count <= maxChatCharacters && huge.contains("You: newest?"), "the newest turn is kept, cut to fit")
    // The raw selection can be far longer than what the model saw.
    check(chatContext(source: String(repeating: "s", count: 100_000), result: "r", history: history).count <= maxChatCharacters, "a huge selection is cut")
}

// Through the real pipeline with a fake runner: the question is the prompt and the context is in the
// system prompt, each as one argument, never run by a shell.
func testChatRoundTrip() throws {
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, #"""
    while [ $# -gt 0 ]; do
      [ "$1" = "--prompt" ] && p="$2"; [ "$1" = "--system-prompt" ] && s="$2"; shift
    done
    case "$s" in *"retries = 3"*) printf 'Here is the answer:\n%s\n' "$p" ;; *) echo "no context" ;; esac
    """#)
    var config = BackendConfig(backend: .mlx, model: "m")
    config.systemPrompt = chatSystemPrompt(style: .explain) + "\n\n" + chatContext(source: "retries = 3", result: "r", history: [])
    checkEqual(try rewrite("it's \"quoted\"; $(rm -rf /) stays text", config: config, searchDirs: [dir], timeout: 10),
               "it's \"quoted\"; $(rm -rf /) stays text")
}

// Only clear non-answers are asked again, without the text: a false alarm throws away a right
// answer for a guess, which is worse than letting a vague reply stand. Each case was seen with
// Qwen 2.5 3B, or is a right answer an earlier version threw away.
func testChatNonAnswer() throws {
    let result = "TITLE: Login fails\nENVIRONMENT: macOS 14"
    for reply in ["I'm sorry, but the text provided does not contain instructions on how to make pancakes.",
                  "I’m sorry, but the text doesn’t mention that.",
                  "Sorry, I can't help with that from the text.",
                  "The highlighted text and the result do not cover the question of how to make pancakes.",
                  "The text doesn’t contain any information about Australia.",
                  "I can't answer that from the text.",
                  "Therefore, I am unsure how to answer this question based solely on the text.",
                  "The result:\nTL;DR: a limit",
                  result] {
        check(isNonAnswer(reply, result: result), "should count as no answer: \(reply)")
    }
    for reply in ["The capital of Australia is Canberra.", "12000", "No.", "Mix flour, eggs and milk, then fry.",
                  "`let x = 1` sets x to 1.", "It drops the oldest turns first.",
                  "The code doesn't include any error handling, so a nil input will crash.",
                  "The code doesn’t set a timeout.",
                  "It checks the reply. If the text doesn't contain an answer, it asks again.",
                  "The result: retries is 3, so it tries three times.",
                  // An edit request in a rewrite dialog: the result in full with one line changed.
                  "TITLE: Login fails\nENVIRONMENT: macOS 15"] {
        check(!isNonAnswer(reply, result: result), "is an answer: \(reply)")
    }
    // The same edit on a result long enough that its whole start is copied.
    let long = "SUMMARY: " + String(repeating: "Login fails after the session expires. ", count: 10) + "\nENVIRONMENT: macOS 14"
    check(!isNonAnswer(long.replacingOccurrences(of: "macOS 14", with: "macOS 15"), result: long), "an edited result is an answer")
}

// A non-answer is asked once more without the text, so the question still gets an answer.
func testChatFallback() throws {
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, #"""
    while [ $# -gt 0 ]; do [ "$1" = "--system-prompt" ] && s="$2"; shift; done
    case "$s" in *"The highlighted text:"*) echo "I'm sorry, the text does not contain that." ;; *) echo "Canberra." ;; esac
    """#)
    let config = BackendConfig(backend: .mlx, model: "m")
    var notices: [String] = []
    let answer = try answerFollowUp("capital of Australia?", style: .explain, source: "retries = 3", result: "r", history: [],
                                    config: config, searchDirs: [dir], timeout: 10, notice: { notices.append($0) })
    checkEqual(answer, "Canberra.")
    checkEqual(notices.count, 1)
    // An answer from the text is kept as it is: one run.
    let direct = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: direct, #"""
    while [ $# -gt 0 ]; do [ "$1" = "--system-prompt" ] && s="$2"; shift; done
    case "$s" in *"retries = 3"*) echo "It retries 3 times." ;; *) echo "wrong run" ;; esac
    """#)
    checkEqual(try answerFollowUp("how many retries?", style: .explain, source: "retries = 3", result: "r", history: [],
                                  config: config, searchDirs: [direct], timeout: 10), "It retries 3 times.")
}

// Stopped (Close or Try Again) during the first run: no second run is started.
func testChatFallbackStopped() throws {
    let dir = try makeTempFolder()
    let log = (dir as NSString).appendingPathComponent("runs")
    try makeScript("mlx_lm.generate", in: dir, "echo run >> '\(log)'; echo \"I'm sorry, the text does not contain that.\"")
    _ = try answerFollowUp("capital?", style: .explain, source: "s", result: "r", history: [], config: BackendConfig(backend: .mlx, model: "m"),
                           searchDirs: [dir], timeout: 10, isStopped: { true })
    checkEqual(try String(contentsOfFile: log, encoding: .utf8), "run\n")
}

// Seen with Qwen 2.5 3B: a new question answered with the last answer word for word. The same
// question asked again may get the same answer.
func testChatRepeatedAnswer() throws {
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, #"""
    while [ $# -gt 0 ]; do [ "$1" = "--system-prompt" ] && s="$2"; shift; done
    case "$s" in *"The highlighted text:"*) echo "The Copy button copies the current prompt to the clipboard." ;; *) echo "Canberra." ;; esac
    """#)
    let config = BackendConfig(backend: .mlx, model: "m")
    let history = [ChatTurn(question: "What does Copy do?", answer: "The Copy button copies the current prompt to the clipboard."),
                   ChatTurn(question: "Is it thread-safe?", answer: "No.")]
    checkEqual(try answerFollowUp("Capital of Australia?", style: .explain, source: "s", result: "r", history: history,
                                  config: config, searchDirs: [dir], timeout: 10), "Canberra.")
    checkEqual(try answerFollowUp("What does Copy do?", style: .explain, source: "s", result: "r", history: history,
                                  config: config, searchDirs: [dir], timeout: 10), "The Copy button copies the current prompt to the clipboard.")
}

// A short answer can be right for two questions ("No." twice); only a longer one repeated word for
// word is the model stuck on its last answer.
func testChatShortRepeatIsAnAnswer() throws {
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, #"""
    while [ $# -gt 0 ]; do [ "$1" = "--system-prompt" ] && s="$2"; shift; done
    case "$s" in *"The highlighted text:"*) echo "No." ;; *) echo "guessed" ;; esac
    """#)
    let history = [ChatTurn(question: "Is it thread-safe?", answer: "No.")]
    checkEqual(try answerFollowUp("Does it handle nil?", style: .explain, source: "s", result: "r", history: history,
                                  config: BackendConfig(backend: .mlx, model: "m"), searchDirs: [dir], timeout: 10), "No.")
}

// llamafile gets one combined prompt; a follow-up is labelled as a question, not as text to rewrite.
func testChatLlamafileLabel() throws {
    let dir = try makeTempFolder()
    try makeScript("llamafile", in: dir, #"""
    while [ $# -gt 0 ]; do [ "$1" = "-p" ] && p="$2"; shift; done
    printf '%s\n' "$p" | tail -2 | head -1
    """#)
    let answer = try answerFollowUp("what is x?", style: .explain, source: "s", result: "r", history: [],
                                    config: BackendConfig(backend: .llamafile, model: ""), searchDirs: [dir], timeout: 10)
    checkEqual(answer, "Question:")
}
