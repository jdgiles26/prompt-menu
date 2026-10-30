import Foundation

// FEATURE_FUTURE §3: the review pipeline. Jury, harden and the state machine, with a fake `ask`
// standing in for the models.

private func model(_ name: String, gb: Double = 2) -> LocalModel {
    LocalModel(format: .mlx, id: "test/\(name)", bytes: Int64(gb * 1_000_000_000))
}

private let goodPrompt = """
ROLE: iOS developer
OBJECTIVE: Fix the crash in `LoginView.swift` on iOS 17.
CONTEXT: It crashes when the password is empty.
CONSTRAINTS: Don't touch the networking code.
STEPS:
1. Reproduce it.
2. Fix it.
DONE WHEN: the login test passes.
"""
private let source = "fix the crash in `LoginView.swift` on iOS 17 when the password is empty"

func testJuryPromptAndVotes() throws {
    let prompt = juryPrompt(task: "add dark mode", candidates: ["first one", "second one"])
    check(prompt.contains("A.\nfirst one"), "candidates are lettered in the order given: \(prompt)")
    check(prompt.contains("B.\nsecond one"), "second candidate is B")
    check(prompt.contains("add dark mode"), "the task is shown")
    check(!jurySystemPrompt.isEmpty && jurySystemPrompt.contains("0 to 100"), "asks for a confidence")

    // "B 80" and the forms small models write.
    check(parseVote("B 80", count: 3) == Vote(choice: 1, confidence: 80), "B 80")
    check(parseVote("C. 65", count: 3) == Vote(choice: 2, confidence: 65), "C. 65")
    check(parseVote("A (confidence: 90)", count: 2) == Vote(choice: 0, confidence: 90), "A (confidence: 90)")
    check(parseVote("B", count: 2) == Vote(choice: 1, confidence: 50), "no number counts as 50")
    check(parseVote("B 250", count: 2) == Vote(choice: 1, confidence: 100), "clamped to 100")
    check(parseVote("D 90", count: 2) == nil, "a letter past the candidates is no vote")
    check(parseVote("I can't decide", count: 2) == nil, "no letter is no vote")
}

func testJuryShuffle() throws {
    let order = shuffledOrder(count: 5, seed: 42)
    checkEqual(order.sorted(), [0, 1, 2, 3, 4])
    checkEqual(shuffledOrder(count: 5, seed: 42), order) // Same seed, same order: reproducible.
    check((0..<20).contains { shuffledOrder(count: 5, seed: UInt64($0)) != order }, "other seeds give other orders")
    checkEqual(shuffledOrder(count: 0, seed: 1), [])
}

func testJuryBiasControls() throws {
    // Position-bias check: a vote counts only if both orders pick the same candidate.
    check(agreedVote(Vote(choice: 2, confidence: 80), Vote(choice: 2, confidence: 60)) == Vote(choice: 2, confidence: 60),
          "agreeing votes count, at the lower confidence")
    check(agreedVote(Vote(choice: 2, confidence: 80), Vote(choice: 1, confidence: 90)) == nil, "disagreeing votes abstain")
    check(agreedVote(nil, Vote(choice: 1, confidence: 90)) == nil, "an unreadable reply abstains")

    // A judge below about 7B (under 3.5 GB on disk) counts at half weight.
    checkEqual(judgeWeight(model("small", gb: 2)), 0.5)
    checkEqual(judgeWeight(model("big", gb: 4.5)), 1)
}

