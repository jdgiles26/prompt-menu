import Foundation

private func bundled() throws -> [AgenticPattern] { try loadPatterns(from: "Resources/patterns.json") }

func testPatternsCatalog() throws {
    let patterns = try bundled()
    check(patterns.count >= 150, "only \(patterns.count) patterns")
    checkEqual(Set(patterns.map(\.slug)).count, patterns.count)
    for p in patterns where p.title.isEmpty || p.summary.isEmpty || p.solution.isEmpty || p.category.isEmpty {
        check(false, "\(p.slug) is incomplete")
    }
    // Apache-2.0 asks for the license and an attribution notice next to the derived file.
    let notice = try String(contentsOfFile: "Resources/NOTICE-agentic-patterns.txt", encoding: .utf8)
    check(notice.contains("Apache License"), "the NOTICE must carry the Apache license")
}

func testPatternShortlist() throws {
    let patterns = try bundled()
    let planning = """
    OBJECTIVE: Migrate the billing service to the new payments API.
    STEPS: Plan every step up front and get the plan reviewed and approved before executing anything.
    Then execute the approved plan step by step.
    """
    let top = shortlist(for: planning, in: patterns).map(\.slug)
    checkEqual(top.count, 5)
    check(top.contains("plan-then-execute-pattern"), "planning prompt shortlist: \(top)")
    let review = "Critique your own draft answer, find the flaws, then revise it before replying. Iterate until the quality is good."
    let reviewTop = shortlist(for: review, in: patterns).map(\.slug)
    check(reviewTop.contains("reflection") || reviewTop.contains("self-critique-evaluator-loop"), "review prompt shortlist: \(reviewTop)")
    // Search ranks title matches first.
    checkEqual(searchPatterns("reflection", in: patterns).first?.slug, "reflection")
    checkEqual(searchPatterns("", in: patterns).count, 0)
}

func testPatternChoice() throws {
    checkEqual(parseChoice("B", count: 5), 1)
    checkEqual(parseChoice("C. Plan-Then-Execute", count: 5), 2)
    checkEqual(parseChoice("b)", count: 5), 1)
    checkEqual(parseChoice("The answer is D.", count: 5), 3)
    checkEqual(parseChoice("A good fit is E", count: 5), 4)
    checkEqual(parseChoice("E", count: 3), nil)
    checkEqual(parseChoice("none of them", count: 5), nil)

    let options = Array(try bundled().prefix(3))
    let prompt = patternChoicePrompt(task: "ROLE: x", options: options)
    check(prompt.contains("A. \(options[0].title)") && prompt.contains("C. \(options[2].title)"), "options are lettered")
    check(prompt.contains("ROLE: x"), "the task is included")

    let system = patternSystemPrompt(options[0])
    for part in [options[0].title, options[0].summary, "WORKFLOW PATTERN:", "[CONFIRM:"] where !system.contains(part) {
        check(false, "the pattern instructions lack \(part)")
    }
    // The exact headings, in order, with the pattern line after OBJECTIVE.
    let headings = system.components(separatedBy: "\n").compactMap { line -> String? in
        let name = line.components(separatedBy: ":").first ?? ""
        return (Style.agentPrompt.sections + ["WORKFLOW PATTERN"]).contains(name) ? name : nil
    }
    checkEqual(headings, ["ROLE", "OBJECTIVE", "WORKFLOW PATTERN", "CONTEXT", "STEPS", "CONSTRAINTS", "DONE WHEN"])
    // Code from the pattern's write-up isn't shown to the model, so it can't be copied.
    let withCode = try bundled().first { $0.solution.contains("```") }
    if let withCode { check(!patternSystemPrompt(withCode).contains("```"), "code blocks should be removed") }
    // A style without sections keeps its format.
    check(patternSystemPrompt(options[0], sections: []).contains("Keep the prompt's format"), "commit messages keep their format")
}
