import AppKit

// Phase 6: what Qwen 2.5 3B actually returned when every built-in prompt was run on 2026-11-05,
// and the deterministic repairs for it. Each fixture is a real reply, trimmed.

private let loginNote = "the login page at /signin throws 500 when email has a plus sign like a+b@x.com. auth is in src/auth/session.ts, uses bcrypt. need fix + regression test, dont touch the db schema. ticket AUTH-412"

// A limit the user stated must reach CONSTRAINTS, even when the model left it out (Spec-As-Test run).
func testStatedLimitsReachConstraints() throws {
    let draft = """
    ROLE: AI coding agent.
    OBJECTIVE: Fix the login error for emails with plus signs.
    STEPS:
    1. Inspect src/auth/session.ts.
    CONSTRAINTS:
    - Keep the change small.
    DONE WHEN: The regression test passes.
    """
    let hardened = hardenAgentPrompt(draft, source: loginNote)
    let constraints = sectionBody("CONSTRAINTS", of: hardened)
    check(constraints.contains("- Don't touch the db schema (from the request)."), constraints)
    // Already there in other words: not added twice.
    let worded = draft.replacingOccurrences(of: "- Keep the change small.", with: "- Do not modify the database schema.")
    let once = sectionBody("CONSTRAINTS", of: hardenAgentPrompt(worded, source: loginNote))
    check(!once.contains("(from the request)"), once)
    // Idempotent, so Try Again can't pile them up.
    checkEqual(hardenAgentPrompt(hardened, source: loginNote), hardened)
    // Each of these is a limit; "no need to" and "never mind" aren't.
    checkEqual(statedLimits(in: "fix it. Do not change the API, never log tokens; must not break v1. no need to rush, never mind the docs"),
               ["Do not change the API", "Never log tokens", "Must not break v1"])
}

// A limit the model made up, which blocks the work ("Do not modify any existing code" on a migration),
// goes. A limit in the user's words, and Prompt Menu's own rules, stay.
func testInventedLimitsAreDropped() throws {
    let note = "migrate the user table from mysql to postgres, dont touch billing"
    let draft = """
    OBJECTIVE: Migrate the user table to postgres.
    STEPS:
    1. Export the user table.
    CONSTRAINTS:
    - Do not modify any existing code.
    - Do not touch the billing module.
    - Never delete the user table before the copy is checked.
    DONE WHEN: The user table is in postgres.
    """
    let constraints = sectionBody("CONSTRAINTS", of: hardenAgentPrompt(draft, source: note))
    check(!constraints.contains("existing code"), constraints)
    check(constraints.contains("Do not touch the billing module."), constraints)
    check(constraints.contains("Never delete the user table"), constraints)
    for rule in agentConstraints { check(constraints.contains(rule), "lost \(rule)") }
}

// The model often writes a section's first line next to its heading, without the bullet the rest get.
func testConstraintsAndDoneWhenAreBullets() throws {
    let draft = "OBJECTIVE: Fix it.\nSTEPS:\n1. Fix it.\nCONSTRAINTS: Do not touch the db schema.\nDONE WHEN: The login page at /signin no longer throws 500."
    let hardened = hardenAgentPrompt(draft, source: loginNote)
    for name in ["CONSTRAINTS", "DONE WHEN"] {
        for line in sectionBody(name, of: hardened).components(separatedBy: "\n") {
            check(line.hasPrefix("- "), "\(name): \(line)")
        }
    }
}

