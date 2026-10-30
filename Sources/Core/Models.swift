import Foundation

// A model already on this Mac. Found by looking at files only: nothing is downloaded or loaded.
struct LocalModel: Equatable {
    enum Format: Equatable { case mlx, gguf }
    var format: Format
    // A Hugging Face repo id (MLX), or the path of a .gguf file.
    var id: String
    var bytes: Int64

    var name: String { format == .mlx ? (id.split(separator: "/").last.map(String.init) ?? id) : (id as NSString).lastPathComponent }

    // The same model can be on disk as MLX and as GGUF, so the label always says which this is.
    var label: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(name) · \(format == .mlx ? "MLX" : "GGUF") · \(size)"
    }

    func runs(on backend: Backend) -> Bool { format == .mlx ? backend == .mlx : backend != .mlx }

    func isCurrent(in config: BackendConfig) -> Bool {
        runs(on: config.backend) && config.model.trimmingCharacters(in: .whitespaces) == id
    }
}

// Where mlx_lm and huggingface-cli keep downloaded models, following the same variables they do.
func huggingFaceHubDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory()) -> String {
    if let cache = environment["HF_HUB_CACHE"], !cache.isEmpty { return cache }
    if let hfHome = environment["HF_HOME"], !hfHome.isEmpty { return (hfHome as NSString).appendingPathComponent("hub") }
    return "\(home)/.cache/huggingface/hub"
}

// Where GGUF files usually live. Not Desktop, Documents or Downloads: reading those makes macOS ask
// for permission, so the user adds them in settings if they want them searched.
func defaultModelFolders(home: String = NSHomeDirectory()) -> [String] {
    ["\(home)/.lmstudio/models", "\(home)/.cache/lm-studio/models", "\(home)/models", "\(home)/llama.cpp/models"]
}

// Every folder to search for GGUF files: the usual ones, the user's own, and the folder of the GGUF
// in use, so models next to it show up too.
func modelSearchFolders(current config: BackendConfig, extra: [String], home: String = NSHomeDirectory()) -> [String] {
    var folders = defaultModelFolders(home: home) + extra
    let model = config.model.trimmingCharacters(in: .whitespaces)
    if config.backend != .mlx, !model.isEmpty {
        folders.append(((model as NSString).expandingTildeInPath as NSString).deletingLastPathComponent)
    }
    return folders
}

// Vocab-only GGUFs (test fixtures that ship with llama.cpp) are a few MB; real models are far bigger.
let minGGUFModelBytes: Int64 = 50_000_000

