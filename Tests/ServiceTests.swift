import Foundation

// The Services menu item lives in Info.plist, and macOS calls the method it names on the app's
// services provider. A typo on either side and the item silently does nothing.
func testServicesEntry() throws {
    guard let plist = NSDictionary(contentsOfFile: "Resources/App-Info.plist"),
          let services = plist["NSServices"] as? [[String: Any]], let service = services.first else {
        throw TestFailure(description: "Resources/App-Info.plist has no NSServices entry")
    }
    let message = service["NSMessage"] as? String ?? ""
    checkEqual(message, serviceMessage)
    checkEqual((service["NSMenuItem"] as? [String: String])?["default"], "Rewrite as Agent Prompt")
    check((service["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true, "the service should accept plain text")
    check(service["NSRequiredContext"] != nil, "NSRequiredContext makes the item show up without a trip to System Settings")
    let source = try String(contentsOfFile: "Sources/PromptMenu/Service.swift", encoding: .utf8)
    check(source.contains("func \(message)(_ pasteboard: NSPasteboard, userData: String?, error"),
          "Service.swift has no \(message)(_:userData:error:) method")
}
