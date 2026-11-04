import AppKit
import WebKit

@MainActor private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?.resume(); completion = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion?.resume(throwing: error); completion = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion?.resume(throwing: error); completion = nil }
}

@main struct ZIMTranslationRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); fflush(stdout); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        let world = WKContentWorld.world(name: "org.projectnomad.article-translation-test")
        let image = Data("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><rect width='12' height='12' fill='blue'/></svg>".utf8).base64EncodedString()
        let html = """
        <html lang="en" dir="ltr"><head><style>.hidden { display:none }</style></head><body>
        <main><h1>Test article</h1><p>Read <a id="link" href="next.html#section">the local link</a> today.</p>
        <img id="picture" src="data:image/svg+xml;base64,\(image)">
        <pre>let secret = 4;</pre><span translate="no">Skip this text</span><span class="hidden">Hidden text</span></main>
        </body></html>
        """
        print("WebKit: loading inline fixture"); fflush(stdout)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.completion = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        print("WebKit: fixture loaded; testing DOM"); fflush(stdout)
        let original = try await evaluate(view, script: "return document.body.innerHTML;", world: .page)
        let raw = try await evaluate(view, script: ZIMTranslationDOM.capture, arguments: ["token": "fixture-1"], world: world)
        let texts = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
        precondition(texts == ["Test article", "Read", "the local link", "today."])
        let replacement = texts.enumerated().map { "ترجمة \($0.offset) <script>should stay text</script>" }
        _ = try await evaluate(view, script: ZIMTranslationDOM.apply, arguments: ["token": "fixture-1", "values": replacement, "target": "ar", "rtl": true], world: world)
        let retained = try await evaluate(view, script: """
        return document.querySelector('#link').getAttribute('href') === 'next.html#section'
          && document.querySelector('#picture').getAttribute('src').startsWith('data:image/svg+xml;base64,')
          && document.querySelector('#picture').naturalWidth === 12
          && document.querySelectorAll('script').length === 0
          && document.querySelector('pre').textContent === 'let secret = 4;'
          && document.documentElement.lang === 'ar' && document.documentElement.dir === 'rtl'
          && typeof globalThis.__nomadArticleTranslation === 'undefined';
        """, world: .page)
        precondition(retained == "true")
        _ = try await evaluate(view, script: ZIMTranslationDOM.restore, world: world)
        let restored = try await evaluate(view, script: "return document.body.innerHTML;", world: .page)
        precondition(restored == original)
        let languageRestored = try await evaluate(view, script: "return document.documentElement.lang === 'en' && document.documentElement.dir === 'ltr';", world: .page)
        precondition(languageRestored == "true")

        _ = try await evaluate(view, script: ZIMTranslationDOM.capture, arguments: ["token": "fixture-2"], world: world)
        _ = try await evaluate(view, script: "document.querySelector('h1').firstChild.nodeValue = 'Changed article'; return true;", world: .page)
        do {
            _ = try await evaluate(view, script: ZIMTranslationDOM.apply, arguments: ["token": "fixture-2", "values": replacement, "target": "ar", "rtl": true], world: world)
            fatalError("Applied a stale DOM snapshot")
        } catch { }
        let stillOriginal = try await evaluate(view, script: "return document.querySelector('#link').textContent === 'the local link' && document.querySelector('h1').textContent === 'Changed article';", world: .page)
        precondition(stillOriginal == "true")
        _ = try await evaluate(view, script: ZIMTranslationDOM.restore, world: world)
        do {
            _ = try await evaluate(view, script: ZIMTranslationDOM.apply, arguments: ["token": "fixture-2", "values": replacement, "target": "ar", "rtl": true], world: world)
            fatalError("Applied a cancelled snapshot")
        } catch { }
        _ = try await evaluate(view, script: "document.querySelector('main').textContent = 'x'.repeat(60001); return true;", world: .page)
        do {
            _ = try await evaluate(view, script: ZIMTranslationDOM.capture, arguments: ["token": "too-large"], world: world)
            fatalError("Accepted an oversized article")
        } catch { }
        view.stopLoading(); window.close()
        print("PASS: real WebKit isolated-world capture, text-only translation, inline links/local image retention, code/hidden exclusion, exact original restoration, stale/cancelled snapshot rejection and text bounds")
    }

    @MainActor private static func evaluate(_ view: WKWebView, script: String, arguments: [String: Any] = [:], world: WKContentWorld) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let wrapped = "const result = await (async () => {\n" + script + "\n})(); return JSON.stringify(result);"
            view.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "null")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}
