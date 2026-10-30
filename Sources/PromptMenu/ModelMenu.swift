import Cocoa

// A menu item that runs a closure, so menus built on the fly don't need a selector per model.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire(_ sender: Any?) { handler() }
}

// The models on this Mac, found fresh each time (a few milliseconds), so a deleted or newly
// downloaded model shows up without restarting.
func modelsOnThisMac(_ config: BackendConfig = loadConfig()) -> [LocalModel] {
    localModels(folders: modelSearchFolders(current: config, extra: modelFolders()))
}

// One item per model on this Mac, the current one ticked. Picking one saves it and calls `picked`
// with the new config. A model that's set but missing is listed first, so it's clear why nothing works.
func modelMenuItems(picked: @escaping (BackendConfig) -> Void) -> [NSMenuItem] {
    let config = loadConfig()
    let models = modelsOnThisMac(config)
    var items: [NSMenuItem] = []
    if case .modelMissing(let model) = missingModel(config) {
        let item = NSMenuItem(title: "\((model as NSString).lastPathComponent) · not on this Mac", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.state = .on
        items.append(item)
        if !models.isEmpty { items.append(.separator()) }
    }
    if models.isEmpty {
        let item = NSMenuItem(title: "No models found on this Mac", action: nil, keyEquivalent: "")
        item.isEnabled = false
        items.append(item)
    }
    for model in models {
        let item = ActionMenuItem(title: model.label + (fitsInMemory(model) ? "" : " · may not fit in memory")) {
            let current = loadConfig()
            let chosen = current.choosing(model)
            guard chosen != current else { return }
            saveConfig(chosen)
            picked(chosen)
        }
        item.toolTip = model.id
        item.state = model.isCurrent(in: config) ? .on : .off
        items.append(item)
    }
    return items
}
