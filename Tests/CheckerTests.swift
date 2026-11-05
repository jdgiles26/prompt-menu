import Foundation

private let notes = "fix the login bug in AuthService.swift, users get error 500 after 3 tries. keep `rememberMe` working"
private let goodPrompt = """
ROLE: Backend engineer.
OBJECTIVE: Fix the login bug in AuthService.swift where users get error 500 after 3 tries.
CONTEXT: The `rememberMe` option must keep working.
STEPS:
1. Reproduce the error 500.
2. Fix it.
3. Run the tests. If they fail, fix the cause and run them again, then stop and report if they still fail.
CONSTRAINTS: Don't change rememberMe.
DONE WHEN: The third login attempt returns 200 and the tests pass.
"""

func testCheckerScoresAGoodPrompt() throws {
    let result = checkPrompt(goodPrompt, source: notes, style: .agentPrompt)
    checkEqual(result.missingSections, [])
    checkEqual(result.lostFacts, [])
    checkEqual(result.confirmCount, 0)
    check(result.doneWhenCheckable, "DONE WHEN has a number and 'pass'")
    checkEqual(result.score, 100)
    checkEqual(result.problems, [])
}

func testCheckerFindsProblems() throws {
    // A missing section, a lost number and file, two open questions, a vague DONE WHEN.
    let weak = """
    **ROLE:** Backend engineer.
    OBJECTIVE: Fix the login bug.
    CONTEXT: [CONFIRM: which service?] `rememberMe` stays. [CONFIRM: how many tries?]
    STEPS: 1. Fix it.
    DONE WHEN: It is better.
    """
    let result = checkPrompt(weak, source: notes, style: .agentPrompt)
    checkEqual(result.missingSections, ["CONSTRAINTS"])
    checkEqual(Set(result.lostFacts), ["AuthService.swift", "500", "3"])
    checkEqual(result.confirmCount, 2)
    check(!result.doneWhenCheckable, "'It is better' can't be checked")
    checkEqual(result.workflowGaps.count, 3)
    checkEqual(result.score, 100 - 15 - 3 * 5 - 2 * 4 - 10 - 3 * 5)
    checkEqual(result.problems.count, 5)
    // Headings written as **ROLE:** or ## Steps still count.
    checkEqual(checkPrompt("## Role: x\n**OBJECTIVE**: y", source: "", style: .agentPrompt).missingSections,
               ["CONTEXT", "STEPS", "CONSTRAINTS", "DONE WHEN"])
    // The score never goes below zero.
    checkEqual(checkPrompt("", source: notes, style: .agentPrompt).score, 0)
}

func testCheckerCommitMessage() throws {
    let source = "fix login after 3 tries in AuthService.swift, it returned 500"
    checkEqual(checkPrompt("Fix login after 3 failed tries\n\nAuthService.swift returned 500.", source: source, style: .commitMessage).score, 100)
    let long = checkPrompt(String(repeating: "x", count: 80), source: "", style: .commitMessage)
    checkEqual(long.problems, ["The subject line is 80 characters; keep it to 72."])
}

// A model stuck in a loop repeats every heading. Finding the next heading used indices from a copy
// of the text, which trapped on this ("Range requires lowerBound <= upperBound").
func testCheckerRepeatedHeadings() throws {
    let looped = "ROLE: a\nDONE WHEN: the test passes.\nROLE: a\nDONE WHEN: the test passes."
    let result = checkPrompt(looped, source: "", style: .agentPrompt)
    check(result.doneWhenCheckable, "DONE WHEN is read up to the next heading")
}

// An explanation is scored on its sections only: it needn't repeat every name and number.
func testCheckerExplain() throws {
    let source = "func login(user: String) { retries = 3 }"
    let good = Style.explain.sections.map { "\($0): something" }.joined(separator: "\n")
    let check = checkPrompt(good, source: source, style: .explain)
    checkEqual(check.lostFacts, [])
    checkEqual(check.missingSections, [])
    checkEqual(check.score, 100)
    checkEqual(checkPrompt("TL;DR: logs in", source: source, style: .explain).missingSections, Array(Style.explain.sections.dropFirst()))
}

// A numbered list isn't a workflow: an agent also needs a check, a way to recover, and a place to stop.
func testCheckerWorkflowGaps() throws {
    let checklist = """
    ROLE: Dev.
    OBJECTIVE: Fix it.
    CONTEXT: None.
    STEPS:
    1. Open the file.
    2. Edit the file.
    CONSTRAINTS: None.
    DONE WHEN: The test passes.
    """
    let result = checkPrompt(checklist, source: "", style: .agentPrompt)
    checkEqual(result.workflowGaps.count, 3)
    checkEqual(result.score, 100 - 3 * 5)
    check(result.problems.contains { $0.contains("workflow") }, "the dialog says what's missing")
    // Other styles aren't agent workflows.
    checkEqual(checkPrompt(checklist, source: "", style: .codeReview).workflowGaps, [])
    // Bug: a pattern's name above the draft's unchanged list scored 85. Naming a workflow isn't applying one.
    let cosmetic = checklist.replacingOccurrences(of: "CONTEXT:", with: "WORKFLOW PATTERN: Reflection, because it fits.\nCONTEXT:")
    let named = checkPrompt(cosmetic, source: "", style: .agentPrompt)
    check(named.workflowGaps.contains { $0.contains("pattern") }, "a pattern with no gates is flagged")
    checkEqual(named.score, 100 - 3 * 5 - 15)
}