// Files and folders the text never named get a question instead of passing as facts
// (`test/auth` in an agent prompt, `charge_test.go` in a review request).
func testInventedNamesAreQuestioned() throws {
    let review = "changed retry logic in payments/charge.go to use exponential backoff max 5 tries. PR #881"
    let reply = "CHANGE: Backoff in `payments/charge.go`.\nCONTEXT: files: `payments/charge.go`, `charge_test.go`. Also tests/auth and and/or N/A."
    let marked = finishedPrompt(reply, style: .codeReview, source: review, builtInInstructions: true).text
    check(marked.contains("`charge_test.go` [CONFIRM: is charge_test.go right? It isn't in your text.]"), marked)
    check(marked.contains("tests/auth [CONFIRM: is tests/auth right? It isn't in your text.]"), marked)
    checkEqual(marked.components(separatedBy: "[CONFIRM:").count - 1, 2)  // payments/charge.go, and/or and N/A are fine.
    // Once only, however often it's finished.
    checkEqual(finishedPrompt(marked, style: .codeReview, source: review, builtInInstructions: true).text, marked)
    // An agent prompt too, and a user's own instructions are left alone.
    let agent = finishedPrompt("OBJECTIVE: Fix it.\nSTEPS:\n1. Add a test in test/auth.", style: .agentPrompt, source: loginNote, builtInInstructions: true).text
    check(agent.contains("test/auth [CONFIRM:"), agent)
    checkEqual(finishedPrompt("x in test/auth", style: .agentPrompt, source: loginNote, builtInInstructions: false).text, "x in test/auth")
    // An explanation describes; it isn't checked against the text like this.
    checkEqual(finishedPrompt("See test/auth.", style: .explain, source: "x", builtInInstructions: true).text, "See test/auth.")
}

// A phase's details mustn't contradict its gate: RED's checks must fail (Spec-As-Test run).
func testPhaseDetailsMatchTheirGate() throws {
    guard let p = try loadPatterns(from: "Resources/patterns.json").first(where: { workflowBlueprint(for: $0).phases.contains { $0.name == "RED" } }) else {
        throw TestFailure(description: "no pattern with a RED phase")
    }
    let reply = """
    SPEC: For AUTH-412, write a test that logs in at /signin with a+b@x.com.
    RED: Run the test to verify the login page works correctly with emails containing plus signs. Note the 500 from /signin in the output.
    IMPLEMENT: Handle the plus sign in src/auth/session.ts.
    GREEN: Run the new test and make sure it passes.
    """
    let draft = "OBJECTIVE: Fix it.\nSTEPS:\n1. Fix it.\nDONE WHEN: The test passes."
    let steps = sectionBody("STEPS", of: applyWorkflow(p, reply: reply, prompt: draft, source: loginNote).text)
    let red = steps.components(separatedBy: "\n").first { $0.contains("RED:") } ?? ""
    check(!red.contains("works correctly"), red)
    check(red.contains("Note the 500 from /signin"), red)
    // GREEN may say it passes: that's its gate.
    check(steps.contains("make sure it passes"), steps)
}

// Commit messages as Qwen 2.5 3B wrote them: a "Fix:" label, a "Body:" heading, a bare CONFIRM and an empty "Verified:".
func testCommitMessageCleanup() throws {
    let note = "fixed the thing where the cache didnt expire because ttl was in ms not seconds in config/cache.yml, tests pass now"
    let reply = "Fix: Cache TTL in config/cache.yml was in milliseconds instead of seconds.\n\nBody:\nCONFIRM: why did the tests pass after this change?\n\nVerified:"
    let message = finishedPrompt(reply, style: .commitMessage, source: note, builtInInstructions: true).text
    let lines = message.components(separatedBy: "\n")
    checkEqual(lines.first ?? "", "Fix cache TTL in config/cache.yml was in milliseconds instead of seconds")
    check(!message.contains("Body:"), message)
    check(message.contains("[CONFIRM: why did the tests pass after this change?]"), message)
    checkEqual(lines.last ?? "", "Verified: tests pass now")
    check(!message.contains("\n\n\n"), message)
    // Nothing was run: an empty Verified line goes.
    let untested = finishedPrompt("Add retry to the uploader\n\nVerified:", style: .commitMessage, source: "added retry to uploader", builtInInstructions: true).text
    checkEqual(untested, "Add retry to the uploader")
    // A good message is left exactly as it is, and so is a conventional "fix:" prefix.
    let good = "fix: expire the cache in seconds, not milliseconds\n\nconfig/cache.yml gave the TTL in ms.\n\nVerified: tests pass now"
    checkEqual(finishedPrompt(good, style: .commitMessage, source: note, builtInInstructions: true).text, good)
    // The instructions show the shape, so the model sees what's wanted.
    check(Style.commitMessage.builtInPrompt.contains("Example"), "no example")
}