func testJuryWinner() throws {
    let candidates = [ReviewCandidate(text: "a", author: "test/one"), ReviewCandidate(text: "b", author: "test/two"),
                      ReviewCandidate(text: "c", author: nil)]
    // The checker alone (no judges): the higher check score wins.
    checkEqual(juryWinner(candidates: candidates, votes: [], checkScores: [70, 90, 80]).winner, 1)
    // Ties in score share points; ties in points go to the higher check score, then the earlier one.
    checkEqual(juryWinner(candidates: candidates, votes: [], checkScores: [80, 80, 60]).winner, 0)

    // Two confident full-weight judges outvote the checker's ranking.
    let votes = [JuryVote(judge: "test/three", choice: 2, confidence: 100, weight: 1),
                 JuryVote(judge: "test/four", choice: 2, confidence: 100, weight: 1)]
    let result = juryWinner(candidates: candidates, votes: votes, checkScores: [70, 90, 80])
    checkEqual(result.winner, 2)
    checkEqual(result.points, [0, 2, 5]) // Checker: 0, 2, 1. Each judge: 2 × 100%.

    // No self-judging: test/two's vote for its own candidate doesn't count.
    let selfVote = [JuryVote(judge: "test/two", choice: 1, confidence: 100, weight: 1)]
    checkEqual(juryWinner(candidates: candidates, votes: selfVote, checkScores: [90, 70, 80]).points, [2, 0, 1])
    // An abstaining judge adds nothing.
    let abstain = [JuryVote(judge: "test/three", choice: nil, confidence: 0, weight: 1)]
    checkEqual(juryWinner(candidates: candidates, votes: abstain, checkScores: [90, 70, 80]).points, [2, 0, 1])
}

func testHardenReply() throws {
    let system = hardenSystemPrompt(.verifiability, sections: Style.agentPrompt.sections)
    check(system.contains("CRITIQUE:") && system.contains("REVISED PROMPT:"), "names both parts")
    check(system.contains("DONE WHEN:"), "spells out the headings to keep")
    check(system.contains("five"), "limits the critique")
    checkEqual(HardenRole.allCases.map(\.rawValue), ["Security & safety", "Scope", "Verifiability"])

    let reply = """
    CRITIQUE:
    - DONE WHEN is vague.
    * No test is named.
    1. Too long.
    • Four.
    - Five.
    - Six is one too many.

    **REVISED PROMPT:**
    ROLE: dev
    DONE WHEN: the tests pass.
    """
    guard let parsed = parseHardenReply(reply) else { throw TestFailure(description: "no reply parsed") }
    checkEqual(parsed.critique, ["DONE WHEN is vague.", "No test is named.", "Too long.", "Four.", "Five."])
    checkEqual(parsed.prompt, "ROLE: dev\nDONE WHEN: the tests pass.")
    check(parseHardenReply("CRITIQUE:\n- fine\n") == nil, "no revised prompt, nothing to keep")
    // Small models copy lines from the instructions into the prompt (seen with Qwen 2.5 3B). They're removed,
    // unless the prompt already had them.
    let echoed = "- Keep these section headings, in this order: ROLE: DONE WHEN:\nROLE: dev\n- Keep every fact, name, number and step.\nDONE WHEN: done"
    checkEqual(removeEchoedLines(echoed, instructions: system, before: "ROLE: dev\n- Keep every fact, name, number and step."),
               "ROLE: dev\n- Keep every fact, name, number and step.\nDONE WHEN: done")
    check(parseHardenReply("CRITIQUE:\n- fine\nREVISED PROMPT:\n  \n") == nil, "an empty revised prompt, nothing to keep")
}

func testHardenPreamble() throws {
    let sections = Style.agentPrompt.sections
    // A critique bullet left above the first heading (seen with Qwen 2.5 3B) is removed...
    checkEqual(removePreamble("- Ensure DONE WHEN is testable.\n\nROLE: dev\nDONE WHEN: x", sections: sections, before: "ROLE: old"),
               "ROLE: dev\nDONE WHEN: x")
    checkEqual(removePreamble("- note\n**Role:** dev", sections: sections, before: "**ROLE:** old"), "**Role:** dev")
    // ...but only when the prompt before the edit started at a heading, and only if the edit has one.
    checkEqual(removePreamble("Intro\nROLE: dev", sections: sections, before: "Intro\nROLE: old"), "Intro\nROLE: dev")
    checkEqual(removePreamble("no headings", sections: sections, before: "ROLE: old"), "no headings")
}

