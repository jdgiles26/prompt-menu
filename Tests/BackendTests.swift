import Foundation

func testMLXInvocation() throws {
    let dir = try makeTempFolder()
    let exe = try makeScript("mlx_lm.generate", in: dir, "")
    let config = BackendConfig(backend: .mlx, model: "mlx-community/Some-Model-4bit", maxTokens: 512, temperature: 0.2)
    let inv = try invocation(for: config, input: "fix the bug", searchDirs: [dir])
    checkEqual(inv.executable, exe)
    checkEqual(inv.arguments, [
        "--model", "mlx-community/Some-Model-4bit",
        "--system-prompt", agentSystemPrompt,
        "--prompt", "fix the bug",
        "--max-tokens", "512",
        "--temp", "0.2",
        // Verbose makes mlx_lm.generate print tokens as they come; cleanOutput drops its stats.
        "--verbose", "True",
    ])
    // Never reach for Hugging Face: the model must already be on disk.
    checkEqual(inv.environment["HF_HUB_OFFLINE"], "1")
    checkEqual(inv.environment["TRANSFORMERS_OFFLINE"], "1")
    // Python buffers stdout into a pipe, which would hold back the streamed tokens.
    checkEqual(inv.environment["PYTHONUNBUFFERED"], "1")
}

func testCustomSystemPrompt() throws {
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, "")
    try makeScript("llamafile", in: dir, "")
    try makeScript("llama-completion", in: dir, "")
    for backend in Backend.allCases {
        let config = BackendConfig(backend: backend, model: "m", systemPrompt: "Be brief.")
        let args = try invocation(for: config, input: "fix it", searchDirs: [dir]).arguments
        check(args.contains("Be brief.") || args.contains(combinedPrompt("fix it", systemPrompt: "Be brief.")),
              "\(backend) ignores the custom system prompt")
        check(!args.contains(where: { $0.contains(agentSystemPrompt) }), "\(backend) still sends the default system prompt")
    }
    checkEqual(combinedPrompt("fix it", systemPrompt: "Be brief."), "Be brief.\n\nText to rewrite:\nfix it")
}

func testLlamafileInvocation() throws {
    let dir = try makeTempFolder()
    let exe = try makeScript("llamafile", in: dir, "")
    // With separate weights.
    var config = BackendConfig(backend: .llamafile, model: "/models/qwen.gguf", maxTokens: 256, temperature: 0.3)
    var inv = try invocation(for: config, input: "fix the bug", searchDirs: [dir])
    // llamafiles are Actually Portable Executables, which the shell starts and posix_spawn can't.
    checkEqual(inv.executable, "/bin/sh")
    checkEqual(inv.arguments, [
        exe, "-m", "/models/qwen.gguf", "--cli",
        "-p", combinedPrompt("fix the bug"),
        "-n", "256", "--temp", "0.3",
    ])
    // A model-bundled .llamafile needs no -m; it's the executable.
    let bundled = try makeScript("Qwen.llamafile", in: dir, "")
    config = BackendConfig(backend: .llamafile, model: "", executable: bundled, maxTokens: 256, temperature: 0.3)
    inv = try invocation(for: config, input: "fix the bug", searchDirs: [])
    checkEqual(inv.arguments, [bundled, "--cli", "-p", combinedPrompt("fix the bug"), "-n", "256", "--temp", "0.3"])
    check(combinedPrompt("fix the bug").hasPrefix(agentSystemPrompt), "the combined prompt starts with the instructions")
    check(combinedPrompt("fix the bug").hasSuffix("fix the bug"), "the combined prompt ends with the text")
}

func testLlamaCppInvocation() throws {
    let dir = try makeTempFolder()
    let exe = try makeScript("llama-completion", in: dir, "")
    let config = BackendConfig(backend: .llamaCpp, model: "/models/qwen.gguf", maxTokens: 300, temperature: 0.5)
    let inv = try invocation(for: config, input: "fix the bug", searchDirs: [dir])
    checkEqual(inv.executable, exe)
    checkEqual(inv.arguments, [
        "-m", "/models/qwen.gguf",
        "-sys", agentSystemPrompt,
        "-p", "fix the bug",
        "-cnv", "-st", "--no-display-prompt", "--log-disable",
        "-n", "300", "--temp", "0.5",
    ])
}

