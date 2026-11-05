import Foundation

// Send To (FEATURE_FUTURE §4): the finished prompt goes to a coding agent's CLI, in Terminal, in a
// folder the user picks. CLIs change their flags often, so each one is data: a program and its
// arguments, with {prompt} where the prompt goes. Users add or change them in harnesses.json.
//
// The prompt is never written to disk (guardrail 2.1) and never becomes shell code: the Terminal
// script holds only the folder and the command, and reads the prompt from the clipboard when it
// runs, as one argument. Copy Command puts it in as one single-quoted word.

struct Harness: Equatable, Codable {
    var name: String
    var program: String      // Looked up like the model runners, so only installed CLIs are offered.
    var arguments: [String]  // One of them contains promptPlaceholder.
}

let promptPlaceholder = "{prompt}"

// Each checked against that CLI's own documentation on 2026-11-05: `claude [prompt]` (claude --help,
// 2.1.318), `codex [PROMPT]` (openai/codex cli.rs), `gemini -i` (Gemini CLI reference: starts an
// interactive session with the prompt), `aider --message` (aider docs: sends it, then exits).
let defaultHarnesses = [
    Harness(name: "Claude Code", program: "claude", arguments: [promptPlaceholder]),
    Harness(name: "Codex", program: "codex", arguments: [promptPlaceholder]),
    Harness(name: "Gemini CLI", program: "gemini", arguments: ["-i", promptPlaceholder]),
    Harness(name: "Aider", program: "aider", arguments: ["--message", promptPlaceholder]),
]

// ~/Library/Application Support/Prompt Menu/harnesses.json, which the user creates. The app reads it, never writes it.
func harnessFile(home: String = NSHomeDirectory()) -> String {
    "\(home)/Library/Application Support/Prompt Menu/harnesses.json"
}

private struct HarnessList: Codable {
    var schema: Int
    var harnesses: [Harness]
}

// The defaults, with the file's entries replacing those of the same name and adding the rest.
// `problem` says what in the file was ignored, if anything.
func loadHarnesses(file: String = harnessFile()) -> (harnesses: [Harness], problem: String?) {
    guard let data = FileManager.default.contents(atPath: file) else { return (defaultHarnesses, nil) }
    guard let list = try? JSONDecoder().decode(HarnessList.self, from: data) else {
        return (defaultHarnesses, "\((file as NSString).lastPathComponent) couldn't be read, so only the built-in agents are listed.")
    }
    var result = defaultHarnesses
    var ignored: [String] = []
    for harness in list.harnesses {
        guard !harness.program.isEmpty, harness.arguments.filter({ $0.contains(promptPlaceholder) }).count == 1 else {
            ignored.append(harness.name)
            continue
        }
        if let index = result.firstIndex(where: { $0.name == harness.name }) { result[index] = harness } else { result.append(harness) }
    }
    let problem = ignored.isEmpty ? nil : "Ignored in harnesses.json (each needs a program and one {prompt}): \(ignored.joined(separator: ", "))."
    return (result, problem)
}

// The harnesses whose program is installed, with its path.
func installedHarnesses(_ harnesses: [Harness], searchDirs: [String] = standardSearchDirs()) -> [(harness: Harness, path: String)] {
    harnesses.compactMap { harness in
        let path = harness.program.hasPrefix("/")
            ? (FileManager.default.isExecutableFile(atPath: harness.program) ? harness.program : nil)
            : findExecutable(named: harness.program, in: searchDirs)
        return path.map { (harness, $0) }
    }
}

// One word to the shell, whatever is in it.
func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// An argument with the prompt standing in for {prompt}, given as shell code that produces it.
private func shellArgument(_ argument: String, prompt: String) -> String {
    let parts = argument.components(separatedBy: promptPlaceholder)
    return parts.map { $0.isEmpty ? "" : shellQuoted($0) }.joined(separator: prompt)
}

// The .command script for Terminal: it deletes itself, goes to the folder, and starts the CLI with
// the clipboard's text as the prompt. `paste` is pbpaste, or a stand-in in tests.
func terminalScript(_ harness: Harness, path: String, folder: String, paste: String = "/usr/bin/pbpaste") -> String {
    let prompt = "\"$(\(shellQuoted(paste)))\""
    let command = ([shellQuoted(path)] + harness.arguments.map { shellArgument($0, prompt: prompt) }).joined(separator: " ")
    return """
    #!/bin/sh
    # Written by Prompt Menu to start \(harness.name). It holds no prompt: that's read from the clipboard.
    rm -f -- "$0"
    cd -- \(shellQuoted(folder)) || exit 1
    \(command)

    """
}

// A command to paste into any terminal, with the prompt in it as one quoted word.
func copyCommand(_ harness: Harness, folder: String, prompt: String) -> String {
    let command = ([shellQuoted(harness.program)] + harness.arguments.map { shellArgument($0, prompt: shellQuoted(prompt)) })
    return "cd \(shellQuoted(folder)) && " + command.joined(separator: " ")
}

// The folders the user sent prompts to, newest first, so the folder picker starts in the last one.
private let recentFoldersKey = "agentFolders"
private let maxRecentFolders = 5

func recentAgentFolders(from defaults: UserDefaults = settings) -> [String] {
    defaults.stringArray(forKey: recentFoldersKey) ?? []
}

func rememberAgentFolder(_ folder: String, in defaults: UserDefaults = settings) {
    let folders = [folder] + recentAgentFolders(from: defaults).filter { $0 != folder }
    defaults.set(Array(folders.prefix(maxRecentFolders)), forKey: recentFoldersKey)
}