func testHardenVerdict() throws {
    let style = Style.agentPrompt
    // An edit that keeps the score and every fact is kept.
    let better = goodPrompt.replacingOccurrences(of: "2. Fix it.", with: "2. Fix it with a guard.")
    check(hardenVerdict(before: goodPrompt, after: better, source: source, style: style) == nil, "kept")
    // Dropping a fact from the highlighted text rejects it, even when nothing else changed.
    let lost = goodPrompt.replacingOccurrences(of: " on iOS 17", with: "")
    let lostReason = hardenVerdict(before: goodPrompt, after: lost, source: source, style: style)
    check(lostReason?.contains("17") == true, "names the dropped fact: \(lostReason ?? "nil")")
    // Losing a section drops the score.
    let noSteps = goodPrompt.replacingOccurrences(of: "STEPS:", with: "Then:")
    let dropReason = hardenVerdict(before: goodPrompt, after: noSteps, source: source, style: style)
    check(dropReason?.contains("Check score dropped") == true, "names the score drop: \(dropReason ?? "nil")")
    checkEqual(hardenVerdict(before: goodPrompt, after: goodPrompt + "\n", source: source, style: style), "Nothing changed.")
    // A model stuck in a loop repeats the whole prompt (seen with Qwen 2.5 3B): same facts, same score, still rejected.
    let looped = goodPrompt + "\n" + goodPrompt
    let loopReason = hardenVerdict(before: goodPrompt, after: looped, source: source, style: style)
    check(loopReason?.contains("Repeats") == true, "names the repeat: \(loopReason ?? "nil")")
}

func testReviewStateMachine() throws {
    var machine = ReviewMachine(roles: 2)
    checkEqual(machine.state, .candidates)
    check((try? machine.move(to: .hardening(0))) == nil, "can't harden before judging")
    try machine.move(to: .judging)
    check((try? machine.move(to: .hardening(1))) == nil, "roles run in order")
    try machine.move(to: .hardening(0))
    try machine.move(to: .hardening(1))
    check((try? machine.move(to: .hardening(2))) == nil, "only two roles")
    try machine.move(to: .done)
    check((try? machine.move(to: .stopped)) == nil, "done is final")

    var stopping = ReviewMachine(roles: 3)
    try stopping.move(to: .judging)
    try stopping.move(to: .stopped)
    check((try? stopping.move(to: .hardening(0))) == nil, "stopped is final")
}

func testLineDiff() throws {
    checkEqual(lineDiff(before: "a\nb\nc", after: "a\nB\nc\nd"), ["- b", "+ B", "+ d"])
    checkEqual(lineDiff(before: "same", after: "same"), [])
}

func testReviewPipeline() throws {
    let one = model("one"), two = model("two", gb: 4.5)
    let candidates = [ReviewCandidate(text: goodPrompt.replacingOccurrences(of: "STEPS:", with: "Then:"), author: one.id),
                      ReviewCandidate(text: goodPrompt, author: two.id)]
    var calls: [(system: String, model: String)] = []
    let ask: ReviewPipeline.Ask = { input, system, model, _ in
        calls.append((system, model.id))
        if system == jurySystemPrompt {
            // Vote for the candidate holding the full prompt, wherever the shuffle put it.
            let letters = ["A", "B"]
            let blocks = input.components(separatedBy: "\n\nA.\n").last!.components(separatedBy: "\n\nB.\n")
            return letters[blocks[0].contains("STEPS:") ? 0 : 1] + " 90"
        }
        if system.contains("Security") {
            return "CRITIQUE:\n- Fine.\nREVISED PROMPT:\n- Keep every fact, name, number and step.\n" + input + "\nAsk before deleting anything."
        }
        if system.contains("Scope") { return "CRITIQUE:\n- Cut.\nREVISED PROMPT:\nROLE: dev" } // Loses sections: rejected.
        throw RewriteError.emptyOutput // Verifiability fails: logged, not fatal.
    }
    let pipeline = ReviewPipeline(candidates: candidates, source: source, style: .agentPrompt, models: [one, two], seed: 7, ask: ask)
    var events: [ReviewEvent] = []
    let final = pipeline.run { events.append($0) }

    // Each judge votes twice; one's vote for two's candidate counts, two's vote for itself doesn't.
    checkEqual(calls.filter { $0.system == jurySystemPrompt }.count, 4)
    guard case .winner(let index, _, _)? = events.first(where: { if case .winner = $0 { return true }; return false }) else {
        throw TestFailure(description: "no winner in \(events)")
    }
    checkEqual(index, 1)
    // Roles go round-robin over the models.
    checkEqual(calls.filter { $0.system != jurySystemPrompt }.map(\.model), [one.id, two.id, one.id])
    let hardens = events.compactMap { event -> (HardenRole, Bool)? in
        if case .harden(let step) = event { return (step.role, step.kept) }
        return nil
    }
    check(hardens.map(\.0) == HardenRole.allCases && hardens.map(\.1) == [true, false, false], "harden steps: \(hardens)")
    check(final.hasSuffix("Ask before deleting anything."), "the kept edit is the result: \(final)")
    check(!final.contains("Keep every fact"), "an instruction echoed into the edit is removed: \(final)")
    checkEqual(pipeline.state, .done)
    check(!reviewLogText(events, labels: ["1 · First draft", "2 · two"]).isEmpty, "the log renders")
}

