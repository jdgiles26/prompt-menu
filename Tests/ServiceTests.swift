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
        // Explain doesn't rewrite, so there's nothing to ask [CONFIRM: …] about; it says what it's unsure of instead.
        if style.isRewrite {
            check(style.builtInPrompt.contains("[CONFIRM:"), "\(style) should ask for [CONFIRM: …] instead of guesses")
        }
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

// Explain This for Me: its own title (not "Rewrite as …"), takes Finder files too, and the
// existing items keep the titles and method names users bound shortcuts to.
func testExplainStyle() throws {
    checkEqual(Style.explain.menuTitle, "Explain This for Me")
    checkEqual(Style.explain.serviceMessage, "explainThisForMe")
    check(!Style.explain.isRewrite, "explain isn't a rewrite")
    check(Style.allCases.filter { $0 != .explain }.allSatisfy { $0.isRewrite }, "the other styles are rewrites")
    checkEqual(Style.bugReport.menuTitle, "Rewrite as Bug Report")
    checkEqual(Style.codeReview.serviceMessage, "rewriteAsCodeReviewRequest")
    checkEqual(Style.commitMessage.menuTitle, "Rewrite as Commit Message")
    let prompt = Style.explain.builtInPrompt
    checkEqual(Style.explain.sections.first, "TL;DR")
    check(prompt.lowercased().contains("explain"), "the instructions should ask for an explanation")
    check(!prompt.contains("[CONFIRM:"), "an explanation has no [CONFIRM: …] questions")
    check(prompt.contains("(probably)"), "guesses should be marked, not stated as fact")
    // In depth: room for a longer answer than a rewrite, without changing the setting.
    checkEqual(Style.explain.maxTokens(base: 1024), 2048)
    checkEqual(Style.explain.maxTokens(base: 4096), 4096)
    checkEqual(Style.agentPrompt.maxTokens(base: 1024), 1024)

    guard let plist = NSDictionary(contentsOfFile: "Resources/App-Info.plist"),
          let services = plist["NSServices"] as? [[String: Any]],
          let service = services.first(where: { $0["NSMessage"] as? String == "explainThisForMe" }) else {
        throw TestFailure(description: "no Services item for explainThisForMe")
    }
    let fileTypes = service["NSSendFileTypes"] as? [String] ?? []
    check(fileTypes.contains("public.plain-text") && fileTypes.contains("public.source-code"),
          "Explain This for Me should show on text and code files in Finder")
    // public.data would also match PDFs and images, which can't be explained, so it stays out.
    check(!fileTypes.contains("public.data") && !fileTypes.contains("public.item") && !fileTypes.contains("public.content"),
          "Explain This for Me shouldn't show on PDFs and images")
    check(fileTypes.contains("public.text"), "HTML, YAML and other text formats aren't public.plain-text")
    // macOS has no type for these text formats, so Finder wouldn't offer the item without this.
    let imported = plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
    let extensions = imported.flatMap { (($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? [] }
    for name in ["toml", "sql", "env", "ini", "conf", "cfg"] { check(extensions.contains(name), "\(name) should count as text") }
    for type in imported { check((type["UTTypeConformsTo"] as? [String])?.contains("public.plain-text") == true, "imported types are plain text") }
}

// Bug: Settings opened after a Services launch whose request had failed, in place of any message.
func testLaunchShowsSettingsOnlyWhenOpenedDirectly() throws {
    check(showsSettingsAtLaunch(isDefaultLaunch: true, handledService: false, hasWindows: false), "opened directly")
    check(!showsSettingsAtLaunch(isDefaultLaunch: false, handledService: false, hasWindows: false), "launched for a Service")
    check(!showsSettingsAtLaunch(isDefaultLaunch: true, handledService: true, hasWindows: false), "a request already arrived")
    check(!showsSettingsAtLaunch(isDefaultLaunch: true, handledService: false, hasWindows: true), "a window is already open")
}

// Finder doesn't show a service's error string, so a failure that only sets it looks like nothing happened.
func testServiceFailuresReachTheUser() throws {
    let source = try String(contentsOfFile: "Sources/PromptMenu/Service.swift", encoding: .utf8)
    check(source.contains("onFailure"), "Service.swift should hand failures to the app to show")
    let explain = source.components(separatedBy: "func explainThisForMe").last?.components(separatedBy: "@objc").first ?? ""
    check(explain.contains("onFailure"), "explainThisForMe must show its failures")
    check(!explain.contains("error.pointee"), "explainThisForMe's failures must not end at the error string")
}
