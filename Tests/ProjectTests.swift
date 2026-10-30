import Foundation

// FEATURE_FUTURE §5: headings and commands from a project's own docs, added to the draft's input.
func testProjectContext() throws {
    let folder = (try makeTempFolder() as NSString).appendingPathComponent("my-app")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try """
    # My App
    Some prose that isn't kept.
    ## Commands
    ```sh
    npm test          # must pass
    npm run build
    ```
    $ make lint
    ### Hard rules
    """.write(toFile: folder + "/AGENTS.md", atomically: true, encoding: .utf8)
    try "@AGENTS.md\n".write(toFile: folder + "/CLAUDE.md", atomically: true, encoding: .utf8)
    try "# My App\n```\nnpm test\n```\n".write(toFile: folder + "/README.md", atomically: true, encoding: .utf8)

    guard let context = projectContext(folder: folder) else { throw TestFailure(description: "no context found") }
    checkEqual(context, """
    Project "my-app" (from its AGENTS.md, CLAUDE.md, README.md):
    Sections: My App · Commands · Hard rules
    Commands:
    - npm test          # must pass
    - npm run build
    - make lint
    - npm test
    """)
    // A folder with none of the files adds nothing.
    checkEqual(projectContext(folder: try makeTempFolder()), nil)

    // The highlighted text comes first and keeps its place; the context is cut to fit, never the text.
    let combined = withProjectContext("fix the bug", context: context)
    check(combined.hasPrefix("fix the bug\n\n"), "text first")
    check(combined.contains("Project facts, from the project's own files:\n" + context), "context follows")
    let long = String(repeating: "x", count: maxInputCharacters - 100)
    let cut = withProjectContext(long, context: context)
    check(cut.hasPrefix(long), "the text is kept whole")
    check(cut.count <= maxInputCharacters, "fits the input limit: \(cut.count)")
    // No room at all: just the text.
    checkEqual(withProjectContext(String(repeating: "y", count: maxInputCharacters), context: context), String(repeating: "y", count: maxInputCharacters))
}
