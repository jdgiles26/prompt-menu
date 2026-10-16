import Foundation

// One workflow from Awesome Agentic Patterns (github.com/nibzard/awesome-agentic-patterns,
// Apache-2.0). Resources/patterns.json is a snapshot made by scripts/update-patterns.sh; the app
// never downloads it.
struct AgenticPattern: Codable, Equatable {
    var slug: String
    var title: String
    var category: String
    var status: String
    var summary: String
    var signals: [String]      // "Use when"
    var antiSignals: [String]  // "Avoid when"
    var tags: [String]
    var solution: String       // An excerpt of the pattern's Solution section.
}

private struct Catalog: Codable { var patterns: [AgenticPattern] }

func loadPatterns(from path: String) throws -> [AgenticPattern] {
    try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: path))).patterns
}

// MARK: Picking candidates without a model

private let stopwords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "from", "into", "your", "you", "are", "was", "were", "will", "can",
    "not", "but", "all", "any", "each", "its", "they", "them", "then", "than", "when", "what", "which", "who", "how",
    "has", "have", "had", "use", "used", "uses", "using", "one", "two", "only", "also", "more", "most", "such", "other",
    "out", "about", "over", "before", "after", "while", "there", "their", "should", "must", "would", "could", "need",
    "needs", "every", "some", "same", "own", "via", "per", "does", "don", "doesn", "make", "makes", "role", "objective",
    "context", "steps", "constraints", "done", "confirm", "agent", "agents", "task", "tasks", "our", "across", "add",
    "new", "get", "let", "like", "want", "just", "sure", "keep", "way", "thing", "things", "work", "works", "first",
    "now", "here", "where", "these", "those", "same", "both", "able", "without", "within", "through", "between",
    // Verbs and nouns every task prompt has, which say nothing about the workflow.
    "change", "changes", "changed", "changing", "current", "currently", "issue", "issues", "resolve", "implement",
    "message", "messages", "second", "seconds", "step", "fix", "fixes", "fixed", "update", "updates", "ensure",
    "identify", "investigate", "result", "results", "solution", "successfully", "problem", "problems", "user", "users",
]
// Short words that do say something about the workflow.
private let shortTerms: Set<String> = ["ci", "ui", "pr", "qa", "db", "vm", "rl"]

// Lowercase words without stopwords, cut to a rough stem so "planning", "plans" and "plan" match.
func patternTokens(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap { word -> String? in
        var w = String(word)
        guard w.count >= 3 || shortTerms.contains(w), !stopwords.contains(w) else { return nil }
        for suffix in ["ations", "ation", "ing", "ed", "es", "s", "e"] where w.hasSuffix(suffix) && w.count - suffix.count >= 4 {
            w.removeLast(suffix.count)
            break
        }
        if let last = w.last, w.count >= 5, w.dropLast().last == last { w.removeLast() }  // "plann" → "plan"
        return w
    }
}

// How much a word in each field says about the pattern.
private func weightedTokens(_ p: AgenticPattern) -> [String: Double] {
    var weights: [String: Double] = [:]
    func add(_ text: String, _ weight: Double) {
        for t in patternTokens(text) { weights[t] = max(weights[t] ?? 0, weight) }
    }
    add(p.summary, 1.5)
    add(p.signals.joined(separator: " "), 2)
    add(p.tags.joined(separator: " "), 3)
    add(p.title, 3)
    return weights
}

// General workflows for coding tasks, offered when few patterns match the words of the prompt.
let generalPatternSlugs = ["plan-then-execute-pattern", "spec-as-test-feedback-loop", "self-critique-evaluator-loop",
                           "output-verification-loop", "discrete-phase-separation"]

// Each pattern's fit for the text: word overlap weighted by field, rarer words counting more, and
// a penalty for words that match the pattern's "Avoid when". Best first; no-match patterns left out.
func rankPatterns(for text: String, in patterns: [AgenticPattern]) -> [(pattern: AgenticPattern, score: Double, matches: Int)] {
    let query = Set(patternTokens(text))
    let indexed = patterns.map { ($0, weightedTokens($0)) }
    var documentFrequency: [String: Int] = [:]
    for (_, weights) in indexed { for t in weights.keys { documentFrequency[t, default: 0] += 1 } }
    let total = Double(patterns.count)
    let proven: Set<String> = ["established", "validated-in-production", "best-practice"]

    let scored = indexed.map { pattern, weights -> (pattern: AgenticPattern, score: Double, matches: Int) in
        let avoid = Set(patternTokens(pattern.antiSignals.joined(separator: " ")))
        var score = 0.0, matches = 0
        for t in query {
            let idf = log(total / Double(1 + (documentFrequency[t] ?? 0)))
            if let w = weights[t] { score += w * idf; matches += 1 }
            if avoid.contains(t) && weights[t] == nil { score -= idf }
        }
        return (pattern, proven.contains(pattern.status) ? score * 1.1 : score, matches)
    }
    return scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
}

