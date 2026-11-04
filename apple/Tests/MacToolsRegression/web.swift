import AppKit
import WebKit

/// Uses the production delegate with an in-memory WKWebView; no persisted browser data is accessed or deleted.
@MainActor final class MacWebHostRunner: NSObject, NSApplicationDelegate {
    let controller = ToolCyberChefController()
    var coordinator: ToolCyberChefWebView.Coordinator?
    var web: WKWebView?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); print("PASS: production Mac web-tool coordinator, CyberChef conversion, offline blocking, and native export bridge; nonpersistent browser store"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
    }
    func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadMacWebSmokeOffline", encodedContentRuleList: rules) else { throw failure("Offline rules could not compile") }
        config.userContentController.add(list)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 850), configuration: config)
        self.web = web
        let coordinator = ToolCyberChefWebView.Coordinator(directory: directory, controller: controller)
        self.coordinator = coordinator; web.navigationDelegate = coordinator; web.uiDelegate = coordinator
        web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        var ready = false
        for _ in 0..<120 {
            if (try? await web.evaluateJavaScript("!!window.app && app.appLoaded && app.workerLoaded && app.waitersLoaded")) as? Bool == true { ready = true; break }
            if let error = controller.error { throw failure(error) }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard ready else { throw failure("Bundled CyberChef did not become ready") }
        let count = try await web.evaluateJavaScript("Object.keys(app.operations).length") as? Int ?? 0
        guard count > 300 else { throw failure("Operation catalog missing") }
        _ = try await web.evaluateJavaScript("app.setInput('NOMAD'); app.setRecipeConfig([{op:'To Base64',args:[]}]); true")
        var converted = false
        for _ in 0..<60 {
            if (try? await web.evaluateJavaScript("app.manager.output.outputEditorView.state.doc.toString()")) as? String == "Tk9NQUQ=" { converted = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard converted else { throw failure("Actual upstream conversion failed") }
        let network = try await web.callAsyncJavaScript("try { await fetch('https://example.com/'); return 'ALLOWED' } catch { return 'BLOCKED' }", arguments: [:], in: nil, contentWorld: .page)
        guard network as? String == "BLOCKED" else { throw failure("Remote fetch was allowed") }
        _ = try await web.evaluateJavaScript("(()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['Mac native export'],{type:'text/plain'}));a.download='test.txt';document.body.appendChild(a);a.click();a.remove();return true;})()")
        for _ in 0..<60 {
            if let export = controller.export {
                guard try String(contentsOf: export.url, encoding: .utf8) == "Mac native export" else { throw failure("Export bytes changed") }
                controller.finishExport(export.url)
                controller.cleanupImports()
                return
            }
            if let error = controller.error { throw failure(error) }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw failure("Production native export delegate did not receive the blob")
    }
    func failure(_ message: String) -> NSError { NSError(domain: "MacWebHost", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@main struct MacWebHostTest {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = MacWebHostRunner(); app.delegate = runner
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL: native Mac web host timed out"); exit(1) }
        app.run()
    }
}
