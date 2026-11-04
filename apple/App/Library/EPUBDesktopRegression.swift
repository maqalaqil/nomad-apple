#if NOMAD_EPUB_DESKTOP_TESTS && os(macOS)
import AppKit
import WebKit

@MainActor private final class EPUBDesktopTestHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loaded = false
    var failure: Error?
    var messages: [Any] = []
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { messages.append(message.body) }
}

@main @MainActor private enum EPUBDesktopRegression {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw EPUBFailure(message: "TEST FAILURE: " + message) }; checks += 1; fputs("PASS: \(message)\n", stderr)
    }
    static func main() async {
        do { try await run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
        let archive = try EPUBArchive(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let host = EPUBDesktopTestHost(), config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(EPUBSchemeHandler(archive: archive), forURLScheme: "nomadepub")
        config.userContentController.add(host, contentWorld: EPUBDesktopPosition.world, name: EPUBDesktopPosition.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: EPUBDesktopPosition.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: EPUBDesktopPosition.world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 500), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; view.navigationDelegate = host; window.orderFront(nil)
        defer {
            view.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: EPUBDesktopPosition.handlerName, contentWorld: EPUBDesktopPosition.world)
            window.contentView = nil; window.close()
        }
        let expectedURL = EPUBArchive.url(path: archive.chapters[0].path)!
        view.load(URLRequest(url: expectedURL))
        let deadline = Date().addingTimeInterval(25)
        while !host.loaded {
            if let failure = host.failure { throw failure }
            guard Date() < deadline else { throw EPUBFailure(message: "Timed out opening local EPUB") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let scriptRan = try await view.callAsyncJavaScript("return Boolean(window.bookScriptRan);", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check(scriptRan == false, "Archive scripts remain disabled")
        let restored = try await view.callAsyncJavaScript(EPUBDesktopPosition.restoreScript, arguments: ["fraction": 0.55], in: nil, contentWorld: EPUBDesktopPosition.world) as? Double
        try check(abs((restored ?? -1) - 0.55) < 0.01, "Native macOS restore reaches requested fraction")
        while host.messages.isEmpty {
            guard Date() < deadline else { throw EPUBFailure(message: "Timed out waiting for isolated-world scroll event") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(host.messages.contains { abs((EPUBDesktopPosition.fraction($0, expectedURL: expectedURL) ?? -1) - 0.55) < 0.01 }, "Scrolled position arrives through isolated bridge")
        let snapshot = try await view.callAsyncJavaScript(EPUBDesktopPosition.snapshotScript, arguments: [:], in: nil, contentWorld: EPUBDesktopPosition.world)
        try check(abs((EPUBDesktopPosition.fraction(snapshot, expectedURL: expectedURL) ?? -1) - 0.55) < 0.01, "Dismissal snapshot records current fraction")
        let configuration = WKFindConfiguration(); configuration.wraps = true
        let match = try await view.find("UNIQUE OFFLINE BOOKMARK", configuration: configuration)
        try check(match.matchFound, "Native chapter text search finds actual local text")
        let missing = try await view.find("NOT IN THIS BOOK 12345", configuration: configuration)
        try check(!missing.matchFound, "Native text search reports absence")
        let blocked = try await view.callAsyncJavaScript("try { await fetch('https://example.invalid/epub-probe'); return false; } catch (_) { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check(blocked == true, "EPUB content policy rejects remote fetch")
        let invalid: [[String: Any]] = [
            ["url": expectedURL.absoluteString, "fraction": true],
            ["url": expectedURL.absoluteString, "fraction": -1],
            ["url": expectedURL.absoluteString, "fraction": Double.infinity],
            ["url": "nomadepub://book/wrong.xhtml", "fraction": 0.5],
            ["url": "https://example.invalid/", "fraction": 0.5]
        ]
        for value in invalid { try check(EPUBDesktopPosition.fraction(value, expectedURL: expectedURL) == nil, "Reject malformed or stale position event") }
        print("PASS: \(checks) native macOS EPUB position/find/security checks using temporary content.")
    }
}
#endif
