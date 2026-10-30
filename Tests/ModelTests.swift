import Foundation

// A Hugging Face cache entry like the ones `mlx_lm.generate` and `huggingface-cli download` leave:
// models--<org>--<name>/snapshots/<hash>/ with the given files. Each file holds `bytes` bytes.
@discardableResult
func makeHubModel(_ repo: String, in hub: String, files: [String], bytes: Int = 10) throws -> String {
    let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
    let snapshot = ((hub as NSString).appendingPathComponent(folder) as NSString).appendingPathComponent("snapshots/abc123")
    try FileManager.default.createDirectory(atPath: snapshot, withIntermediateDirectories: true)
    for file in files { try makeFile((snapshot as NSString).appendingPathComponent(file), bytes: bytes) }
    return snapshot
}

func makeFile(_ path: String, bytes: Int) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(count: bytes).write(to: URL(fileURLWithPath: path))
}

// The bug this fixes: the default model had been deleted from the cache, every rewrite failed, and
// nothing offered the models that were on the Mac.
func testLocalModels() throws {
    let hub = try makeTempFolder(), folder = try makeTempFolder()
    try makeHubModel("mlx-community/gemma-4-12b-it-4bit", in: hub, files: ["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
    // Not runnable as a model: a LoRA adapter, a Whisper model, a repo with only a README.
    try makeHubModel("someone/qwen-adapter", in: hub, files: ["adapter_config.json", "adapter_model.safetensors"])
    try makeHubModel("Systran/faster-whisper-base", in: hub, files: ["config.json", "model.bin"])
    try makeHubModel("someone/empty", in: hub, files: ["README.md"])
    // A GGUF in the cache, a vocab-only GGUF (tiny), and a vision projector, which isn't a model on its own.
    try makeHubModel("unsloth/gemma-4-12B-it-GGUF", in: hub, files: ["gemma-4-12b-it-Q4_K_M.gguf", "mmproj-F16.gguf"], bytes: 2000)
    try makeFile((folder as NSString).appendingPathComponent("qwen2.5-3b-instruct-q4_k_m.gguf"), bytes: 2000)
    try makeFile((folder as NSString).appendingPathComponent("vocab/ggml-vocab-llama.gguf"), bytes: 10)
    try makeFile((folder as NSString).appendingPathComponent(".hidden/secret.gguf"), bytes: 2000)

    let models = localModels(hubDir: hub, folders: [folder, "/no/such/folder"], minGGUFBytes: 1000)
    let cachedGGUF = (try makeHubModel("unsloth/gemma-4-12B-it-GGUF", in: hub, files: []) as NSString).appendingPathComponent("gemma-4-12b-it-Q4_K_M.gguf")
    checkEqual(models.map(\.id), [
        "mlx-community/gemma-4-12b-it-4bit",
        cachedGGUF,
        (folder as NSString).appendingPathComponent("qwen2.5-3b-instruct-q4_k_m.gguf"),
    ])
    checkEqual(models.map(\.format), [.mlx, .gguf, .gguf])
    guard models.count == 3 else { throw TestFailure(description: "expected 3 models, found \(models.map(\.id))") }
    // The same model as MLX and as GGUF shows twice; the label says which is which.
    checkEqual(models[0].name, "gemma-4-12b-it-4bit")
    checkEqual(models[1].name, "gemma-4-12b-it-Q4_K_M.gguf")
    check(models[0].label.contains("MLX"), "MLX label: \(models[0].label)")
    check(models[1].label.contains("GGUF"), "GGUF label: \(models[1].label)")
    checkEqual(models[0].bytes, 20)
    // A folder listed twice, or a GGUF reached two ways, still shows once.
    checkEqual(localModels(hubDir: hub, folders: [folder, folder + "/"], minGGUFBytes: 1000).count, 3)
    // Nothing there: an empty list, not a crash.
    checkEqual(localModels(hubDir: "/no/such/hub", folders: [], minGGUFBytes: 1000), [])

    // Where the cache is: HF_HUB_CACHE, then HF_HOME/hub, then ~/.cache/huggingface/hub.
    checkEqual(huggingFaceHubDir(environment: ["HF_HUB_CACHE": "/x/hub"], home: "/Users/t"), "/x/hub")
    checkEqual(huggingFaceHubDir(environment: ["HF_HOME": "/x"], home: "/Users/t"), "/x/hub")
    checkEqual(huggingFaceHubDir(environment: [:], home: "/Users/t"), "/Users/t/.cache/huggingface/hub")
    // Default folders never include Desktop, Documents or Downloads: reading them asks for permission.
    for folder in defaultModelFolders(home: "/Users/t") {
        check(!["Desktop", "Documents", "Downloads"].contains(where: { folder.hasPrefix("/Users/t/\($0)") }), "\(folder) needs a permission")
    }
}

func testModelOnDisk() throws {
    let hub = try makeTempFolder(), folder = try makeTempFolder()
    try makeHubModel("mlx-community/gemma-4-12b-it-4bit", in: hub, files: ["config.json", "model.safetensors"])
    try makeHubModel("someone/qwen-adapter", in: hub, files: ["adapter_config.json", "adapter_model.safetensors"])
    let gguf = (folder as NSString).appendingPathComponent("m.gguf")
    try makeFile(gguf, bytes: 10)

    checkEqual(missingModel(BackendConfig(backend: .mlx, model: "mlx-community/gemma-4-12b-it-4bit"), hubDir: hub), nil)
    checkEqual(missingModel(BackendConfig(backend: .mlx, model: "mlx-community/Llama-3.2-3B-Instruct-4bit"), hubDir: hub),
               .modelMissing("mlx-community/Llama-3.2-3B-Instruct-4bit"))
    checkEqual(missingModel(BackendConfig(backend: .mlx, model: "someone/qwen-adapter"), hubDir: hub), .modelMissing("someone/qwen-adapter"))
    // mlx_lm also takes a folder on disk.
    checkEqual(missingModel(BackendConfig(backend: .mlx, model: folder), hubDir: hub), nil)
    checkEqual(missingModel(BackendConfig(backend: .llamaCpp, model: gguf), hubDir: hub), nil)
    checkEqual(missingModel(BackendConfig(backend: .llamaCpp, model: gguf + ".gone"), hubDir: hub), .modelMissing(gguf + ".gone"))
    // A model-bundled .llamafile has no separate model; an unset model is a different error.
    checkEqual(missingModel(BackendConfig(backend: .llamafile, model: ""), hubDir: hub), nil)
    checkEqual(missingModel(BackendConfig(backend: .llamaCpp, model: " "), hubDir: hub), .modelNotSet)
    check(RewriteError.modelMissing("x/y").localizedDescription.contains("x/y"), "the error names the model")
}

// Picking a found model sets the runner that can use it.
func testChoosingAModel() throws {
    let dir = try makeTempFolder()
    try makeScript("llama-completion", in: dir, "")
    let mlx = LocalModel(format: .mlx, id: "mlx-community/m-4bit", bytes: 1)
    let gguf = LocalModel(format: .gguf, id: "/models/q.gguf", bytes: 1)
    var config = BackendConfig(backend: .mlx, model: "gone/model", executable: "/x/mlx_lm.generate", maxTokens: 99)

    var chosen = config.choosing(gguf, searchDirs: [dir])
    checkEqual(chosen.backend, .llamaCpp)
    checkEqual(chosen.model, "/models/q.gguf")
    checkEqual(chosen.executable, nil)  // The MLX runner's path means nothing to llama.cpp.
    checkEqual(chosen.maxTokens, 99)
    // An MLX model keeps the MLX runner path.
    chosen = config.choosing(mlx, searchDirs: [dir])
    checkEqual(chosen, BackendConfig(backend: .mlx, model: "mlx-community/m-4bit", executable: "/x/mlx_lm.generate", maxTokens: 99))
    // Already on llamafile: a GGUF stays on llamafile, with its runner path.
    config = BackendConfig(backend: .llamafile, model: "", executable: "/x/llamafile")
    chosen = config.choosing(gguf, searchDirs: [dir])
    checkEqual(chosen.backend, .llamafile)
    checkEqual(chosen.executable, "/x/llamafile")
    // No llama.cpp, but llamafile installed: use llamafile.
    let other = try makeTempFolder()
    try makeScript("llamafile", in: other, "")
    checkEqual(BackendConfig(backend: .mlx, model: "m").choosing(gguf, searchDirs: [other]).backend, .llamafile)
    // Which models a runner can use.
    check(mlx.runs(on: .mlx) && !mlx.runs(on: .llamaCpp), "MLX models run on MLX only")
    check(gguf.runs(on: .llamaCpp) && gguf.runs(on: .llamafile) && !gguf.runs(on: .mlx), "GGUF runs on llama.cpp and llamafile")
    // The current model is recognized in the list.
    check(mlx.isCurrent(in: BackendConfig(backend: .mlx, model: "mlx-community/m-4bit")), "current MLX model")
    check(!mlx.isCurrent(in: BackendConfig(backend: .llamaCpp, model: "mlx-community/m-4bit")), "wrong runner")
}

// Folders searched for GGUF files: the usual ones, the user's, and the current model's own folder.
func testModelSearchFolders() throws {
    let config = BackendConfig(backend: .llamaCpp, model: "/Users/t/.kimi/models/q.gguf")
    let folders = modelSearchFolders(current: config, extra: ["/x"], home: "/Users/t")
    checkEqual(folders, defaultModelFolders(home: "/Users/t") + ["/x", "/Users/t/.kimi/models"])
    // An MLX repo id isn't a path; a model-bundled llamafile has none.
    checkEqual(modelSearchFolders(current: BackendConfig(backend: .mlx, model: "org/m"), extra: [], home: "/Users/t"),
               defaultModelFolders(home: "/Users/t"))
    checkEqual(modelSearchFolders(current: BackendConfig(backend: .llamafile, model: ""), extra: [], home: "/Users/t"),
               defaultModelFolders(home: "/Users/t"))
}

// FEATURE_FUTURE §2: the estimate shown before comparing, and a warning for models too big for memory.
func testCompareEstimate() throws {
    let gb: Int64 = 1_000_000_000
    let small = LocalModel(format: .mlx, id: "a/3b-4bit", bytes: 2 * gb)
    // A 3B model (about 2 GB at 4 bits): about 10 s to load plus 7 to 15 s to write, as measured for the design doc.
    checkEqual(estimatedSeconds(for: [small]), 17...25)
    // Bigger models load and write proportionally slower; models run one after another, so times add up.
    let big = LocalModel(format: .gguf, id: "/m/12b.gguf", bytes: 8 * gb)
    checkEqual(estimatedSeconds(for: [big]), 68...100)
    checkEqual(estimatedSeconds(for: [small, big]), 85...125)
    checkEqual(estimatedSeconds(for: []), 0...0)
    // On an 8 GB Mac, a 7 GB model leaves too little for macOS and the app that asked.
    check(fitsInMemory(small, memory: 8 * 1 << 30), "a 2 GB model fits in 8 GB")
    check(!fitsInMemory(LocalModel(format: .mlx, id: "a/12b", bytes: 7 * gb), memory: 8 * 1 << 30), "a 7 GB model doesn't fit in 8 GB")
}