// The bug report asks for SCOPE, so the check looks for it.
func testBugReportChecksScope() throws {
    check(Style.bugReport.sections.last == "SCOPE", "\(Style.bugReport.sections)")
}

// Lines a model copies from its instructions ("Reply with only the prompt:", seen from LFM2.5 1.2B) are removed,
// unless the user's own text has them.
func testEchoedInstructionsAreRemoved() throws {
    let reply = "TITLE: Crash on export\nReply with only the prompt:\nKeep every fact, name, number and error message\nSUMMARY: It crashes."
    let cleaned = removingEchoedInstructions(reply, instructions: agentSystemPrompt + "\n" + Style.bugReport.builtInPrompt, input: "it crashes on export")
    checkEqual(cleaned, "TITLE: Crash on export\nSUMMARY: It crashes.")
    let quoted = "Keep every fact, name, number and error message"
    checkEqual(removingEchoedInstructions(quoted, instructions: Style.bugReport.builtInPrompt, input: "my notes say: \(quoted)"), quoted)
    // Short lines, such as headings, are never echoes.
    checkEqual(removingEchoedInstructions("TL;DR:", instructions: Style.explain.builtInPrompt, input: "x"), "TL;DR:")
}

// A Metal out-of-memory failure says what it is, not only "exit code 1".
func testOutOfMemoryMessage() throws {
    let failure = RewriteError.failed(status: 1, message: "ggml_metal_graph_compute: command buffer 0 failed with status 5\nerror: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)")
    let text = failure.errorDescription ?? ""
    check(text.hasPrefix("The model ran out of memory."), text)
    check(text.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory"), "keeps the details: \(text)")
    check(!(RewriteError.failed(status: 1, message: "bad flag").errorDescription ?? "").contains("memory"), "only for memory")
}

// Reading what Finder sent happens off the main thread, and a read that hangs (a slow disk,
// PDFKit on a broken file) ends in a message instead of a frozen app.
func testExplainReadingHasATimeLimit() throws {
    let done = DispatchSemaphore(value: 0)
    var results: [Result<String, Error>] = []
    let lock = NSLock()
    readItems(["/a"], timeout: 0.2, read: { _ in Thread.sleep(forTimeInterval: 1); return "late" }) { result in
        lock.lock(); results.append(result); lock.unlock(); done.signal()
    }
    check(done.wait(timeout: .now() + 2) == .success, "never finished")
    Thread.sleep(forTimeInterval: 1.2)  // The late read finishes and must not report again.
    lock.lock(); defer { lock.unlock() }
    checkEqual(results.count, 1)
    if case .failure(let error as RewriteError) = results.first { checkEqual(error, .slowRead("a")) } else { check(false, "\(results)") }

    let quick = DispatchSemaphore(value: 0)
    var text = ""
    readItems(["/a"], timeout: 2, read: { _ in "fine" }) { result in text = (try? result.get()) ?? ""; quick.signal() }
    _ = quick.wait(timeout: .now() + 2)
    checkEqual(text, "fine")
}

// An image's text is read on this Mac (Vision, no network), so a screenshot of an error can be explained.
func testExplainImageText() throws {
    let folder = try makeTempFolder()
    let path = (folder as NSString).appendingPathComponent("shot.png")
    let image = NSImage(size: NSSize(width: 900, height: 200))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 900, height: 200).fill()
    ("Error 4471: disk full" as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        throw TestFailure(description: "couldn't make the image")
    }
    try png.write(to: URL(fileURLWithPath: path))
    let text = try describeItem(path, limit: 4000)
    check(text.contains("Error 4471"), text)
    check(text.contains("disk full"), text)
    check(text.range(of: "\\d+ × \\d+ pixels", options: .regularExpression) != nil, text)
    // Its own limit still holds.
    check(try describeItem(path, limit: 60).count <= 60, "limit")
}

