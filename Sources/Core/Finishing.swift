import Foundation

// Deterministic repairs to a finished rewrite, for what small models get wrong however they're asked.
// Each one was seen from Qwen 2.5 3B (docs/DECISIONS.md, 2026-11-05).

// MARK: Names the text never gave

// Folders that start a relative path in most projects, so `tests/auth` reads as a path and `and/or` doesn't.
private let codeFolders: Set<String> = [
    "src", "source", "sources", "lib", "libs", "app", "apps", "test", "tests", "spec", "specs", "pkg", "cmd",
    "internal", "doc", "docs", "config", "configs", "script", "scripts", "packages", "components", "api",
    "server", "client", "web", "bin", "include", "resources", "assets", "public", "migrations", "db",
]
private let fileName = "(?:[\\w.-]+/)*[\\w-]+\\.(?:swift|py|js|ts|tsx|jsx|json|md|ya?ml|toml|go|rs|rb|java|kt|c|h|cpp|sh|sql|html|css|plist|txt|cfg|ini|xml|cs|php|vue|scss)"
private let pathName = "(?:~|\\.{1,2})?/[\\w.-]+(?:/[\\w.-]+)*/?|[\\w.-]+(?:/[\\w.-]+)+/?"
private let nameRegex = try! NSRegularExpression(pattern: "(?<![\\w/.:@-])(\(fileName)|\(pathName))(?![\\w/])")

private func looksLikePath(_ name: String) -> Bool {
    guard name.rangeOfCharacter(from: .letters) != nil else { return false }  // 11/05/2026
    if name.range(of: "\\.[a-z]+$", options: .regularExpression) != nil, !name.hasSuffix("/") { return true }
    if name.hasPrefix("/") || name.hasPrefix("~/") || name.hasPrefix("./") || name.hasPrefix("../") { return true }
    let segments = name.split(separator: "/")
    return segments.count >= 3 || codeFolders.contains(segments.first.map { $0.lowercased() } ?? "")
}

// Two digits or more: one digit is a list item or the work loop's "3 attempts".
private let numberRegex = try! NSRegularExpression(pattern: "(?<![\\w.#$-])(\\d{2,}(?:[.,:]\\d+)*%?)(?![\\w])")

// "10,000" from "10k" isn't made up.
private func isRestated(_ number: String, in source: String) -> Bool {
    let digits = number.replacingOccurrences(of: ",", with: "")
    guard digits.hasSuffix("000"), digits.count > 3 else { return false }
    return source.range(of: "(?i)(?<![\\w.])\(digits.dropLast(3))\\s?k\\b", options: .regularExpression) != nil
}

// Files, folders and numbers in `text` that `source` doesn't have, in order.
func inventedNames(in text: String, source: String) -> [String] {
    let ns = text as NSString
    let whole = NSRange(location: 0, length: ns.length)
    var seen = Set<String>()
    let found = nameRegex.matches(in: text, range: whole).map { (ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ".")), $0.range.location, true) }
        + numberRegex.matches(in: text, range: whole).map { (ns.substring(with: $0.range(at: 1)), $0.range.location, false) }
    return found.sorted { $0.1 < $1.1 }.compactMap { name, _, isPath in
        guard isPath ? looksLikePath(name) : !isRestated(name, in: source),
              seen.insert(name).inserted, !contains(source, fact: name) else { return nil }
        return name
    }
}

// Each such name, the first time it appears, followed by a question, so it can't pass as a fact.
func questioningInventedNames(_ text: String, source: String) -> String {
    var result = text
    for name in inventedNames(in: text, source: source) {
        let question = "[CONFIRM: is \(name) right? It isn't in your text.]"
        guard !result.contains(question) else { continue }
        let pattern = "(?<![\\w/.:@-])\(NSRegularExpression.escapedPattern(for: name))(?![\\w/])`?"
        guard let at = result.range(of: pattern, options: .regularExpression) else { continue }
        result.insert(contentsOf: " " + question, at: at.upperBound)
    }
    return result
}

// MARK: Commit messages

