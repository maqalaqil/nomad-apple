// macOS WebKit smoke test for the bundled CyberChef distribution.
// Run: swift apple/scripts/fetch-web-tools.smoke.swift [CyberChef resource directory]
// Requires access to macOS GUI/WebKit services; it opens no visible window.
import AppKit
import WebKit

setbuf(stdout, nil)

struct RecipeCheck {
    let name: String
    let input: String
    let recipe: [[String: Any]]
    let expected: String
}

final class WebToolsSmokeRunner: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKDownloadDelegate {
    let root: URL
    var webView: WKWebView!
    var recipeIndex = 0
    var attempts = 0
    var downloadURL: URL?
    let recipes: [RecipeCheck] = [
        .init(name: "Base64", input: "NOMAD", recipe: [["op": "To Base64", "args": []]], expected: "Tk9NQUQ="),
        .init(name: "SHA-256", input: "abc", recipe: [["op": "SHA2", "args": [256]]], expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        .init(name: "Reverse", input: "NOMAD", recipe: [["op": "Reverse", "args": []]], expected: "DAMON"),
        .init(name: "Gzip round-trip", input: "NOMAD offline test", recipe: [["op": "Gzip", "args": []], ["op": "Gunzip", "args": []]], expected: "NOMAD offline test"),
        .init(name: "Jq WebAssembly", input: "{\"answer\":42}", recipe: [["op": "Jq", "args": [".answer"]]], expected: "42"),
        .init(name: "ROT13", input: "NOMAD", recipe: [["op": "ROT13", "args": []]], expected: "ABZNQ")
    ]

    init(root: URL) { self.root = root }

    func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1366, height: 1024), configuration: configuration)
        webView.navigationDelegate = self
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadCyberChefOfflineSmoke", encodedContentRuleList: rules) { rules, error in
            guard let rules else { self.fail("Content rule compilation: \(String(describing: error))") }
            configuration.userContentController.add(rules)
            self.webView.loadFileURL(self.root.appendingPathComponent("index.html"), allowingReadAccessTo: self.root)
            self.waitForReady()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.fail("Smoke test exceeded 120 seconds") }
    }

    func waitForReady() {
        attempts += 1
        if attempts > 60 { fail("CyberChef workers failed to become ready") }
        webView.evaluateJavaScript("!!window.app && app.appLoaded && app.workerLoaded && app.waitersLoaded && !document.getElementById('loader-wrapper')") { value, error in
            if value as? Bool == true {
                self.webView.evaluateJavaScript("Object.keys(app.operations).length") { value, _ in print("Catalog operations: \(value ?? "unknown")") }
                self.startRecipe()
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForReady() } }
        }
    }

    func startRecipe() {
        guard recipeIndex < recipes.count else { testNetworkBlocking(); return }
        let test = recipes[recipeIndex]
        let payload: [String: Any] = ["input": test.input, "recipe": test.recipe]
        let json: String
        do { json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self) }
        catch { fail("Could not serialize test recipe: \(error)") }
        attempts = 0
        webView.evaluateJavaScript("(()=>{const t=\(json); app.setInput(t.input); app.setRecipeConfig(t.recipe); return true;})()") { _, error in
            if let error { self.fail("Could not start \(test.name): \(error)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.checkRecipe() }
        }
    }

    func checkRecipe() {
        attempts += 1
        let test = recipes[recipeIndex]
        webView.evaluateJavaScript("app.manager.output.outputEditorView.state.doc.toString()") { value, error in
            let output = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if output == test.expected {
                print("PASS: \(test.name)")
                self.recipeIndex += 1
                self.startRecipe()
            } else if self.attempts >= 30 {
                self.fail("\(test.name): expected \(test.expected), got \(String(describing: output)); \(String(describing: error))")
            } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.checkRecipe() } }
        }
    }

    func testNetworkBlocking() {
        let worker = "return await new Promise(resolve => { const code = \"fetch('https://example.com/').then(()=>postMessage('ALLOWED'),()=>postMessage('BLOCKED'))\"; const worker = new Worker(URL.createObjectURL(new Blob([code], {type:'application/javascript'}))); worker.onmessage=e=>{worker.terminate();resolve(e.data)}; setTimeout(()=>resolve('TIMEOUT'),5000); });"
        webView.callAsyncJavaScript(worker, arguments: [:], in: nil, in: .page) { result in
            guard case .success(let value) = result, value as? String == "BLOCKED" else { self.fail("Worker network blocking: \(result)") }
            print("PASS: worker remote fetch blocked")
            self.webView.callAsyncJavaScript("try { await fetch('https://example.com/'); return 'ALLOWED' } catch { return 'BLOCKED' }", arguments: [:], in: nil, in: .page) { result in
                guard case .success(let value) = result, value as? String == "BLOCKED" else { self.fail("Document network blocking: \(result)") }
                print("PASS: document remote fetch blocked")
                self.testDownload()
            }
        }
    }

    func testDownload() {
        webView.evaluateJavaScript("(()=>{const a=document.createElement('a'); a.href=URL.createObjectURL(new Blob(['NOMAD offline export'],{type:'text/plain'})); a.download='nomad-smoke.txt'; document.body.appendChild(a); a.click(); a.remove(); return true;})()") { _, error in
            if let error { self.fail("Could not trigger blob export: \(error)") }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-cyberchef-smoke-\(UUID().uuidString).txt")
        downloadURL = destination
        completionHandler(destination)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let downloadURL, let data = try? String(contentsOf: downloadURL, encoding: .utf8), data == "NOMAD offline export" else { fail("Blob export bytes differ") }
        try? FileManager.default.removeItem(at: downloadURL)
        print("PASS: native blob download preserves output bytes")
        print("PASS: all CyberChef WebKit smoke checks")
        exit(0)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { fail("Blob download failed: \(error)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("Navigation failed: \(error)") }
}

let defaultDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/WebTools/CyberChef", isDirectory: true)
let root = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : defaultDirectory
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
    print("Run fetch-web-tools.py first. Missing \(root.path)/index.html")
    exit(2)
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let runner = WebToolsSmokeRunner(root: root)
application.delegate = runner
application.run()
