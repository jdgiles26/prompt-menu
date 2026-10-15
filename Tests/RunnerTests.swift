import Foundation

func testRunCapturesOutput() throws {
    let dir = try makeTempFolder()
    // Echoes its arguments and an environment variable; writes noise to stderr, which is ignored.
    let exe = try makeScript("runner", in: dir, #"echo "args: $*"; echo "env: $HF_HUB_OFFLINE"; echo "warning" >&2"#)
    let out = try run(Invocation(executable: exe, arguments: ["a", "b c"], environment: ["HF_HUB_OFFLINE": "1"]), timeout: 10)
    checkEqual(out, "args: a b c\nenv: 1\n")
    // Big outputs on both pipes at once mustn't deadlock.
    let chatty = try makeScript("chatty", in: dir, "i=0; while [ $i -lt 3000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; echo 'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' >&2; i=$((i+1)); done")
    checkEqual(try run(Invocation(executable: chatty, arguments: [], environment: [:]), timeout: 20).count, 3000 * 47)
}

func testRunFailures() throws {
    let dir = try makeTempFolder()
    let failing = try makeScript("failing", in: dir, "echo 'model not found' >&2; exit 3")
    checkThrows(.failed(status: 3, message: "model not found")) {
        _ = try run(Invocation(executable: failing, arguments: [], environment: [:]), timeout: 10)
    }
    checkThrows(.executableNotFound("/nowhere/runner")) {
        _ = try run(Invocation(executable: "/nowhere/runner", arguments: [], environment: [:]), timeout: 10)
    }
}

func testRunTimeout() throws {
    let dir = try makeTempFolder()
    let slow = try makeScript("slow", in: dir, "sleep 30")
    let start = Date()
    checkThrows(.timedOut) { _ = try run(Invocation(executable: slow, arguments: [], environment: [:]), timeout: 1) }
    check(Date().timeIntervalSince(start) < 5, "the timeout should stop the runner promptly")
}

func testRewritePipeline() throws {
    let dir = try makeTempFolder()
    // A fake mlx_lm.generate that answers with the user prompt it got, wrapped in noise.
    try makeScript("mlx_lm.generate", in: dir, #"""
    while [ $# -gt 0 ]; do [ "$1" = "--prompt" ] && p="$2"; shift; done
    printf '<think>hmm</think>\n```\nROLE: agent for %s\n```\n' "$p"
    """#)
    let config = BackendConfig(backend: .mlx, model: "m")
    checkEqual(try rewrite("  fix login  ", config: config, searchDirs: [dir], timeout: 10), "ROLE: agent for fix login")
    checkThrows(.emptyInput) { _ = try rewrite("   ", config: config, searchDirs: [dir], timeout: 10) }
    // A runner that prints nothing useful.
    let quiet = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: quiet, "echo '[end of text]'")
    checkThrows(.emptyOutput) { _ = try rewrite("fix login", config: config, searchDirs: [quiet], timeout: 10) }
}