// Second real run (2026-11-05): numbers the notes never gave ("1800"), a "Verified:" line left out
// though the notes say tests pass, "works with" in RED, and two limits in one line, one made up.
func testSecondRunRepairs() throws {
    let note = "fixed the thing where the cache didnt expire because ttl was in ms not seconds in config/cache.yml, tests pass now"
    let reply = "Fix the cache expiration by setting TTL to 1800 seconds\n\nThe TTL was 1800 milliseconds instead of seconds."
    let message = finishedPrompt(reply, style: .commitMessage, source: note, builtInInstructions: true).text
    check(message.contains("1800 [CONFIRM: is 1800 right? It isn't in your text.]"), message)
    checkEqual(message.components(separatedBy: "[CONFIRM:").count - 1, 1)
    check(message.hasSuffix("\n\nVerified: tests pass now"), message)
    // Small numbers are list items and the work loop's "3 attempts"; a number the notes have is fine.
    let agent = finishedPrompt("OBJECTIVE: Fix the 500.\nSTEPS:\n1. Retry 3 times.", style: .agentPrompt, source: "it throws 500", builtInInstructions: true).text
    check(!agent.contains("[CONFIRM: is"), agent)

    guard let p = try loadPatterns(from: "Resources/patterns.json").first(where: { workflowBlueprint(for: $0).phases.contains { $0.name == "RED" } }) else {
        throw TestFailure(description: "no pattern with a RED phase")
    }
    let steps = sectionBody("STEPS", of: applyWorkflow(p, reply: "RED: Run the test suite to ensure the login page works with emails containing plus signs.",
                                                       prompt: "OBJECTIVE: x\nSTEPS:\n1. x", source: "x").text)
    check(!(steps.components(separatedBy: "\n").first { $0.contains("RED:") } ?? "").contains("works with"), steps)

    let draft = "OBJECTIVE: Fix it.\nSTEPS:\n1. Fix it.\nCONSTRAINTS: Do not modify the database schema. Do not touch any other parts of the codebase."
    let constraints = sectionBody("CONSTRAINTS", of: hardenAgentPrompt(draft, source: "fix the login 500, dont touch the db schema"))
    check(constraints.contains("- Do not modify the database schema."), constraints)
    check(!constraints.contains("codebase"), constraints)
}

// Asked in the chat to change one line, Qwen 2.5 3B returns only the changed section. It's merged
// into the result, so the user gets the whole prompt back as a new version instead of copying by hand.
func testChatEditMergesSections() throws {
    let result = "ROLE: Agent.\nOBJECTIVE: Fix the login.\nSTEPS:\n1. Fix it.\nCONSTRAINTS:\n- Keep it small.\nDONE WHEN:\n- Tests pass."
    let answer = "Here's the updated section:\n\nCONSTRAINTS:\n- Keep it small.\n- Don't touch billing."
    let merged = chatEdit(answer, of: result, style: .agentPrompt)
    checkEqual(merged, "ROLE: Agent.\nOBJECTIVE: Fix the login.\nSTEPS:\n1. Fix it.\nCONSTRAINTS:\n- Keep it small.\n- Don't touch billing.\nDONE WHEN:\n- Tests pass.")
    // A whole new result is used as it is; an answer with no sections isn't an edit.
    let whole = "ROLE: Agent.\nOBJECTIVE: Fix the signup.\nSTEPS:\n1. Fix it.\nCONSTRAINTS:\n- Small.\nDONE WHEN:\n- Tests pass."
    checkEqual(chatEdit(whole, of: result, style: .agentPrompt), whole)
    checkEqual(chatEdit("The objective is to fix the login.", of: result, style: .agentPrompt), nil)
    // The same text back isn't an edit either, and explanations are answers, not edits.
    checkEqual(chatEdit("CONSTRAINTS:\n- Keep it small.", of: result, style: .agentPrompt), nil)
    checkEqual(chatEdit("TL;DR: x", of: "TL;DR: y", style: .explain), nil)
    // "**Constraints:**" counts as the heading, as the checker accepts it.
    check(chatEdit("**Constraints:**\n- None.", of: result, style: .agentPrompt)?.contains("CONSTRAINTS") == false, "keeps the model's heading")
}

