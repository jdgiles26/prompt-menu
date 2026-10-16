import Foundation

// A quick, deterministic check of a rewritten prompt: no model, same text in, same score out.
// It answers "can I hand this to an agent as is?", not "is it well written?".
struct PromptCheck: Equatable {
    var missingSections: [String] = []
    var confirmCount = 0
    // Names, numbers, files and quoted text from the highlighted text that the prompt dropped.
    var lostFacts: [String] = []
    var doneWhenCheckable = true
    var subjectLength = 0  // Commit messages only.

    // Each problem costs a fixed number of points, so the score is reproducible.
    var score: Int {
        var score = 100
        score -= 15 * missingSections.count
        score -= min(25, 5 * lostFacts.count)
        score -= min(20, 4 * confirmCount)
        if !doneWhenCheckable { score -= 10 }
        if subjectLength > 72 { score -= 15 }
        return max(0, score)
    }

    // One sentence per kind of problem, for the dialog.
    var problems: [String] {
        var list: [String] = []
        if !missingSections.isEmpty { list.append("Missing: \(missingSections.joined(separator: ", ")).") }
        if !lostFacts.isEmpty { list.append("Dropped from your text: \(lostFacts.joined(separator: ", ")).") }
        if confirmCount > 0 { list.append("\(confirmCount) [CONFIRM: …] question\(confirmCount == 1 ? "" : "s") to answer.") }
        if !doneWhenCheckable { list.append("DONE WHEN has nothing an agent can check, such as a test, a number or a visible result.") }
        if subjectLength > 72 { list.append("The subject line is \(subjectLength) characters; keep it to 72.") }
        return list
    }
}

func checkPrompt(_ prompt: String, source: String, style: Style) -> PromptCheck {
    var result = PromptCheck()
    result.missingSections = style.sections.filter { headingRange($0, in: prompt) == nil }
    result.confirmCount = prompt.components(separatedBy: "[CONFIRM:").count - 1
    result.lostFacts = facts(in: source).filter { !contains(prompt, fact: $0) }
    if let doneWhen = sectionText("DONE WHEN", in: prompt, style: style) {
        result.doneWhenCheckable = isCheckable(doneWhen)
    }
    if style == .commitMessage {
        result.subjectLength = prompt.components(separatedBy: "\n").first?.count ?? 0
    }
    return result
}

// "ROLE:", "**ROLE:**", "**Role**:", "## Role:" at the start of a line.
private func headingRange(_ section: String, in text: String) -> Range<String.Index>? {
    let name = NSRegularExpression.escapedPattern(for: section).replacingOccurrences(of: " ", with: "\\s+")
    return text.range(of: "(?im)^[\\s#>*_-]*\(name)[\\s*_]*:", options: .regularExpression)
}

// The text under a heading, up to the next of the style's headings.
private func sectionText(_ section: String, in text: String, style: Style) -> String? {
    guard let start = headingRange(section, in: text) else { return nil }
    let rest = text[start.upperBound...]
    let next = style.sections.compactMap { headingRange($0, in: String(rest)) }.map { $0.lowerBound }.min()
    return String(rest[..<(next ?? rest.endIndex)])
}

private let checkableWords = ["pass", "fail", "return", "show", "display", "print", "exist", "succeed", "match", "equal",
                              "build", "compile", "contain", "respond", "render", "load", "open", "log", "error", "green",
                              "merged", "deployed", "test", "visible", "status", "exit"]

private func isCheckable(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.rangeOfCharacter(from: .decimalDigits) != nil || checkableWords.contains { lower.contains($0) }
}

private let factPatterns = [
    "`([^`\\n]{2,80})`", "\"([^\"\\n]{2,80})\"",                       // quoted
    "\\b([\\w.-]+/[\\w./-]+|[\\w-]+\\.(?:swift|py|js|ts|tsx|jsx|json|md|ya?ml|toml|go|rs|rb|java|kt|c|h|cpp|sh|sql|html|css|plist|txt))\\b", // paths and files
    "\\b([a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[a-z][a-z0-9]*_[a-z0-9_]+)\\b",  // camelCase, PascalCase, snake_case
    "(?<![\\w.])(\\d+(?:[.:]\\d+)*%?)(?![\\w])",                          // numbers and versions
    "\\b([a-z][a-z0-9+.-]*://\\S+)",                                       // links
]

// Facts in the highlighted text that a rewrite must keep, in order of first appearance.
func facts(in text: String) -> [String] {
    var found: [(String, Int)] = []
    let ns = text as NSString
    for pattern in factPatterns {
        let regex = try! NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let fact = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .punctuationCharacters)
            if !fact.isEmpty, !found.contains(where: { $0.0 == fact || $0.0.contains(fact) }) {
                found.append((fact, match.range.location))
            }
        }
    }
    return found.sorted { $0.1 < $1.1 }.map { $0.0 }
}

// Case-insensitive, and a number must stand alone: "3" isn't kept by "2023".
private func contains(_ text: String, fact: String) -> Bool {
    let pattern = "(?<![\\w.])\(NSRegularExpression.escapedPattern(for: fact))(?![\\w])"
    return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}
