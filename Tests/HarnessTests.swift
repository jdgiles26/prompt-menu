import Foundation

// FEATURE_FUTURE §4: send the finished prompt to a coding agent's CLI. The prompt reaches the
// command only through the clipboard (pbpaste) or, for Copy Command, as one single-quoted word, so
// nothing in it can run as a command, and it's never written to disk.

private let nasty = "Fix it'; rm -rf ~; echo \"$(whoami)\" `id` $HOME\nline two \\ end"

// Each default is checked against that CLI's current --help or docs (docs/DECISIONS.md).
func testHarnessDefaults() throws {
    let names = defaultHarnesses.map(\.name)
    checkEqual(names, ["Claude Code", "Codex", "Gemini CLI", "Aider"])
    for harness in defaultHarnesses {
        checkEqual(harness.arguments.filter { $0.contains(promptPlaceholder) }.count, 1)
    }
}

// The user's harnesses.json adds CLIs and replaces a default of the same name; a broken file says so.
func testHarnessFile() throws {
    let folder = try makeTempFolder()
    let file = (folder as NSString).appendingPathComponent("harnesses.json")
    checkEqual(loadHarnesses(file: file).harnesses, defaultHarnesses)  // No file: the defaults.
    try """
    {"schema": 1, "harnesses": [
      {"name": "Claude Code", "program": "claude", "arguments": ["--model", "opus", "{prompt}"]},
      {"name": "opencode", "program": "opencode", "arguments": ["--prompt", "{prompt}"]}
    ]}
    """.write(toFile: file, atomically: true, encoding: .utf8)
    let loaded = loadHarnesses(file: file)
    checkEqual(loaded.problem, nil)
    checkEqual(loaded.harnesses.map(\.name), ["Claude Code", "Codex", "Gemini CLI", "Aider", "opencode"])
    checkEqual(loaded.harnesses[0].arguments, ["--model", "opus", "{prompt}"])
    // One without {prompt} can't take the prompt, so it's left out and named.
    try #"{"schema": 1, "harnesses": [{"name": "Bad", "program": "x", "arguments": []}]}"#.write(toFile: file, atomically: true, encoding: .utf8)
    let bad = loadHarnesses(file: file)
    checkEqual(bad.harnesses, defaultHarnesses)
    check(bad.problem?.contains("Bad") == true, bad.problem ?? "no problem reported")
    try "not json".write(toFile: file, atomically: true, encoding: .utf8)
    let broken = loadHarnesses(file: file)
    checkEqual(broken.harnesses, defaultHarnesses)
    check(broken.problem?.contains("harnesses.json") == true, broken.problem ?? "no problem reported")
}

// Only installed CLIs are offered.
func testHarnessDetection() throws {
    let bin = try makeTempFolder()
    try makeScript("codex", in: bin, "exit 0")
    let found = installedHarnesses(defaultHarnesses, searchDirs: [bin])
    checkEqual(found.map(\.harness.name), ["Codex"])
    checkEqual(found.first?.path, (bin as NSString).appendingPathComponent("codex"))
}

// The Terminal script has the folder and the command, never the prompt; it reads the prompt from
// the clipboard when it runs, passes it as one argument, and deletes itself.
func testHarnessTerminalScript() throws {
    let folder = try makeTempFolder()
    let work = (folder as NSString).appendingPathComponent("my project's 'dir'")
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    let out = (folder as NSString).appendingPathComponent("out.txt")
    let agent = try makeScript("agent", in: folder, "pwd > '\(out)'; for a in \"$@\"; do printf '[%s]\\n' \"$a\" >> '\(out)'; done")
    let paste = try makeScript("paste", in: folder, "printf '%s' '\(nasty.replacingOccurrences(of: "'", with: "'\\''"))'")
    let harness = Harness(name: "Test", program: "agent", arguments: ["-i", promptPlaceholder])
    let script = terminalScript(harness, path: agent, folder: work, paste: paste)
    check(!script.contains("rm -rf ~"), "the prompt must not be in the script")
    let scriptPath = (folder as NSString).appendingPathComponent("send.command")
    try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/bin/sh")
    run.arguments = [scriptPath]
    try run.run()
    run.waitUntilExit()
    checkEqual(run.terminationStatus, 0)
    let printed = try String(contentsOfFile: out, encoding: .utf8)
    checkEqual(printed, "\(work)\n[-i]\n[\(nasty)]\n")
    check(!FileManager.default.fileExists(atPath: scriptPath), "the script deletes itself")
}

// Copy Command puts the prompt in as one single-quoted word, so pasting it into a shell runs only the CLI.
func testHarnessCopyCommand() throws {
    let folder = try makeTempFolder()
    let out = (folder as NSString).appendingPathComponent("out.txt")
    let agent = try makeScript("agent", in: folder, "for a in \"$@\"; do printf '[%s]\\n' \"$a\" >> '\(out)'; done")
    let harness = Harness(name: "Test", program: agent, arguments: ["--message={prompt}", "--yes"])
    let command = copyCommand(harness, folder: folder, prompt: nasty)
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/bin/sh")
    run.arguments = ["-c", command]
    try run.run()
    run.waitUntilExit()
    checkEqual(try String(contentsOfFile: out, encoding: .utf8), "[--message=\(nasty)]\n[--yes]\n")
}

// Recent folders, newest first, no repeats, at most 5.
func testRecentAgentFolders() throws {
    let defaults = UserDefaults(suiteName: "PromptMenuTests-\(UUID().uuidString)")!
    for folder in ["/a", "/b", "/a", "/c", "/d", "/e", "/f"] { rememberAgentFolder(folder, in: defaults) }
    checkEqual(recentAgentFolders(from: defaults), ["/f", "/e", "/d", "/c", "/a"])
}
