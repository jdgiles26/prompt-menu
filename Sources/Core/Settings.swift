import Foundation

// Small enough for 8 GB Macs, and good at following an outline.
let defaultMLXModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"

// The app's own preferences. Also editable with `defaults write local.promptmenu <key> <value>`.
let settings = UserDefaults(suiteName: "local.promptmenu") ?? .standard

func loadConfig(from defaults: UserDefaults = settings) -> BackendConfig {
    let backend = defaults.string(forKey: "backend").flatMap(Backend.init(rawValue:)) ?? .mlx
    let model = defaults.string(forKey: "model") ?? (backend == .mlx ? defaultMLXModel : "")
    let executable = defaults.string(forKey: "executable").flatMap { $0.isEmpty ? nil : $0 }
    var config = BackendConfig(backend: backend, model: model, executable: executable)
    if defaults.object(forKey: "maxTokens") != nil { config.maxTokens = defaults.integer(forKey: "maxTokens") }
    if defaults.object(forKey: "temperature") != nil { config.temperature = defaults.double(forKey: "temperature") }
    return config
}

func saveConfig(_ config: BackendConfig, to defaults: UserDefaults = settings) {
    defaults.set(config.backend.rawValue, forKey: "backend")
    defaults.set(config.model, forKey: "model")
    defaults.set(config.executable ?? "", forKey: "executable")
    defaults.set(config.maxTokens, forKey: "maxTokens")
    defaults.set(config.temperature, forKey: "temperature")
}
