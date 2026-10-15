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
