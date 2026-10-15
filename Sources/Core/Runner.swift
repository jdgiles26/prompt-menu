import Foundation

// Runs the invocation and returns what it printed. stderr only matters when it fails.
// `started` gets the process, so the caller can stop it early.
func run(_ inv: Invocation, timeout: TimeInterval, started: ((Process) -> Void)? = nil) throws -> String {
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

    // Read both pipes while it runs: a runner that fills one pipe's buffer would otherwise
    // block forever waiting for us.
    var stdout = Data(), stderr = Data()
    let reads = DispatchGroup()
    for (pipe, isOut) in [(out, true), (err, false)] {
        reads.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if isOut { stdout = data } else { stderr = data }
            reads.leave()
        }
    }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
        try process.run()
    } catch {
        throw RewriteError.executableNotFound(inv.executable)
    }
    started?(process)

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        // Children (llamafile runs under /bin/sh) keep the pipes open; give up on them shortly.
        if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        _ = reads.wait(timeout: .now() + 1)
        throw RewriteError.timedOut
    }
    reads.wait()

    guard process.terminationStatus == 0 else {
        let message = String(decoding: stderr, as: UTF8.self)
        // The end of stderr says what went wrong; the start is usually warnings and progress bars.
        let tail = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(8)
        throw RewriteError.failed(status: process.terminationStatus, message: tail.joined(separator: "\n"))
    }
    return String(decoding: stdout, as: UTF8.self)
}

// Highlighted text in, agentic prompt out. Blocks while the model runs, so call it off the main thread.
func rewrite(_ text: String, config: BackendConfig, searchDirs: [String] = standardSearchDirs(),
             timeout: TimeInterval = 300, started: ((Process) -> Void)? = nil) throws -> String {
    let input = try prepareInput(text)
    let output = cleanOutput(try run(invocation(for: config, input: input, searchDirs: searchDirs), timeout: timeout, started: started))
    guard !output.isEmpty else { throw RewriteError.emptyOutput }
    return output
}
