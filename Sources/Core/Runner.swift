import Foundation

// Runs the invocation and returns what it printed. stderr only matters when it fails.
// `started` gets the process, so the caller can stop it early; `output` gets everything printed
// so far, each time more arrives.
func run(_ inv: Invocation, timeout: TimeInterval, started: ((Process) -> Void)? = nil,
         output: ((String) -> Void)? = nil) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: inv.executable) else {
        throw RewriteError.executableNotFound(inv.executable)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: inv.executable)
    process.arguments = inv.arguments
    process.environment = ProcessInfo.processInfo.environment.merging(inv.environment) { $1 }
    process.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err

    // Read both pipes while it runs: a runner that fills one pipe's buffer would otherwise block
    // forever waiting for us. Handlers run on background queues, hence the lock.
    let lock = NSLock()
    var stdout = Data(), stderr = Data()
    let reads = DispatchGroup()
    for (pipe, isOut) in [(out, true), (err, false)] {
        reads.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { // End of file.
                handle.readabilityHandler = nil
                reads.leave()
                return
            }
            lock.lock()
            if isOut { stdout.append(chunk) } else { stderr.append(chunk) }
            let soFar = isOut && output != nil ? String(decoding: stdout, as: UTF8.self) : nil
            lock.unlock()
            if let soFar { output?(soFar) }
        }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        for pipe in [out, err] { pipe.fileHandleForReading.readabilityHandler = nil }
        throw RewriteError.executableNotFound(inv.executable)
    }
    started?(process)

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        _ = reads.wait(timeout: .now() + 1)
        throw RewriteError.timedOut
    }
    // A child the runner left behind can hold the pipes open; don't wait on it for long.
    _ = reads.wait(timeout: .now() + 2)
    for pipe in [out, err] { pipe.fileHandleForReading.readabilityHandler = nil }

    lock.lock()
    defer { lock.unlock() }
    guard process.terminationStatus == 0 else {
        let message = String(decoding: stderr, as: UTF8.self)
        // The end of stderr says what went wrong; the start is usually warnings and progress bars.
        let tail = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(8)
        throw RewriteError.failed(status: process.terminationStatus, message: tail.joined(separator: "\n"))
    }
    return String(decoding: stdout, as: UTF8.self)
}

// Highlighted text in, agentic prompt out. Blocks while the model runs, so call it off the main thread.
// `progress` gets the cleaned reply so far while it streams, on a background queue.
func rewrite(_ text: String, config: BackendConfig, searchDirs: [String] = standardSearchDirs(),
             timeout: TimeInterval = 300, started: ((Process) -> Void)? = nil,
             progress: ((String) -> Void)? = nil) throws -> String {
    let input = try prepareInput(text)
    let inv = try invocation(for: config, input: input, searchDirs: searchDirs)
    var lastShown = ""
    let raw = try run(inv, timeout: timeout, started: started, output: progress.map { progress in
        { soFar in
            let cleaned = cleanOutput(soFar)
            // Chunks arrive one at a time per pipe, so lastShown isn't shared between threads.
            guard !cleaned.isEmpty, cleaned != lastShown else { return }
            lastShown = cleaned
            progress(cleaned)
        }
    })
    let output = cleanOutput(raw)
    guard !output.isEmpty else { throw RewriteError.emptyOutput }
    return output
}
