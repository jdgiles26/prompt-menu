import Foundation

// A stand-in for Resources/mlx_worker.py that speaks the same protocol. The model name picks how
// it behaves: "crash" exits, "missing" reports an error, "hang" never answers, "slow" ticks.
private let fakeWorker = #"""
import json, sys, threading, time, queue
requests, cancelled = queue.Queue(), set()
def reader():
    for line in sys.stdin:
        msg = json.loads(line)
        if "cancel" in msg: cancelled.add(msg["cancel"])
        else: requests.put(msg)
    requests.put(None)
threading.Thread(target=reader, daemon=True).start()
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
while True:
    r = requests.get()
    if r is None: break
    model = r["model"]
    if model == "crash": sys.exit(3)
    if model == "missing": send({"id": r["id"], "error": "not downloaded"}); continue
    if model == "hang": time.sleep(30)
    words = ["tick "] * 25 if model == "slow" else ["ROLE: ", "agent ", "for ", r["prompt"], " (" + r["system"] + ")"]
    for w in words:
        if r["id"] in cancelled: break
        send({"id": r["id"], "text": w}); time.sleep(0.2 if model == "slow" else 0.02)
    send({"id": r["id"], "done": True})
"""#

private func makeWorker() throws -> WarmRunner {
    let dir = try makeTempFolder()
    let path = (dir as NSString).appendingPathComponent("worker.py")
    try fakeWorker.write(toFile: path, atomically: true, encoding: .utf8)
    return WarmRunner(command: ["/usr/bin/python3", path], idleTimeout: 60)
}

private func ask(_ worker: WarmRunner, model: String = "m", prompt: String = "fix it", timeout: TimeInterval = 10,
                 started: ((@escaping () -> Void) -> Void)? = nil, progress: ((String) -> Void)? = nil) throws -> String {
    try worker.generate(model: model, system: "sys", prompt: prompt, maxTokens: 64, temperature: 0,
                        timeout: timeout, started: started, progress: progress)
}

func testWarmRunnerReusesTheProcess() throws {
    let worker = try makeWorker()
    defer { worker.unload() }
    var updates: [String] = []
    let lock = NSLock()
    checkEqual(try ask(worker, progress: { lock.lock(); updates.append($0); lock.unlock() }), "ROLE: agent for fix it (sys)")
    check(updates.count >= 3 && updates.last == "ROLE: agent for fix it (sys)", "streamed text so far: \(updates)")
    let pid = worker.processIdentifier
    check(worker.isLoaded && pid != nil, "the worker stays running")
    checkEqual(try ask(worker, prompt: "again"), "ROLE: agent for again (sys)")
    checkEqual(worker.processIdentifier, pid)
}

func testWarmRunnerCancelAndErrors() throws {
    let worker = try makeWorker()
    defer { worker.unload() }
    // Cancelling returns what was written so far, quickly, and keeps the worker.
    var stop: (() -> Void)?
    let start = Date()
    let partial = try ask(worker, model: "slow", started: { stop = $0 }, progress: { _ in stop?() })
    check(Date().timeIntervalSince(start) < 2, "cancel took \(Date().timeIntervalSince(start))s")
    check(partial.hasPrefix("tick") && partial.count < 25 * 5, "partial output: \(partial)")
    check(worker.isLoaded, "a cancel keeps the model loaded")
    // The model reports an error: the worker stays.
    checkThrows(.modelError("not downloaded")) { _ = try ask(worker, model: "missing") }
    check(worker.isLoaded, "an error reply keeps the worker")
    // No answer in time: stopped.
    checkThrows(.timedOut) { _ = try ask(worker, model: "hang", timeout: 0.5) }
    check(!worker.isLoaded, "a timed-out worker is stopped")
    // The worker dies before answering: it's unavailable, so the caller can run the model once instead.
    do {
        _ = try ask(worker, model: "crash")
        check(false, "a crashed worker should throw")
    } catch is WarmRunnerUnavailable {
    } catch {
        check(false, "expected WarmRunnerUnavailable, got \(error)")
    }
    let missing = WarmRunner(command: ["/nowhere/python3", "worker.py"], idleTimeout: 60)
    do { _ = try ask(missing); check(false, "no interpreter should throw") } catch is WarmRunnerUnavailable {}
}

func testWarmRunnerUnloads() throws {
    let worker = try makeWorker()
    worker.idleTimeout = 0.5
    var changes: [Bool] = []
    let lock = NSLock()
    worker.onChange = { lock.lock(); changes.append($0); lock.unlock() }
    _ = try ask(worker)
    let pid = worker.processIdentifier ?? 0
    check(worker.unloadsAt != nil, "an idle deadline is set")
    Thread.sleep(forTimeInterval: 1.2)
    check(!worker.isLoaded, "idle for longer than idleTimeout: unloaded")
    check(kill(pid, 0) != 0, "the worker process is gone")
    lock.lock(); checkEqual(changes, [true, false]); lock.unlock()
    // It starts again on the next request.
    checkEqual(try ask(worker), "ROLE: agent for fix it (sys)")
    worker.unload()
    check(!worker.isLoaded, "unload stops it")
}

func testInterpreter() throws {
    let dir = try makeTempFolder()
    let direct = try makeScript("a", in: dir, "")
    try "#!/usr/bin/python3\nimport x\n".write(toFile: direct, atomically: true, encoding: .utf8)
    checkEqual(interpreter(ofScript: direct), ["/usr/bin/python3"])
    try "#!/usr/bin/env python3\n".write(toFile: direct, atomically: true, encoding: .utf8)
    checkEqual(interpreter(ofScript: direct), ["/usr/bin/env", "python3"])
    try "binary".write(toFile: direct, atomically: true, encoding: .utf8)
    checkEqual(interpreter(ofScript: direct), nil)
    checkEqual(interpreter(ofScript: "/nowhere"), nil)
}

// A warm worker that can't start falls back to running the model once, and says so.
func testRewriteFallsBack() throws {
    let dir = try makeTempFolder()
    let exe = try makeScript("mlx_lm.generate", in: dir, "echo 'ROLE: once'")
    let broken = WarmRunner(command: ["/nowhere/python3"], idleTimeout: 60)
    var notices: [String] = []
    let out = try rewrite("fix it", config: BackendConfig(backend: .mlx, model: "m", executable: exe), warm: broken,
                          searchDirs: [], timeout: 10, notice: { notices.append($0) })
    checkEqual(out, "ROLE: once")
    checkEqual(notices.count, 1)
    // And a working one is used instead of the one-shot program.
    let worker = try makeWorker()
    defer { worker.unload() }
    checkEqual(try rewrite("fix it", config: BackendConfig(backend: .mlx, model: "m", executable: exe, systemPrompt: "S"),
                           warm: worker, searchDirs: [], timeout: 10), "ROLE: agent for fix it (S)")
}
