import Foundation

// The Services menu items live in Info.plist, and macOS calls the method each one names on the
// app's services provider. A typo on either side and the item silently does nothing.
func testServicesEntry() throws {
    guard let plist = NSDictionary(contentsOfFile: "Resources/App-Info.plist"),
          let services = plist["NSServices"] as? [[String: Any]] else {
        throw TestFailure(description: "Resources/App-Info.plist has no NSServices entries")
    }
    let source = try String(contentsOfFile: "Sources/PromptMenu/Service.swift", encoding: .utf8)
    var messages: [String] = []
    for service in services {
        let message = service["NSMessage"] as? String ?? ""
        messages.append(message)
        check(source.contains("func \(message)(_ pasteboard: NSPasteboard, userData: String?, error"),
              "Service.swift has no \(message)(_:userData:error:) method")
        check((service["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true, "\(message) should accept plain text")
        check(service["NSRequiredContext"] != nil, "\(message): NSRequiredContext makes the item show up without a trip to System Settings")
    }
    // Every style has its item, with the title the docs use.
    for style in Style.allCases {
        guard let service = services.first(where: { $0["NSMessage"] as? String == style.serviceMessage }) else {
            check(false, "no Services item for \(style)"); continue
        }
        checkEqual((service["NSMenuItem"] as? [String: String])?["default"], style.menuTitle)
        check(service["NSReturnTypes"] == nil, "\(style) opens a dialog, so it returns nothing")
    }
    // Existing keyboard shortcuts are bound to this name.
    checkEqual(Style.agentPrompt.serviceMessage, "rewriteAsAgentPrompt")
    checkEqual(Style.agentPrompt.menuTitle, "Rewrite as Agent Prompt")
    // The in-place item returns text, and waits long enough for a model to load.
    guard let inPlace = services.first(where: { $0["NSMessage"] as? String == inPlaceServiceMessage }) else {
        throw TestFailure(description: "no Services item for \(inPlaceServiceMessage)")
    }
    checkEqual((inPlace["NSMenuItem"] as? [String: String])?["default"], "Rewrite as Agent Prompt (Replace Selection)")
    check((inPlace["NSReturnTypes"] as? [String])?.contains("public.utf8-plain-text") == true, "the in-place item must return text")
    check(Int(inPlace["NSTimeout"] as? String ?? "") ?? 0 > Int(inPlaceTimeout * 1000), "NSTimeout must outlast inPlaceTimeout")
    checkEqual(messages.count, Set(messages).count)
    checkEqual(messages.count, Style.allCases.count + 1)
}

func testStyles() throws {
    for style in Style.allCases {
        check(style.builtInPrompt.contains("[CONFIRM:"), "\(style) should ask for [CONFIRM: …] instead of guesses")
        for section in style.sections {
            check(style.builtInPrompt.contains("\(section):"), "\(style)'s instructions don't name its \(section) section")
        }
    }
    checkEqual(Style.agentPrompt.builtInPrompt, agentSystemPrompt)
    // The custom systemPrompt setting changes the agent prompt only.
    let custom = BackendConfig(backend: .mlx, model: "m", systemPrompt: "Be brief.")
    checkEqual(systemPrompt(for: .agentPrompt, config: custom), "Be brief.")
    checkEqual(systemPrompt(for: .bugReport, config: custom), Style.bugReport.builtInPrompt)
}