// FEATURE_FUTURE §6: a model big enough to choose well picks from all 203, in two small steps:
// the category, then a pattern in it. A reply that names nothing gives nil, and the keyword order stands.
func testTwoStagePatternPick() throws {
    let patterns = try loadPatterns(from: "Resources/patterns.json")
    let categories = patternCategories(patterns)
    checkEqual(categories.count, Set(patterns.map(\.category)).count)
    var prompts: [String] = []
    let picked = pickPattern(task: "fix the 500 on /signin and add a regression test", from: patterns) { prompt in
        prompts.append(prompt)
        return prompts.count == 1 ? "\(Character(UnicodeScalar(65 + categories.firstIndex(of: "Feedback Loops")!)!))" : "A"
    }
    checkEqual(prompts.count, 2)
    check(prompts[0].contains("Feedback Loops"), prompts[0])
    checkEqual(picked?.category, "Feedback Loops")
    // The second step offers only that category, at most 10 of them, best keyword matches first.
    let offered = patterns.filter { $0.category == "Feedback Loops" }.filter { prompts[1].contains($0.title) }
    check(!offered.isEmpty && offered.count <= 10, "\(offered.count) offered")
    checkEqual(pickPattern(task: "x", from: patterns) { _ in "no idea" }, nil)
    // Only models from about 7B choose better than the keyword order (docs/DECISIONS.md).
    check(choosesFromAllPatterns(LocalModel(format: .mlx, id: "org/big", bytes: 4_500_000_000)), "7B")
    check(!choosesFromAllPatterns(LocalModel(format: .mlx, id: "org/3b", bytes: 2_000_000_000)), "3B")
}

// Seen in the app (2026-11-05): "add a delete command … add a test" put Session-Scoped Context Runtime
// first and Spec-As-Test fourth. Building something is a kind of task too.
func testShortlistForFeatureWork() throws {
    let patterns = try loadPatterns(from: "Resources/patterns.json")
    // The draft as the dialog had it, standard lines included.
    let draft = hardenAgentPrompt("""
    ROLE: AI coding assistant
    OBJECTIVE: Add a delete command to `notes.py` in `tiny notes` to remove a note by its number, without changing the `notes.json` format, and add a test.
    CONTEXT: `notes.py`, `notes.json`
    STEPS:
    1. Open `notes.py`.
    2. Confirm: What is the current structure of `notes.json`?
    3. Add a function to delete a note by its number.
    4. Test the delete function with sample data.
    5. Save `notes.py`.
    CONSTRAINTS:
    - Do not change the `notes.json` format.
    - Do not add any new dependencies.
    DONE WHEN:
    - The delete function removes the note and the test passes.
    """, source: "add a delete command to notes.py in tiny notes so i can remove a note by its number. dont change the notes.json format. add a test")
    let withTest = shortlist(for: draft, in: patterns)
    checkEqual(withTest.prefix(2).map(\.slug), ["spec-as-test-feedback-loop", "plan-then-execute-pattern"])
    let noTest = shortlist(for: "OBJECTIVE: Implement an export button on the reports page.", in: patterns)
    checkEqual(noTest.first?.slug, "plan-then-execute-pattern")
    // A bug fix still wins: "add" appears in most fixes too.
    checkEqual(shortlist(for: "OBJECTIVE: Fix the crash on export and add a regression test.", in: patterns).first?.slug, "spec-as-test-feedback-loop")
}