func testReviewPipelineSingleModelAndStop() throws {
    let one = model("one")
    let candidates = [ReviewCandidate(text: "ROLE: x", author: nil), ReviewCandidate(text: goodPrompt, author: nil)]
    var juryCalls = 0
    let pipeline = ReviewPipeline(candidates: candidates, source: source, style: .agentPrompt, models: [one], seed: 1) { _, system, _, _ in
        if system == jurySystemPrompt { juryCalls += 1 }
        return "no marker here"
    }
    var events: [ReviewEvent] = []
    let final = pipeline.run { events.append($0) }
    checkEqual(juryCalls, 0) // One model: no jury, the checker picks.
    check(events.contains { if case .note(let text) = $0 { return text.contains("check picks") }; return false }, "says why: \(events)")
    checkEqual(final, goodPrompt)

    // Stop before anything runs: everything so far is kept, and nothing more is asked.
    var asked = 0
    let stopped = ReviewPipeline(candidates: candidates, source: source, style: .agentPrompt, models: [one], seed: 1) { _, _, _, _ in
        asked += 1
        return ""
    }
    stopped.isStopped = { true }
    _ = stopped.run { _ in }
    checkEqual(asked, 0)
    checkEqual(stopped.state, .stopped)
}

func testReviewEstimate() throws {
    // Two 3B models: 4 jury calls and 3 harden calls, about 2 to 3 minutes.
    let range = reviewEstimate(models: [model("a"), model("b")], candidates: 3, checkTwice: true)
    checkEqual(range, 119...175)
    checkEqual(reviewCallCount(models: 2, candidates: 3, checkTwice: false), 5)
    checkEqual(reviewCallCount(models: 1, candidates: 3, checkTwice: true), 3) // No jury with one model.
    checkEqual(reviewCallCount(models: 2, candidates: 1, checkTwice: true), 3) // Nor with one candidate.
}

func testReviewPositionBias() throws {
    // A judge that always answers "A" picks a different candidate in each order: it abstains, and the log says why.
    let candidates = [ReviewCandidate(text: "ROLE: x", author: nil), ReviewCandidate(text: goodPrompt, author: nil)]
    let pipeline = ReviewPipeline(candidates: candidates, source: source, style: .agentPrompt, models: [model("one"), model("two")],
                                  seed: 5) { _, system, _, _ in system == jurySystemPrompt ? "A 90" : "" }
    var events: [ReviewEvent] = []
    _ = pipeline.run { events.append($0) }
    let notes = events.compactMap { event -> String? in if case .note(let text) = event { return text }; return nil }
    checkEqual(notes.filter { $0.contains("position") }.count, 2)
}
