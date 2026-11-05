import Foundation

private let note = "the login page throws 500 when the session cookie expired. look at src/auth/session.ts. tests in tests/auth. dont touch billing"

// What Qwen 2.5 3B returned for this note (baseline, 2026-11-05): sections dropped and no way to
// recover from a failure.
private let thinDraft = """
ROLE: AI coding agent.
OBJECTIVE: Fix the login page error in `src/auth/session.ts`.
STEPS:
1. Understand the current state of `src/auth/session.ts`.
2. Update it to handle expired cookies.
DONE WHEN: The login page no longer throws a 500 error.
"""

private func catalog() throws -> [AgenticPattern] { try loadPatterns(from: "Resources/patterns.json") }
private func pattern(_ slug: String) throws -> AgenticPattern {
    guard let found = try catalog().first(where: { $0.slug == slug }) else { throw TestFailure(description: "no \(slug)") }
    return found
}
// In STEPS only: a pattern's summary may use the word too.
private func gateCount(_ text: String) -> Int { sectionBody("STEPS", of: text).components(separatedBy: "Gate:").count - 1 }

// The workflow comes from code, so it's there for every pattern, whatever the model does.
func testEveryPatternHasAWorkflow() throws {
    for p in try catalog() {
        let blueprint = workflowBlueprint(for: p)
        check(blueprint.phases.count >= 3, "\(p.slug) has \(blueprint.phases.count) phases")
        let result = applyWorkflow(p, reply: "", prompt: thinDraft, source: note)
        checkEqual(gateCount(result.text), blueprint.phases.count)
        let scored = checkPrompt(result.text, source: note, style: .agentPrompt)
        checkEqual(scored.missingSections, [])
        checkEqual(scored.lostFacts, [])
        checkEqual(scored.workflowGaps, [])
        // The system prompt's headings are matched by the first word on a line; a phase must not read as one.
        for phase in blueprint.phases where Style.agentPrompt.sections.contains(phase.name) {
            check(false, "\(p.slug): phase \(phase.name) has a section's name")
        }
    }
}

func testWorkflowUsesTheModelsDetails() throws {
    let p = try pattern("plan-then-execute-pattern")
    let reply = """
    ROLE: Dev.
    OBJECTIVE: Something the model reworded.
    STEPS:
    1. PLAN: List every edit to `src/auth/session.ts` before changing anything.
    2. **EXECUTE**: Apply only the listed edits.
       Gate: invented by the model.
    3. VERIFY — Run the tests in tests/auth.
    """
    let result = applyWorkflow(p, reply: reply, prompt: thinDraft, source: note)
    checkEqual(result.filled, 3)
    checkEqual(result.phases, 3)
    let phases = workflowBlueprint(for: p).phases
    check(result.text.contains("1. PLAN: \(phases[0].action) List every edit to `src/auth/session.ts`"), result.text)
    check(result.text.contains("2. EXECUTE: \(phases[1].action) Apply only the listed edits."), result.text)
    check(result.text.contains("3. VERIFY: \(phases[2].action) Run the tests in tests/auth."), result.text)
    // The gates and the sections the model doesn't own aren't taken from its reply.
    check(!result.text.contains("invented by the model"), "the gates are the blueprint's")
    check(!result.text.contains("reworded"), "OBJECTIVE stays the draft's, so no fact is lost")
    check(result.text.contains("OBJECTIVE: Fix the login page error"), result.text)
    check(result.text.contains("WORKFLOW PATTERN: \(p.title):"), "the pattern is named after OBJECTIVE")
    check(result.text.contains(workflowBlueprint(for: p).phases[0].gate), "the blueprint's gate is used")
    check(!result.text.contains("Task checklist"), "every phase was filled, so the old list isn't needed")
    checkEqual(checkPrompt(result.text, source: note, style: .agentPrompt).workflowGaps, [])
}

