import Foundation

// Keeps an MLX model loaded between rewrites, so only the first one waits for the model to load.
// The model lives in a child process (Resources/mlx_worker.py) that the app talks to over its
// stdin and stdout, one JSON object per line:
//
//   to the worker:   {"id", "model", "system", "prompt", "max_tokens", "temp"}   or   {"cancel": id}
//   from the worker: {"id", "text": "more text"} … then {"id", "done": true}   or   {"id", "error": "message"}
//
// No sockets and no server: the worker can only hear from this app, and it exits when the app
// closes its stdin, so it can't outlive the app. It's unloaded after `idleTimeout` without use.
final class WarmRunner {
    let command: [String]
    let environment: [String: String]
    var idleTimeout: TimeInterval
    // Called with true once a model is loaded and false once it's unloaded, on a background queue.
    var onChange: ((Bool) -> Void)?

    private final class Request {
        let id = UUID().uuidString
        let progress: ((String) -> Void)?
        var text = ""
        var replied = false
        var error: Error?
        let finished = DispatchSemaphore(value: 0)
        init(progress: ((String) -> Void)?) { self.progress = progress }
    }

    private let lock = NSLock()          // Guards everything below.
    private let oneAtATime = NSLock()    // The worker answers one request at a time.
    private var process: Process?
    private var input: FileHandle?
    private var lines = Data()
    private var stderrTail = ""
    private var request: Request?
    private var idleTimer: DispatchSourceTimer?
    private var deadline: Date?
    private var announced = false

    init(command: [String], environment: [String: String] = [:], idleTimeout: TimeInterval) {
        self.command = command
        self.environment = environment
        self.idleTimeout = idleTimeout
        // Writing to a worker that just died would otherwise kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    deinit { unload() }

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return process != nil }
    var unloadsAt: Date? { lock.lock(); defer { lock.unlock() }; return deadline }
    var processIdentifier: Int32? { lock.lock(); defer { lock.unlock() }; return process?.processIdentifier }

    // Blocks until the reply is complete; call it off the main thread. `started` gets a function
    // that cancels this request; a cancelled request returns the text written so far.
    // Throws WarmRunnerUnavailable when the worker can't start or dies before replying, so the
    // caller can run the model once instead.
    func generate(model: String, system: String, prompt: String, maxTokens: Int, temperature: Double,
                  timeout: TimeInterval, started: ((@escaping () -> Void) -> Void)? = nil,
                  progress: ((String) -> Void)? = nil) throws -> String {
        oneAtATime.lock()
        defer { oneAtATime.unlock() }
        let request = Request(progress: progress)
        lock.lock()
        idleTimer?.cancel()
        idleTimer = nil
        do { try startIfNeeded() } catch { lock.unlock(); throw error }
        self.request = request
        let handle = input
        lock.unlock()

        let message: [String: Any] = ["id": request.id, "model": model, "system": system, "prompt": prompt,
                                      "max_tokens": maxTokens, "temp": temperature]
        guard send(message, to: handle) else {
            unload()
            throw WarmRunnerUnavailable(reason: "it stopped before taking the request")
        }
        started?({ [weak self] in self?.cancel(request.id) })

        if request.finished.wait(timeout: .now() + timeout) == .timedOut {
            unload()
            throw RewriteError.timedOut
        }
        lock.lock()
        self.request = nil
        let announce = process != nil && !announced && request.error == nil
        if announce { announced = true }
        if process != nil { scheduleUnload() }
        lock.unlock()
        if announce { onChange?(true) }
        if let error = request.error { throw error }
        return request.text
    }

    // Stops the worker and frees the model's memory.
    func unload() {
        lock.lock()
        let worker = process, handle = input, inFlight = request, wasAnnounced = announced
        process = nil
        input = nil
        announced = false
        idleTimer?.cancel()
        idleTimer = nil
        deadline = nil
        let interrupted = inFlight?.error == nil ? inFlight : nil
        interrupted?.error = RewriteError.modelError("The model was unloaded.")
        lock.unlock()
        try? handle?.close()  // End of input: the worker exits on its own.
        if worker?.isRunning == true { worker?.terminate() }  // Also when it's busy generating.
        interrupted?.finished.signal()
        if wasAnnounced { onChange?(false) }
    }