private let imperativeVerbs: Set<String> = ["Fix", "Add", "Remove", "Update", "Change", "Refactor", "Improve", "Make", "Use",
                                             "Handle", "Correct", "Set", "Move", "Rename", "Drop", "Bump", "Revert", "Allow", "Stop"]

// What the text says was run, for a "Verified:" line the model left empty: "tests pass now".
private func statedVerification(in source: String) -> String? {
    let pattern = "(?i)\\b((?:all |the )?(?:tests?|checks?|specs?|build|ci|linters?)\\b[^.,;\\n]*?\\b(?:pass|passes|passed|passing|green|succeeds?|succeeded|works?)\\b[^.,;\\n]*)"
    guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
    return source[range].trimmingCharacters(in: .whitespaces)
}

// The commit message's shape, whatever the model did to it: no "Subject:" or "Body:" labels, a
// subject in the imperative with no period, a CONFIRM in brackets, and a "Verified:" line only when
// the text says what was run. A message that's already right comes back unchanged.
func finishedCommitMessage(_ text: String, source: String) -> String {
    var lines = text.components(separatedBy: "\n").filter {
        $0.range(of: "^\\s*(?:subject|title|body|summary|commit message)\\s*:\\s*$", options: [.regularExpression, .caseInsensitive]) == nil
    }
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    guard !lines.isEmpty else { return text }
    var subject = lines[0].replacingOccurrences(of: "^\\s*(?:subject|title)\\s*:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
    // "Fix: Cache TTL…" → "Fix cache TTL…". A lowercase "fix:" is the Conventional Commits style, and stays.
    if let label = subject.range(of: "^[A-Z][a-z]+:\\s+", options: .regularExpression),
       case let verb = subject[..<subject.firstIndex(of: ":")!], imperativeVerbs.contains(String(verb)) {
        var rest = String(subject[label.upperBound...])
        if rest.count > 1, rest[rest.index(after: rest.startIndex)].isLowercase { rest = rest.prefix(1).lowercased() + rest.dropFirst() }
        subject = "\(verb) \(rest)"
    }
    while subject.hasSuffix("."), !subject.hasSuffix("..") { subject.removeLast() }
    lines[0] = subject
    lines = lines.compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("CONFIRM:") { return "[\(trimmed)]" }
        if trimmed.range(of: "^verified:?$", options: [.regularExpression, .caseInsensitive]) != nil {
            return statedVerification(in: source).map { "Verified: \($0)" }
        }
        return line
    }
    // Left out, though the text says what was run.
    if !lines.contains(where: { $0.hasPrefix("Verified:") }), let verified = statedVerification(in: source) {
        lines += ["", "Verified: \(verified)"]
    }
    return lines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: Explanations

private let explainHeading = try! NSRegularExpression(pattern: "^((?:TL;DR|WHAT IT IS|HOW IT WORKS|KEY PARTS|WATCH OUT FOR|NEXT STEPS):)\\s*(.*)$")
private let inlineBullet = "(?:^|\\s)[–—-]\\s+(?=\\*\\*|[A-Z\"`])"

// An explanation with each bullet on its own line. Small models sometimes run a section's bullets
// together after its heading ("KEY PARTS: – **a**: x – **b**: y"), which defeats the easy-to-scan layout.
// Two bullets or more on a line count; one dash in a sentence doesn't.
func finishedExplanation(_ text: String) -> String {
    text.components(separatedBy: "\n").map { line -> String in
        let ns = line as NSString
        var head = "", rest = line
        if let match = explainHeading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            head = ns.substring(with: match.range(at: 1))
            rest = ns.substring(with: match.range(at: 2))
        }
        let restNS = rest as NSString
        let bullets = try! NSRegularExpression(pattern: inlineBullet).matches(in: rest, range: NSRange(location: 0, length: restNS.length))
        guard bullets.count >= 2, bullets[0].range.location == 0 else { return line }
        let items = rest.replacingOccurrences(of: inlineBullet, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ([head].filter { !$0.isEmpty } + items.map { "- \($0)" }).joined(separator: "\n")
    }.joined(separator: "\n")
}
