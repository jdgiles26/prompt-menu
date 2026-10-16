import Foundation

private let notes = "fix the login bug in AuthService.swift, users get error 500 after 3 tries. keep `rememberMe` working"
private let goodPrompt = """
ROLE: Backend engineer.
OBJECTIVE: Fix the login bug in AuthService.swift where users get error 500 after 3 tries.
CONTEXT: The `rememberMe` option must keep working.
STEPS:
1. Reproduce the error 500.
2. Fix it.
3. Run the tests.
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
    checkEqual(result.score, 100 - 15 - 3 * 5 - 2 * 4 - 10)
    checkEqual(result.problems.count, 4)
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
