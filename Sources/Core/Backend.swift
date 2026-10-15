import Foundation

// Each backend is a command-line program run once per rewrite. Prompt Menu has no network code:
// no local server, no HTTP. Each model loads, answers and exits.
enum Backend: String, CaseIterable {
    case mlx                      // Apple's MLX, through mlx-lm (pip install mlx-lm)
    case llamafile                // Mozilla.ai's llamafile 0.10 or later
    case llamaCpp = "llama.cpp"   // llama.cpp's one-shot runner (brew install llama.cpp)

    var displayName: String {
        switch self {
        case .mlx: return "MLX (mlx-lm)"
        case .llamafile: return "llamafile"
        case .llamaCpp: return "llama.cpp"
        }
    }

    var executableName: String {
        switch self {
        case .mlx: return "mlx_lm.generate"
        case .llamafile: return "llamafile"
        case .llamaCpp: return "llama-completion"
        }
    }

    // A model-bundled .llamafile carries its own weights.
    var needsModel: Bool { self != .llamafile }
}

struct BackendConfig: Equatable {
    var backend: Backend
    // A Hugging Face repo id already downloaded (MLX), or a .gguf path (llamafile, llama.cpp).
    var model: String
    // A full path to the runner; nil means search for it.
    var executable: String? = nil
    var maxTokens = 1024
    var temperature = 0.3
    // What the model is told to do; agentSystemPrompt unless the user changed it.
    var systemPrompt = agentSystemPrompt
}

// One run of a model runner.
struct Invocation: Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
}

func invocation(for config: BackendConfig, input: String, searchDirs: [String]) throws -> Invocation {
    let exe: String
    if let path = config.executable {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw RewriteError.executableNotFound(path) }
        exe = path
    } else {
        guard let found = findExecutable(named: config.backend.executableName, in: searchDirs) else {
            throw RewriteError.executableNotFound(config.backend.executableName)
        }
        exe = found
    }
    let model = config.model.trimmingCharacters(in: .whitespaces)
    if config.backend.needsModel && model.isEmpty { throw RewriteError.modelNotSet }
    let tokens = String(config.maxTokens), temp = String(config.temperature)

    switch config.backend {
    case .mlx:
        return Invocation(executable: exe, arguments: [
            "--model", model,
            "--system-prompt", config.systemPrompt,
            "--prompt", input,
            "--max-tokens", tokens,
            "--temp", temp,
            // Prints tokens as they come (between "==========" lines, then stats); cleanOutput drops the rest.
            "--verbose", "True",
        ], environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONUNBUFFERED": "1"])
    case .llamafile:
        // llamafiles are Actually Portable Executables: a shell script header that posix_spawn
        // refuses, so let the shell start them, as running one from Terminal does.
        var args = [exe]
        if !model.isEmpty { args += ["-m", model] }
        args += ["--cli", "-p", combinedPrompt(input, systemPrompt: config.systemPrompt), "-n", tokens, "--temp", temp]
        return Invocation(executable: "/bin/sh", arguments: args, environment: [:])
    case .llamaCpp:
        return Invocation(executable: exe, arguments: [
            "-m", model,
            "-sys", config.systemPrompt,
            "-p", input,
            "-cnv", "-st", "--no-display-prompt", "--log-disable",
            "-n", tokens, "--temp", temp,
        ], environment: [:])
    }
}

func findExecutable(named name: String, in dirs: [String]) -> String? {
    dirs.lazy
        .map { ($0 as NSString).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// Apps opened from the Dock or by the Services menu get launchd's bare PATH, so also look where
// Homebrew, pip and pipx put programs.
func standardSearchDirs(home: String = NSHomeDirectory(),
                        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [String] {
    var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
    // pip install --user puts scripts under each Python version.
    let pythons = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Python")) ?? []
    dirs += pythons.sorted(by: >).map { "\(home)/Library/Python/\($0)/bin" }
    dirs += path.split(separator: ":").map(String.init)
    var seen = Set<String>()
    return dirs.filter { seen.insert($0).inserted }
}
