import Foundation

// A small test runner, so the tests build with plain swiftc like the app (no Xcode project, and
// XCTest isn't part of the Command Line Tools). scripts/test.sh compiles this folder together with
// Sources/Core and runs it from the repository root. Adapted from Finder Menu's runner.

var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
    guard !condition else { return }
    failures += 1
    print("  FAIL \(file):\(line): \(message())")
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) {
    check(actual == expected, "got \(actual), expected \(expected)", file: file, line: line)
}

// Checks that `body` throws exactly `expected`.
func checkThrows(_ expected: RewriteError, file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "expected \(expected), nothing was thrown", file: file, line: line)
    } catch let error as RewriteError {
        checkEqual(error, expected, file: file, line: line)
    } catch {
        check(false, "expected \(expected), got \(error)", file: file, line: line)
    }
}

// Thrown to stop a test that can't go on.
struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

// A new empty folder, deleted when the run ends.
private var tempFolders: [String] = []
func makeTempFolder() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("PromptMenuTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    tempFolders.append(path)
    return (path as NSString).standardizingPath
}

// An executable shell script named `name` in `folder`, standing in for a model runner.
@discardableResult
func makeScript(_ name: String, in folder: String, _ body: String) throws -> String {
    let path = (folder as NSString).appendingPathComponent(name)
    try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

let tests: [(name: String, run: () throws -> Void)] = [
    ("system prompt", testSystemPrompt),
    ("input preparation", testPrepareInput),
    ("long input", testLongInput),
    ("MLX command", testMLXInvocation),
    ("llamafile command", testLlamafileInvocation),
    ("llama.cpp command", testLlamaCppInvocation),
    ("finding runners", testFindExecutable),
    ("missing runner or model", testMissingRunnerOrModel),
    ("output cleanup", testCleanOutput),
    ("running a runner", testRunCapturesOutput),
    ("runner failures", testRunFailures),
    ("runner timeout", testRunTimeout),
    ("whole rewrite", testRewritePipeline),
    ("streaming", testStreaming),
    ("runner child keeps pipe open", testRunnerChildKeepsPipeOpen),
    ("custom system prompt", testCustomSystemPrompt),
    ("no network code", testNoNetworkCode),
    ("no entitlements", testNoEntitlementsOrPermissions),
    ("docs cover every runner", testDocsCoverEveryRunner),
    ("settings", testSettings),
    ("Services entry", testServicesEntry),
    ("styles", testStyles),
    ("explain style", testExplainStyle),
    ("explain: Finder files", testExplainFileInput),
    ("checker: explain", testCheckerExplain),
    ("chat: instructions", testChatSystemPrompt),
    ("chat: context and trimming", testChatContext),
    ("chat: round trip", testChatRoundTrip),
    ("chat: non-answers", testChatNonAnswer),
    ("chat: fallback", testChatFallback),
    ("chat: no fallback once stopped", testChatFallbackStopped),
    ("chat: repeated answer", testChatRepeatedAnswer),
    ("chat: short repeat is an answer", testChatShortRepeatIsAnAnswer),
    ("chat: llamafile label", testChatLlamafileLabel),
    ("checker: good prompt", testCheckerScoresAGoodPrompt),
    ("checker: problems", testCheckerFindsProblems),
    ("checker: commit message", testCheckerCommitMessage),
    ("checker: repeated headings", testCheckerRepeatedHeadings),
    ("patterns catalog", testPatternsCatalog),
    ("pattern shortlist", testPatternShortlist),
    ("pattern choice", testPatternChoice),
    ("warm model: reuse", testWarmRunnerReusesTheProcess),
    ("warm model: cancel and errors", testWarmRunnerCancelAndErrors),
    ("warm model: unload", testWarmRunnerUnloads),
    ("python interpreter", testInterpreter),
    ("warm model fallback", testRewriteFallsBack),
    ("finding local models", testLocalModels),
    ("model on disk", testModelOnDisk),
    ("choosing a model", testChoosingAModel),
    ("model search folders", testModelSearchFolders),
    ("compare: estimate", testCompareEstimate),
    ("project context", testProjectContext),
    ("fill gaps: questions", testConfirmQuestions),
    ("fill gaps: answers", testFillAnswers),
    ("fill gaps: polish prompt", testPolishPrompt),
    ("review: jury prompt and votes", testJuryPromptAndVotes),
    ("review: shuffle", testJuryShuffle),
    ("review: bias controls", testJuryBiasControls),
    ("review: winner", testJuryWinner),
    ("review: harden reply", testHardenReply),
    ("review: harden preamble", testHardenPreamble),
    ("review: harden verdict", testHardenVerdict),
    ("review: state machine", testReviewStateMachine),
    ("review: line diff", testLineDiff),
    ("review: pipeline", testReviewPipeline),
    ("review: one model and stop", testReviewPipelineSingleModelAndStop),
    ("review: estimate", testReviewEstimate),
    ("review: position bias", testReviewPositionBias),
    ("explain: protected file", testExplainProtectedFile),
    ("explain: empty file", testExplainEmptyFile),
    ("explain: UTF-16 file", testExplainUTF16File),
    ("explain: folder", testExplainFolder),
    ("explain: folder edges", testExplainFolderEdges),
    ("explain: no extension", testExplainFileWithoutExtension),
    ("explain: database", testExplainDatabase),
    ("explain: any file", testExplainAnyFile),
    ("explain: mixed selection", testExplainMixedSelection),
    ("hardening: stated limits", testStatedLimitsReachConstraints),
    ("hardening: invented limits", testInventedLimitsAreDropped),
    ("hardening: bullets", testConstraintsAndDoneWhenAreBullets),
    ("hardening: invented names", testInventedNamesAreQuestioned),
    ("hardening: phase details vs gate", testPhaseDetailsMatchTheirGate),
    ("hardening: commit message", testCommitMessageCleanup),
    ("hardening: bug report scope", testBugReportChecksScope),
    ("hardening: echoed instructions", testEchoedInstructionsAreRemoved),
    ("hardening: out of memory", testOutOfMemoryMessage),
    ("explain: reading time limit", testExplainReadingHasATimeLimit),
    ("explain: text in an image", testExplainImageText),
    ("hardening: second real run", testSecondRunRepairs),
    ("chat: edits become a version", testChatEditMergesSections),
    ("send to agent: defaults", testHarnessDefaults),
    ("send to agent: harnesses.json", testHarnessFile),
    ("send to agent: detection", testHarnessDetection),
    ("send to agent: Terminal script", testHarnessTerminalScript),
    ("send to agent: copy command", testHarnessCopyCommand),
    ("send to agent: recent folders", testRecentAgentFolders),
    ("pattern pick from all 203", testTwoStagePatternPick),
    ("pattern shortlist: feature work", testShortlistForFeatureWork),
    ("workflow: phase details aren't code", testPhaseDetailsAreNotCode),
    ("explain: bullets on their own lines", testExplanationBulletsOnTheirOwnLines),
    ("hardening: demo repairs", testDemoRepairs),
    ("launch: settings only when opened directly", testLaunchShowsSettingsOnlyWhenOpenedDirectly),
    ("service failures reach the user", testServiceFailuresReachTheUser),
    ("check: workflow gaps", testCheckerWorkflowGaps),
    ("shortlist by task type", testPatternShortlistByTaskType),
    ("workflow: every pattern has one", testEveryPatternHasAWorkflow),
    ("workflow: model fills the phases", testWorkflowUsesTheModelsDetails),
    ("workflow: details after an echo", testWorkflowKeepsDetailsAfterAnEcho),
    ("workflow: restated phases", testWorkflowRestatedPhases),
    ("workflow: survives a useless model", testWorkflowSurvivesAUselessModel),
    ("workflow: applying twice", testWorkflowAppliedTwice),
    ("workflow: draft hardening", testDraftHardening),
    ("workflow: which outputs are hardened", testFinishedPrompt),
]

for test in tests {
    let before = failures
    do {
        try test.run()
    } catch {
        failures += 1
        print("  FAIL \(error)")
    }
    print(failures == before ? "ok      \(test.name)" : "FAILED  \(test.name)")
}
for path in tempFolders { try? FileManager.default.removeItem(atPath: path) }

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