// What Qwen 2.5 3B actually does: copies the phase's job, then adds the useful part. It also copies
// sentences from the catalog's text about the pattern, which describe building a system, not this task.
func testWorkflowKeepsDetailsAfterAnEcho() throws {
    let p = try pattern("spec-as-test-feedback-loop")
    let phases = workflowBlueprint(for: p).phases
    let reply = """
    STEPS:
    1. SPEC: \(phases[0].action) Add a test for expired cookies in `tests/auth`.
    2. RED: \(phases[1].action) Regenerate the test suite from the latest spec snapshot on each spec commit.
    3. IMPLEMENT: Regenerate the test suite from the latest spec snapshot on each spec commit. Handle the expired cookie in `src/auth/session.ts`.
    4. GREEN: \(phases[3].action)
    """
    let result = applyWorkflow(p, reply: reply, prompt: thinDraft, source: note)
    checkEqual(result.filled, 2)  // SPEC and IMPLEMENT added something; RED and GREEN didn't.
    check(result.text.contains("1. SPEC: \(phases[0].action) Add a test for expired cookies in `tests/auth`."), result.text)
    check(result.text.contains("2. RED: \(phases[1].action)\n"), result.text)
    check(result.text.contains("3. IMPLEMENT: \(phases[2].action) Handle the expired cookie in `src/auth/session.ts`."), result.text)
    check(!result.text.contains("spec snapshot"), "the catalog's text isn't the task")
}

// Also from Qwen 2.5 3B: it repeats the instructions' label, and restates a phase's job with the
// task's details in it. A restatement replaces the general wording rather than saying it twice.
func testWorkflowRestatedPhases() throws {
    let p = try pattern("swarm-migration-pattern")
    let phases = workflowBlueprint(for: p).phases
    let reply = """
    1. INVENTORY: The job: \(phases[0].action)
    2. PILOT: Migrate one representative call site, and work out the exact recipe from it, including how to handle double charging.
    3. BATCHES: The job: Apply the recipe.
    4. RECONCILE: Check the payments_v3 flag is in place.
    """
    let result = applyWorkflow(p, reply: reply, prompt: thinDraft, source: note)
    checkEqual(result.filled, 2)
    check(result.text.contains("1. INVENTORY: \(phases[0].action)\n"), "the repeated label adds nothing: \(result.text)")
    check(result.text.contains("2. PILOT: Migrate one representative call site, and work out the exact recipe from it, including how to handle double charging.\n"), result.text)
    check(!result.text.contains(phases[1].action), "the restatement replaces the general wording")
    check(result.text.contains("3. BATCHES: \(phases[2].action)\n"), result.text)
    check(result.text.contains("4. RECONCILE: \(phases[3].action) Check the payments_v3 flag is in place."), result.text)
    check(!result.text.contains("The job"), result.text)
}

// Bug: the model copied the draft's list unchanged, and that became the "workflow".
func testWorkflowSurvivesAUselessModel() throws {
    let p = try pattern("plan-then-execute-pattern")
    let phases = workflowBlueprint(for: p).phases
    for reply in ["", thinDraft, "I can't help with that.",
                  "1. PLAN: \(phases[0].action)\n2. EXECUTE: <what to do>"] {
        let result = applyWorkflow(p, reply: reply, prompt: thinDraft, source: note)
        checkEqual(result.filled, 0)
        checkEqual(gateCount(result.text), phases.count)
        check(result.text.contains("1. PLAN: \(phases[0].action)"), "the phase's own action stands in")
        // The draft's task knowledge isn't lost when the model adds nothing.
        check(result.text.contains("Task checklist"), result.text)
        check(result.text.contains("Update it to handle expired cookies."), result.text)
        checkEqual(checkPrompt(result.text, source: note, style: .agentPrompt).score, 100)
    }
}

// A second pattern replaces the first one's phases and doesn't pile up the shared rules.
func testWorkflowAppliedTwice() throws {
    let first = applyWorkflow(try pattern("plan-then-execute-pattern"), reply: "", prompt: thinDraft, source: note)
    let second = applyWorkflow(try pattern("spec-as-test-feedback-loop"), reply: "", prompt: first.text, source: note)
    checkEqual(second.text.components(separatedBy: "WORKFLOW PATTERN:").count - 1, 1)
    check(second.text.contains("Spec-As-Test") || second.text.contains("Spec as Test") || second.text.lowercased().contains("spec-as-test"), second.text)
    checkEqual(second.text.components(separatedBy: agentLoopRules[1]).count - 1, 1)
    checkEqual(second.text.components(separatedBy: agentConstraints[0]).count - 1, 1)
    checkEqual(gateCount(second.text), workflowBlueprint(for: try pattern("spec-as-test-feedback-loop")).phases.count)
    check(!second.text.contains("Task checklist") || !second.text.contains("Gate:\n- "), "gates don't leak into the checklist")
    check(!sectionBody("STEPS", of: second.text).lowercased().contains("freeze"), "the first pattern's phases are gone")
}

