import Foundation

func testSystemPrompt() throws {
    // The model is told what an agentic prompt looks like, and to answer with the prompt alone.
    for section in ["ROLE", "OBJECTIVE", "CONTEXT", "STEPS", "CONSTRAINTS", "DONE WHEN"] {
        check(agentSystemPrompt.contains(section), "system prompt is missing \(section)")
    }
    check(agentSystemPrompt.contains("[CONFIRM"), "system prompt should mark unknowns instead of inventing them")
    check(agentSystemPrompt.lowercased().contains("only the prompt"), "system prompt should ask for the prompt alone")
}

func testPrepareInput() throws {
    checkEqual(try prepareInput("  fix the login bug \n\n"), "fix the login bug")
    checkEqual(try prepareInput("line one\nline two"), "line one\nline two")
    checkThrows(.emptyInput) { _ = try prepareInput("") }
    checkThrows(.emptyInput) { _ = try prepareInput(" \n\t ") }
}

func testLongInput() throws {
    let long = String(repeating: "a", count: maxInputCharacters + 500)
    let prepared = try prepareInput(long)
    checkEqual(prepared.count, maxInputCharacters)
    let exact = String(repeating: "b", count: maxInputCharacters)
    checkEqual(try prepareInput(exact), exact)
}

func testCleanOutput() throws {
    // ANSI colors, as llama.cpp prints them on a terminal.
    checkEqual(cleanOutput("\u{1B}[1;32mROLE: dev\u{1B}[0m"), "ROLE: dev")
    // mlx_lm.generate's separators and stats, should --verbose be on.
    checkEqual(cleanOutput("==========\nROLE: dev\n==========\nPrompt: 12 tokens, 80.1 tokens-per-sec\nGeneration: 5 tokens, 30.2 tokens-per-sec\nPeak memory: 1.9 GB\n"),
               "ROLE: dev")
    // Reasoning models think out loud first.
    checkEqual(cleanOutput("<think>\nThe user wants…\n</think>\n\nROLE: dev"), "ROLE: dev")
    // While streaming, thinking that hasn't finished yet shows nothing.
    checkEqual(cleanOutput("<think>\nThe user wa"), "")
    // While streaming, mlx_lm.generate's first separator has arrived but the second hasn't.
    checkEqual(cleanOutput("==========\nROLE: d"), "ROLE: d")
    // llama.cpp marks the end.
    checkEqual(cleanOutput("ROLE: dev\n\n[end of text]\n"), "ROLE: dev")
    // With --no-display-prompt, llama.cpp puts it at the end of the last line (seen with build 10470).
    checkEqual(cleanOutput("DONE WHEN: tests pass. [end of text]\n\n"), "DONE WHEN: tests pass.")
    // A reply wrapped whole in one code fence is unwrapped; fences inside are kept.
    checkEqual(cleanOutput("```markdown\nROLE: dev\n```"), "ROLE: dev")
    checkEqual(cleanOutput("ROLE: dev\n```sh\nls\n```"), "ROLE: dev\n```sh\nls\n```")
    // Small models announce the answer despite being told not to; the announcement goes.
    checkEqual(cleanOutput("Here is the rewritten prompt:\n\nROLE: dev"), "ROLE: dev")
    checkEqual(cleanOutput("Sure! Here's the bug report:\nTITLE: x"), "TITLE: x")
    checkEqual(cleanOutput("Here is the rewritten prompt:\n```\nROLE: dev\n```"), "ROLE: dev")
    // But a first line that is content stays, and so does an announcement that's still arriving.
    checkEqual(cleanOutput("Here is what happens: the app crashes.\nTITLE: x"), "Here is what happens: the app crashes.\nTITLE: x")
    checkEqual(cleanOutput("Here is the rewri"), "Here is the rewri")
    checkEqual(cleanOutput("  \n"), "")
}

// Files right-clicked in Finder: each one's name, then its text, all within maxInputCharacters.
func testExplainFileInput() throws {
    let dir = try makeTempFolder()
    let swift = (dir as NSString).appendingPathComponent("Login.swift")
    try "func login() {}".write(toFile: swift, atomically: true, encoding: .utf8)
    checkEqual(try explainInput(files: [swift]), "File: Login.swift\n\nfunc login() {}")

    let notes = (dir as NSString).appendingPathComponent("notes.txt")
    try "two".write(toFile: notes, atomically: true, encoding: .utf8)
    checkEqual(try explainInput(files: [swift, notes]), "File: Login.swift\n\nfunc login() {}\n\nFile: notes.txt\n\ntwo")

    let big = (dir as NSString).appendingPathComponent("big.txt")
    try String(repeating: "x", count: maxInputCharacters * 2).write(toFile: big, atomically: true, encoding: .utf8)
    checkEqual(try explainInput(files: [big]).count, maxInputCharacters)

    // Bytes are trimmed only where the read stopped mid-character, not to excuse a bad last byte.
    let tail = (dir as NSString).appendingPathComponent("tail.txt")
    try (Data(String(repeating: "a", count: maxInputCharacters + 1000).utf8) + [0xFF]).write(to: URL(fileURLWithPath: tail))
    checkThrows(.unreadableFile("tail.txt")) { _ = try explainInput(files: [tail]) }
    let cut = (dir as NSString).appendingPathComponent("cut.txt")
    try String(repeating: "é", count: maxInputCharacters * 3).write(toFile: cut, atomically: true, encoding: .utf8)
    checkEqual(try explainInput(files: [cut]).count, maxInputCharacters)
    // Once the text is full, later files aren't read at all.
    checkEqual(try explainInput(files: [big, (dir as NSString).appendingPathComponent("gone.txt")]).count, maxInputCharacters)

    // Not text: a binary file, a folder, a file that isn't there.
    let binary = (dir as NSString).appendingPathComponent("image.png")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: binary))
    checkThrows(.unreadableFile("image.png")) { _ = try explainInput(files: [binary]) }
    checkThrows(.unreadableFile((dir as NSString).lastPathComponent)) { _ = try explainInput(files: [dir]) }
    checkThrows(.unreadableFile("gone.txt")) { _ = try explainInput(files: [(dir as NSString).appendingPathComponent("gone.txt")]) }
    checkThrows(.emptyInput) { _ = try explainInput(files: []) }
}
