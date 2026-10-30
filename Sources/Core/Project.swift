import Foundation

// Project context: the headings and commands from a project's own instructions, so the prompt can
// name real commands and conventions. Read only from a folder the user picked.

private let projectFiles = ["AGENTS.md", "CLAUDE.md", "README.md"]
// Enough to reach the commands section of most READMEs, without filling a small model's context.
private let charactersPerFile = 4000
private let maxHeadings = 20, maxCommands = 15
private let shellFences: Set<String> = ["", "sh", "bash", "zsh", "shell", "console"]

func projectContext(folder: String) -> String? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    var used: [String] = [], headings: [String] = [], commands: [String] = []
    for wanted in projectFiles {
        // README.md is sometimes Readme.md or readme.md.
        guard let name = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }),
              let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8) else { continue }
        used.append(name)
        var fence: String? = nil  // The open code block's language, if inside one.
        for raw in String(text.prefix(charactersPerFile)).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                fence = fence == nil ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() : nil
            } else if let language = fence {
                if shellFences.contains(language), !line.isEmpty { commands.append(line.hasPrefix("$ ") ? String(line.dropFirst(2)) : line) }
            } else if line.hasPrefix("$ ") {
                commands.append(String(line.dropFirst(2)))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                headings.append(String(line[range.upperBound...]))
            }
        }
    }
    let sections = unique(headings).prefix(maxHeadings), runs = unique(commands).prefix(maxCommands)
    guard !sections.isEmpty || !runs.isEmpty else { return nil }
    var lines = ["Project \"\((folder as NSString).lastPathComponent)\" (from its \(used.joined(separator: ", "))):"]
    if !sections.isEmpty { lines.append("Sections: " + sections.joined(separator: " · ")) }
    if !runs.isEmpty { lines.append("Commands:"); lines += runs.map { "- " + $0 } }
    return lines.joined(separator: "\n")
}

// The highlighted text, then the project facts, cut so the whole stays within maxInputCharacters.
// The text is never cut for the context's sake.
func withProjectContext(_ text: String, context: String) -> String {
    let prefix = text + "\n\nProject facts, from the project's own files:\n"
    let room = maxInputCharacters - prefix.count
    return room > 0 ? prefix + context.prefix(room) : text
}

private func unique(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}