func testDraftHardening() throws {
    let hardened = hardenAgentPrompt(thinDraft, source: note)
    let scored = checkPrompt(hardened, source: note, style: .agentPrompt)
    checkEqual(scored.missingSections, [])
    checkEqual(scored.lostFacts, [])  // tests/auth was dropped by the model and is put back.
    checkEqual(scored.workflowGaps, [])
    // The model's own steps come first, in its own words.
    check(hardened.contains("1. Understand the current state of `src/auth/session.ts`."), hardened)
    check(hardened.contains("tests/auth"), hardened)
    for rule in agentLoopRules { check(hardened.contains(rule), "missing rule: \(rule)") }
    // Sections in order, each once.
    let order = Style.agentPrompt.sections.compactMap { hardened.range(of: "\($0):")?.lowerBound }
    checkEqual(order, order.sorted())
    checkEqual(order.count, 6)
    // Doing it twice changes nothing, so Try Again and Review can't pile rules up.
    checkEqual(hardenAgentPrompt(hardened, source: note), hardened)
    // A model that stuck in a loop: the first copy of each section wins.
    let looped = hardenAgentPrompt(thinDraft + "\n" + thinDraft, source: note)
    checkEqual(looped.components(separatedBy: "ROLE:").count - 1, 1)
    // The note is repeated, so a limit the model dropped ("dont touch billing") still reaches the agent.
    check(hardened.contains(note), hardened)
    // And it outranks a limit the model made up, like "Do not modify any existing code" on a migration.
    check(hardened.contains("Original request (it wins over anything below that conflicts): \(note)"), hardened)
    // A long note isn't repeated, but the facts dropped from it are still kept.
    let long = String(repeating: "word ", count: 200) + "see `tests/auth/login.test.ts`."
    let keptFacts = hardenAgentPrompt(thinDraft, source: long)
    check(keptFacts.contains("Also from the request: tests/auth/login.test.ts."), keptFacts)
    check(!keptFacts.contains("Original request"), "too long to repeat")
    checkEqual(hardenAgentPrompt(keptFacts, source: long), keptFacts)
    // The fallback steps aren't the task, so the model isn't given them to copy back.
    let noSteps = hardenAgentPrompt("OBJECTIVE: Do it.", source: "")
    check(noSteps.contains("Do what the objective asks."), noSteps)
    check(!removingStandardLines(noSteps).contains("Do what the objective asks."), "fallback steps are removed")
    // Something with no sections at all isn't ours to reshape.
    checkEqual(hardenAgentPrompt("Sorry, I can't do that.", source: note), "Sorry, I can't do that.")
}

func testFinishedPrompt() throws {
    let p = try pattern("plan-then-execute-pattern")
    // A first draft with the built-in instructions.
    check(finishedPrompt(thinDraft, style: .agentPrompt, source: note, builtInInstructions: true).text.contains(agentLoopRules[0]), "hardened")
    // A user's own instructions, and the other styles, keep their format.
    checkEqual(finishedPrompt(thinDraft, style: .agentPrompt, source: note, builtInInstructions: false).text, thinDraft)
    checkEqual(finishedPrompt("TITLE: x", style: .bugReport, source: note, builtInInstructions: true).text, "TITLE: x")
    // A pattern on an agent prompt gets the workflow; on a bug report it keeps its format.
    let applied = finishedPrompt("", style: .agentPrompt, source: note, builtInInstructions: true, pattern: p, before: thinDraft)
    checkEqual(gateCount(applied.text), 3)
    checkEqual(applied.notice, "The model added details to 0 of 3 phases; the others use the pattern's own wording.")
    checkEqual(finishedPrompt("TITLE: x", style: .bugReport, source: note, builtInInstructions: true, pattern: p, before: "y").text, "TITLE: x")
    // The instructions the model gets name each phase, so it fills them in rather than copy the old list.
    // (They moved from patternSystemPrompt to phaseDetailsSystemPrompt, which asks for the phases alone.)
    let system = phaseDetailsSystemPrompt(p)
    for phase in workflowBlueprint(for: p).phases { check(system.contains("\(phase.name):"), "\(phase.name) isn't asked for") }
    check(!patternSystemPrompt(p, sections: Style.bugReport.sections).contains("Gate"), "other styles have no phases")
}
