import Foundation

// FEATURE_FUTURE §1: answering the model's [CONFIRM: …] questions without a model.
func testConfirmQuestions() throws {
    let text = """
    OBJECTIVE: Add dark mode [CONFIRM: which pages?].
    CONTEXT: React app. [CONFIRM:  where is the setting stored? ]
    STEPS: 1. Check [CONFIRM: which pages?] again.
    DONE WHEN: [CONFIRM: ] the toggle persists. [not a question]
    """
    // In order, each once, trimmed; an empty one isn't a question.
    checkEqual(confirmQuestions(in: text), ["which pages?", "where is the setting stored?"])
    checkEqual(confirmQuestions(in: "No questions."), [])
}

func testFillAnswers() throws {
    let text = "Pages: [CONFIRM: which pages?]. Store: [CONFIRM:  where stored? ]. Again: [CONFIRM: which pages?]."
    // Every copy of an answered question is replaced; unanswered and blank ones stay as they were.
    checkEqual(fill(text, answers: ["which pages?": "settings and profile", "where stored?": "  "]),
               "Pages: settings and profile. Store: [CONFIRM:  where stored? ]. Again: settings and profile.")
    checkEqual(fill(text, answers: [:]), text)
    // An answer containing $ or \\ is inserted as is, not read as a regex template.
    checkEqual(fill("[CONFIRM: cost?]", answers: ["cost?": "$5 \\1"]), "$5 \\1")
    // The checker's count goes down as questions are answered.
    let filled = fill(text, answers: ["which pages?": "settings"])
    checkEqual(checkPrompt(filled, source: "", style: .agentPrompt).confirmCount, 1)
}

func testPolishPrompt() throws {
    for style in Style.allCases {
        let prompt = polishSystemPrompt(sections: style.sections)
        for section in style.sections { check(prompt.contains(section), "\(style): polish prompt drops \(section)") }
        check(prompt.contains("[CONFIRM"), "\(style): unanswered questions must survive polishing")
    }
}