// Asked for one line per phase, Qwen 2.5 3B filled every phase, but put code in IMPLEMENT and a bare
// function name in SPEC (2 of 3 runs). A prompt says what to do; the agent writes the code.
func testPhaseDetailsAreNotCode() throws {
    guard let p = try loadPatterns(from: "Resources/patterns.json").first(where: { $0.slug == "spec-as-test-feedback-loop" }) else {
        throw TestFailure(description: "no spec-as-test")
    }
    let reply = """
    SPEC: delete_note_by_number()
    RED: Run the new test for deleting note 2 and check that it fails because there is no delete command yet.
    IMPLEMENT: def delete_note_by_number(self, note_number): notes = json.load(open("notes.json")) if note_number in notes: del notes[note_number]
    GREEN: Run the new test and the whole suite, and read the output.
    """
    let steps = sectionBody("STEPS", of: applyWorkflow(p, reply: reply, prompt: "OBJECTIVE: x\\nSTEPS:\\n1. x", source: "add a delete command to notes.py, delete note 2").text)
    check(!steps.contains("def "), steps)
    check(!steps.contains("delete_note_by_number"), steps)
    check(steps.contains("there is no delete command yet"), steps)
    // The instructions ask for one line per phase, not the whole prompt, and say no code.
    let system = phaseDetailsSystemPrompt(p)
    for phase in workflowBlueprint(for: p).phases { check(system.contains("\(phase.name):"), phase.name) }
    check(system.contains("No code"), system)
    check(!system.contains("ROLE:"), "only the phases are asked for")
}

// Seen in the app (2026-11-05, settings-store.json): Qwen 2.5 3B ran a section's bullets together on one
// line, which defeats the easy-to-scan layout Explain is for. They go back on lines of their own.
func testExplanationBulletsOnTheirOwnLines() throws {
    let reply = """
    TL;DR: settings-store.json stores settings for Docker - the desktop app.
    KEY PARTS: – **AutoStart**: false – **AutoStartError**: "option disabled" – **SettingsVersion**: 48
    WATCH OUT FOR: – The value of "LastContainerdSnapshotterEnable" is a timestamp. – The "SettingsVersion" is a number.
    NEXT STEPS:
    - Check the Docker settings.
    """
    let fixed = finishedPrompt(reply, style: .explain, source: "x", builtInInstructions: true).text
    check(fixed.contains("KEY PARTS:\n- **AutoStart**: false\n- **AutoStartError**: \"option disabled\"\n- **SettingsVersion**: 48"), fixed)
    check(fixed.contains("WATCH OUT FOR:\n- The value of \"LastContainerdSnapshotterEnable\" is a timestamp.\n- The \"SettingsVersion\" is a number."), fixed)
    // One dash in a sentence isn't a list.
    check(fixed.contains("TL;DR: settings-store.json stores settings for Docker - the desktop app."), fixed)
    check(fixed.contains("NEXT STEPS:\n- Check the Docker settings."), fixed)
}

// Seen in the final demo (2026-11-05): "dont change the notes.json format" became "Don't change the
// notes", cut at the dot in the file name; and a single bullet stayed on its heading's line.
func testDemoRepairs() throws {
    checkEqual(statedLimits(in: "add a test. dont change the notes.json format. ok"), ["Don't change the notes.json format"])
    checkEqual(statedLimits(in: "never touch v2.3.1, dont log"), ["Never touch v2.3.1", "Don't log"])
    let fixed = finishedExplanation("KEY PARTS: – **Session**: The type.\n– **userId**: The property.\nWATCH OUT FOR: – Check the type.")
    checkEqual(fixed, "KEY PARTS:\n- **Session**: The type.\n– **userId**: The property.\nWATCH OUT FOR:\n- Check the type.")
}