    // MARK: Private; `lock` is held where noted.

    // Lock held.
    private func startIfNeeded() throws {
        if process != nil { return }
        guard let exe = command.first, FileManager.default.isExecutableFile(atPath: exe) else {
            throw WarmRunnerUnavailable(reason: "\(command.first ?? "the worker") wasn't found")
        }
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: exe)
        worker.arguments = Array(command.dropFirst())
        worker.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        worker.standardInput = stdin
        worker.standardOutput = stdout
        worker.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.receivedError(data) }
        }
        worker.terminationHandler = { [weak self] in self?.exited($0) }
        do {
            try worker.run()
        } catch {
            for pipe in [stdout, stderr] { pipe.fileHandleForReading.readabilityHandler = nil }
            throw WarmRunnerUnavailable(reason: error.localizedDescription)
        }
        process = worker
        input = stdin.fileHandleForWriting
        lines = Data()
        stderrTail = ""
    }

    private func send(_ message: [String: Any], to handle: FileHandle?) -> Bool {
        guard let handle, var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do { try handle.write(contentsOf: data) } catch { return false }
        return true
    }

    private func cancel(_ id: String) {
        lock.lock()
        let handle = request?.id == id ? input : nil
        lock.unlock()
        _ = send(["cancel": id], to: handle)
    }

    private func received(_ data: Data) {
        var updates: [(Request, String)] = []
        var finished: [Request] = []
        lock.lock()
        lines.append(data)
        while let end = lines.firstIndex(of: 0x0A) {
            let line = lines[lines.startIndex..<end]
            lines.removeSubrange(lines.startIndex...end)
            guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let current = request, reply["id"] as? String == current.id else { continue }
            current.replied = true
            if let text = reply["text"] as? String {
                current.text += text
                updates.append((current, current.text))
            }
            if let error = reply["error"] as? String {
                current.error = RewriteError.modelError(error)
                finished.append(current)
            } else if reply["done"] != nil {
                finished.append(current)
            }
        }
        lock.unlock()
        // Progress first, so the last update arrives before generate() returns.
        for (request, text) in updates { request.progress?(text) }
        for request in finished { request.finished.signal() }
    }

    private func receivedError(_ data: Data) {
        lock.lock()
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
        lock.unlock()
    }

    private func exited(_ worker: Process) {
        lock.lock()
        guard worker === process else { lock.unlock(); return }  // Already unloaded.
        process = nil
        input = nil
        idleTimer?.cancel()
        idleTimer = nil
        deadline = nil
        let wasAnnounced = announced
        announced = false
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(8).joined(separator: "\n")
        let inFlight = request
        if let inFlight, inFlight.error == nil {
            inFlight.error = inFlight.replied
                ? RewriteError.failed(status: worker.terminationStatus, message: tail)
                : WarmRunnerUnavailable(reason: tail.isEmpty ? "it stopped with exit code \(worker.terminationStatus)" : tail)
        }
        lock.unlock()
        inFlight?.finished.signal()
        if wasAnnounced { onChange?(false) }
    }

    // Lock held.
    private func scheduleUnload() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.unload() }
        timer.resume()
        idleTimer = timer
        deadline = Date().addingTimeInterval(idleTimeout)
    }
}

struct WarmRunnerUnavailable: Error {
    var reason: String
}

// The interpreter a script's "#!" line names, such as ["/usr/bin/python3"] or ["/usr/bin/env", "python3"].
// mlx_lm.generate is a Python script, and its interpreter is the one that has mlx-lm installed.
func interpreter(ofScript path: String) -> [String]? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let head = String(decoding: handle.readData(ofLength: 512), as: UTF8.self)
    guard head.hasPrefix("#!"), let line = head.dropFirst(2).split(separator: "\n").first else { return nil }
    let parts = line.split(separator: " ").map(String.init)
    guard let program = parts.first, FileManager.default.isExecutableFile(atPath: program) else { return nil }
    return parts
}