func testFindExecutable() throws {
    let first = try makeTempFolder(), second = try makeTempFolder()
    let exe = try makeScript("llamafile", in: second, "")
    // A file that isn't executable doesn't count.
    try "".write(toFile: (first as NSString).appendingPathComponent("llamafile"), atomically: true, encoding: .utf8)
    checkEqual(findExecutable(named: "llamafile", in: [first, second]), exe)
    checkEqual(findExecutable(named: "llamafile", in: [first]), nil)
    checkEqual(findExecutable(named: "nope", in: [first, second]), nil)
    // Apps opened from the Dock get a bare PATH, so the usual install folders are searched too.
    let dirs = standardSearchDirs(home: "/Users/test", path: "/usr/bin:/bin")
    for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/Users/test/.local/bin", "/usr/bin"] {
        check(dirs.contains(expected), "search dirs are missing \(expected)")
    }
}

func testMissingRunnerOrModel() throws {
    let empty = try makeTempFolder()
    checkThrows(.executableNotFound("mlx_lm.generate")) {
        _ = try invocation(for: BackendConfig(backend: .mlx, model: "m"), input: "x", searchDirs: [empty])
    }
    // An explicit path that doesn't exist is reported as is.
    checkThrows(.executableNotFound("/nowhere/llamafile")) {
        _ = try invocation(for: BackendConfig(backend: .llamafile, model: "", executable: "/nowhere/llamafile"), input: "x", searchDirs: [])
    }
    let dir = try makeTempFolder()
    try makeScript("mlx_lm.generate", in: dir, "")
    try makeScript("llama-completion", in: dir, "")
    checkThrows(.modelNotSet) { _ = try invocation(for: BackendConfig(backend: .mlx, model: " "), input: "x", searchDirs: [dir]) }
    checkThrows(.modelNotSet) { _ = try invocation(for: BackendConfig(backend: .llamaCpp, model: ""), input: "x", searchDirs: [dir]) }
}

func testSettings() throws {
    let suite = "PromptMenuTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "no defaults suite") }
    defer { defaults.removePersistentDomain(forName: suite) }
    // Keeping the model loaded: 5 minutes unless changed, 0 turns it off, clamped to 0…120.
    checkEqual(keepLoadedMinutes(from: defaults), 5)
    saveKeepLoadedMinutes(0, to: defaults)
    checkEqual(keepLoadedMinutes(from: defaults), 0)
    saveKeepLoadedMinutes(500, to: defaults)
    checkEqual(keepLoadedMinutes(from: defaults), keepLoadedRange.upperBound)
    // Nothing saved: MLX with a small instruct model.
    var config = loadConfig(from: defaults)
    checkEqual(config.backend, .mlx)
    checkEqual(config.model, defaultMLXModel)
    checkEqual(config.executable, nil)
    // Saved values come back.
    saveConfig(BackendConfig(backend: .llamafile, model: "/m.gguf", executable: "/bin/llamafile", maxTokens: 99, temperature: 0.9), to: defaults)
    config = loadConfig(from: defaults)
    checkEqual(config, BackendConfig(backend: .llamafile, model: "/m.gguf", executable: "/bin/llamafile", maxTokens: 99, temperature: 0.9))
    // An unknown backend name falls back to MLX; an empty path means "search for it".
    defaults.set("gpt-cloud", forKey: "backend")
    defaults.set("", forKey: "executable")
    config = loadConfig(from: defaults)
    checkEqual(config.backend, .mlx)
    checkEqual(config.executable, nil)
    // Out-of-range numbers are clamped; an empty system prompt means the built-in one.
    defaults.set(1_000_000, forKey: "maxTokens")
    defaults.set(-3.0, forKey: "temperature")
    defaults.set("  ", forKey: "systemPrompt")
    config = loadConfig(from: defaults)
    checkEqual(config.maxTokens, maxTokensRange.upperBound)
    checkEqual(config.temperature, 0)
    checkEqual(config.systemPrompt, agentSystemPrompt)
    defaults.set(1, forKey: "maxTokens")
    defaults.set("Be brief.", forKey: "systemPrompt")
    config = loadConfig(from: defaults)
    checkEqual(config.maxTokens, maxTokensRange.lowerBound)
    checkEqual(config.systemPrompt, "Be brief.")
    // The built-in prompt isn't saved, so improving it reaches everyone who didn't change it.
    saveConfig(BackendConfig(backend: .mlx, model: "m"), to: defaults)
    checkEqual(defaults.string(forKey: "systemPrompt"), "")
}
