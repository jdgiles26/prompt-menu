import Foundation

// Fill Gaps: the model marks what it couldn't know as [CONFIRM: question]. The user answers some,
// and each answer replaces its marker exactly, with no model involved.

private let confirmMarker = try! NSRegularExpression(pattern: #"\[CONFIRM:([^\]]*)\]"#)

private func confirmMatches(in text: String) -> [(range: NSRange, question: String)] {
    let ns = text as NSString
    return confirmMarker.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
        ($0.range, ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Each non-empty question once, in the order it first appears.
func confirmQuestions(in text: String) -> [String] {
    var seen = Set<String>()
    return confirmMatches(in: text).map(\.question).filter { !$0.isEmpty && seen.insert($0).inserted }
}

// Replaces every marker whose question has a non-blank answer. The rest stay for the user to see.
func fill(_ text: String, answers: [String: String]) -> String {
    let result = NSMutableString(string: text)
    // Back to front, so earlier ranges stay valid.
    for match in confirmMatches(in: text).reversed() {
        guard let answer = answers[match.question]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { continue }
        result.replaceCharacters(in: match.range, with: answer)
    }
    return result as String
}

// The optional Polish pass after filling: smooth the wording, change nothing that matters.
func polishSystemPrompt(sections: [String]) -> String {
    """
    You edit a prompt for an AI agent. Some answers were just pasted into it and may read awkwardly.

    Smooth the wording so it reads naturally. Change nothing else:
    - Keep these section headings, in this order: \(sections.map { $0 + ":" }.joined(separator: " "))
    - Keep every fact, name, number and step.
    - Keep every remaining [CONFIRM: …] exactly as it is.
    - Reply with only the edited prompt: no preamble, no explanation.
    """
}