// MLX models in the Hugging Face cache first, then GGUF files in the cache, then GGUF files in
// `folders` (searched three levels deep). A file reached two ways is listed once.
func localModels(hubDir: String = huggingFaceHubDir(), folders: [String],
                 minGGUFBytes: Int64 = minGGUFModelBytes) -> [LocalModel] {
    var models: [LocalModel] = [], seen = Set<String>()
    func add(_ model: LocalModel) {
        let key = model.format == .mlx ? "mlx:" + model.id : (model.id as NSString).resolvingSymlinksInPath
        if seen.insert(key).inserted { models.append(model) }
    }
    let repos = ((try? FileManager.default.contentsOfDirectory(atPath: hubDir)) ?? []).filter { $0.hasPrefix("models--") }.sorted()
    var hubGGUF: [String] = []
    for repo in repos {
        let snapshots = (hubDir as NSString).appendingPathComponent("\(repo)/snapshots")
        let id = String(repo.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
        if let bytes = mlxWeightBytes(inRepo: snapshots) { add(LocalModel(format: .mlx, id: id, bytes: bytes)) }
        hubGGUF += ggufFiles(in: snapshots, depth: 3, minBytes: minGGUFBytes)
    }
    for path in hubGGUF.sorted() { add(LocalModel(format: .gguf, id: path, bytes: fileSize(path))) }
    for folder in folders {
        let standard = (folder as NSString).standardizingPath
        for path in ggufFiles(in: standard, depth: 3, minBytes: minGGUFBytes).sorted() {
            add(LocalModel(format: .gguf, id: path, bytes: fileSize(path)))
        }
    }
    return models
}

// nil when the configured model is on disk, otherwise the error to show. Checked before running, so
// a deleted model says so instead of failing deep inside the runner.
func missingModel(_ config: BackendConfig, hubDir: String = huggingFaceHubDir()) -> RewriteError? {
    let model = config.model.trimmingCharacters(in: .whitespaces)
    guard config.backend.needsModel || !model.isEmpty else { return nil }
    guard !model.isEmpty else { return .modelNotSet }
    let path = (model as NSString).expandingTildeInPath
    var isFolder: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
    switch config.backend {
    case .mlx:
        // mlx_lm takes a folder on disk as well as a repo id.
        if exists && isFolder.boolValue { return nil }
        let repo = "models--" + model.replacingOccurrences(of: "/", with: "--")
        return mlxWeightBytes(inRepo: (hubDir as NSString).appendingPathComponent("\(repo)/snapshots")) == nil ? .modelMissing(model) : nil
    case .llamafile, .llamaCpp:
        return exists && !isFolder.boolValue ? nil : .modelMissing(model)
    }
}

extension BackendConfig {
    // This config with `model` in place of the current one, on a runner that can use it. Everything
    // else (tokens, temperature, instructions) stays.
    func choosing(_ model: LocalModel, searchDirs: [String] = standardSearchDirs()) -> BackendConfig {
        var config = self
        config.model = model.id
        if !model.runs(on: backend) {
            switch model.format {
            case .mlx: config.backend = .mlx
            case .gguf:
                let hasLlamaCpp = findExecutable(named: Backend.llamaCpp.executableName, in: searchDirs) != nil
                let hasLlamafile = findExecutable(named: Backend.llamafile.executableName, in: searchDirs) != nil
                config.backend = !hasLlamaCpp && hasLlamafile ? .llamafile : .llamaCpp
            }
            // A runner path belongs to its runner.
            config.executable = nil
        }
        return config
    }
}

// The size of the MLX weights in the first snapshot that has a config and model weights (not just
// a LoRA adapter), or nil if none has.
private func mlxWeightBytes(inRepo snapshots: String) -> Int64? {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? []).sorted()
    for name in names {
        let snapshot = (snapshots as NSString).appendingPathComponent(name)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: snapshot)) ?? []
        let weights = files.filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix("adapter") }
        guard files.contains("config.json"), !weights.isEmpty else { continue }
        return weights.reduce(0) { $0 + fileSize((snapshot as NSString).appendingPathComponent($1)) }
    }
    return nil
}

private func ggufFiles(in folder: String, depth: Int, minBytes: Int64) -> [String] {
    // Relative paths, joined to the folder as given, so each path matches what the user typed or saw.
    guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
    var found: [String] = []
    for case let relative as String in walker {
        let name = (relative as NSString).lastPathComponent
        // Hidden folders and app bundles hold nothing worth listing, and can be large.
        if name.hasPrefix(".") || name.hasSuffix(".app") || walker.level >= depth {
            walker.skipDescendants()
            if name.hasPrefix(".") { continue }
        }
        guard name.lowercased().hasSuffix(".gguf"), !name.lowercased().hasPrefix("mmproj") else { continue }
        let path = (folder as NSString).appendingPathComponent(relative)
        if fileSize(path) >= minBytes { found.append(path) }
    }
    return found
}

// Follows symlinks: the Hugging Face cache links each snapshot file to a blob.
private func fileSize(_ path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

// Seconds to run each of `models` once, one after another, as a range. Scaled from a 3B model at
// 4 bits (about 2 GB): about 10 s to load and 7 to 15 s to write a prompt. Rough by design; it's
// shown so nobody starts a five-minute comparison by surprise.
func estimatedSeconds(for models: [LocalModel]) -> ClosedRange<Int> {
    let scales = models.map { Double($0.bytes) / 2_000_000_000 }
    let low = scales.reduce(0) { $0 + 17 * $1 }, high = scales.reduce(0) { $0 + 25 * $1 }
    return Int(low.rounded())...Int(high.rounded())
}

// Whether a model leaves room for macOS and the app the text came from: at most 60% of memory.
func fitsInMemory(_ model: LocalModel, memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
    Double(model.bytes) <= Double(memory) * 0.6
}