// The candidates to offer: keyword matches backed by at least three words of the prompt (fewer
// are usually a coincidence), with two places kept for general workflows.
func shortlist(for text: String, in patterns: [AgenticPattern], count: Int = 5) -> [AgenticPattern] {
    let ranked = rankPatterns(for: text, in: patterns)
    var picks = ranked.filter { $0.matches >= 3 }.prefix(max(1, count - 2)).map(\.pattern)
    // General workflows in the order the prompt's words favour them.
    let general = generalPatternSlugs.compactMap { slug in patterns.first { $0.slug == slug } }
    let order = Dictionary(ranked.map { ($0.pattern.slug, $0.score) }, uniquingKeysWith: max)
    for p in general.sorted(by: { order[$0.slug] ?? 0 > order[$1.slug] ?? 0 }) where picks.count < count && !picks.contains(p) {
        picks.append(p)
    }
    return picks
}

// For the search field: title matches first, then any field.
func searchPatterns(_ query: String, in patterns: [AgenticPattern], limit: Int = 30) -> [AgenticPattern] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return [] }
    let inTitle = patterns.filter { $0.title.lowercased().contains(q) || $0.slug.contains(q) }
    let elsewhere = patterns.filter { p in
        !inTitle.contains(p) && [p.summary, p.category, p.tags.joined(separator: " "), p.signals.joined(separator: " ")]
            .contains { $0.lowercased().contains(q) }
    }
    return Array((inTitle + elsewhere).prefix(limit))
}

// MARK: Letting the model pick one (a typed choice, like a decision model)

let patternChoiceSystemPrompt = "You pick the workflow pattern that best fits an AI agent's task. Reply with only the letter of the best option."

func patternChoicePrompt(task: String, options: [AgenticPattern]) -> String {
    let letters = "ABCDEFGHIJ".map(String.init)
    let list = zip(letters, options).map { letter, p in
        "\(letter). \(p.title): \(p.summary)\n   Use when: \(p.signals.joined(separator: "; "))\n   Avoid when: \(p.antiSignals.joined(separator: "; "))"
    }.joined(separator: "\n")
    let choices = letters.prefix(options.count).joined(separator: ", ")
    // Options first: the input limit cuts the end of a long task, never the options.
    return "OPTIONS:\n\(list)\n\nTASK:\n\(task.prefix(3000))\n\nWhich option fits the task best? Reply with one letter: \(choices)."
}

// The option a reply names, as an index: "B", "C. Title", "b)", "The answer is D", "A good fit is E".
func parseChoice(_ reply: String, count: Int) -> Int? {
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    func index(_ letter: Character) -> Int? {
        guard let ascii = letter.uppercased().first?.asciiValue, ascii >= 65 else { return nil }
        let i = Int(ascii) - 65
        return i < count ? i : nil
    }
    // A letter alone, or followed by punctuation, at the start.
    if let first = text.first, first.isLetter, text.count == 1 || [".", ")", ":", ","].contains(text.dropFirst().first!) {
        return index(first)
    }
    // Otherwise the last standalone capital letter.
    let matches = text.ranges(of: "(?<![A-Za-z])[A-J](?![A-Za-z])")
    return matches.last.flatMap { index(text[$0].first!) }
}

private extension String {
    func ranges(of pattern: String) -> [Range<String.Index>] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self) }
    }
}

// MARK: Rewriting a prompt around a pattern

// `sections` are the headings the prompt must keep (the style's). Small models copy whatever
// headings they see, so the exact output headings are spelled out and the pattern's own text is
// marked as background, with its code and headings removed.
func patternSystemPrompt(_ p: AgenticPattern, sections: [String] = Style.agentPrompt.sections) -> String {
    let patternLine = "WORKFLOW PATTERN: \(p.title), because <why it fits this task, in one sentence>"
    var outline: [String] = sections.map { section in
        switch section {
        case "STEPS": return "STEPS: the pattern's phases applied to this task, numbered, with a checkpoint after each phase"
        case "CONSTRAINTS": return "CONSTRAINTS: the prompt's constraints, plus the ones the pattern needs"
        case "DONE WHEN": return "DONE WHEN: the prompt's finish criteria, plus the pattern's"
        default: return "\(section): as in the prompt"
        }
    }
    outline.insert(patternLine, at: min(2, outline.count))
    let format = sections.isEmpty
        ? "Keep the prompt's format, and add this line at the end:\n\(patternLine)"
        : "Use exactly these headings, in this order, and no others:\n" + outline.joined(separator: "\n")
    return """
    You restructure a prompt for an AI agent so the agent follows a proven agentic workflow pattern.

    BACKGROUND ON THE PATTERN (for you to understand it; don't copy its wording, headings or examples):
    Name: \(p.title) (\(p.category))
    What it does: \(p.summary)
    Use it when: \(p.signals.joined(separator: "; "))
    Watch out for: \(p.antiSignals.joined(separator: "; "))
    How it works: \(plainText(p.solution))

    Rewrite the user's prompt so the agent applies this pattern to the user's task.
    \(format)

    Rules:
    - Keep every fact, name, number and [CONFIRM: …] from the prompt. Never invent details; write [CONFIRM: what to ask] instead.
    - Write about the user's task only, not about the pattern in general.
    - Reply with only the rewritten prompt: no preamble, no explanation.
    """
}

// Markdown without code blocks, headings or emphasis, joined into running text.
private func plainText(_ markdown: String) -> String {
    markdown
        .replacingOccurrences(of: "(?s)```.*?```", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?m)^#+\\s*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[*_`]+", with: "", options: .regularExpression)
        .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: " ")
}
