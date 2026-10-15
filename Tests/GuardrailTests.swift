import Foundation

// Checks on the project's promises, so a change that breaks one fails here instead of in review.
// See AGENTS.md before changing any of these.

// Prompt Menu has no network code. Models run as local programs; nothing is sent anywhere.
func testNoNetworkCode() throws {
    let forbidden = ["URLSession", "URLRequest", "NWConnection", "NWListener", "import Network", "CFSocket",
                     "CFStream", "WKWebView", "http://", "https://", "NSURLConnection", "Socket("]
    let files = try FileManager.default.subpathsOfDirectory(atPath: "Sources").filter { $0.hasSuffix(".swift") }
    check(!files.isEmpty, "no sources found; run from the repository root")
    for file in files {
        let source = try String(contentsOfFile: "Sources/\(file)", encoding: .utf8)
        for word in forbidden where source.contains(word) {
            check(false, "Sources/\(file) contains \"\(word)\": Prompt Menu must not use the network")
        }
    }
}

// The app is never sandboxed out of running local programs, and never asks for more than it uses.
func testNoEntitlementsOrPermissions() throws {
    let plist = NSDictionary(contentsOfFile: "Resources/App-Info.plist") ?? [:]
    let usage = (plist.allKeys as? [String] ?? []).filter { $0.hasSuffix("UsageDescription") }
    checkEqual(usage, [])
    let resources = try FileManager.default.contentsOfDirectory(atPath: "Resources")
    check(!resources.contains { $0.hasSuffix(".entitlements") }, "Prompt Menu takes no entitlements")
}

// The README and the docs describe every runner the code supports.
func testDocsCoverEveryRunner() throws {
    for doc in ["README.md", "docs/ARCHITECTURE.md"] {
        let text = try String(contentsOfFile: doc, encoding: .utf8)
        for backend in Backend.allCases where !text.contains(backend.executableName) {
            check(false, "\(doc) doesn't mention \(backend.executableName)")
        }
    }
}
