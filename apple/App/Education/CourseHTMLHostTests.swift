#if NOMAD_HTML_HOST_TESTS && os(macOS)
import Foundation
import AppKit
import WebKit

@MainActor private final class CourseHTMLTestRequest: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    init(_ path: String) { request = URLRequest(url: URL(string: "nomad-course://local/" + path)!) }
    func didReceive(_ response: URLResponse) { events.append("response") }
    func didReceive(_ data: Data) { events.append("data") }
    func didFinish() { events.append("finish") }
    func didFailWithError(_ error: Error) { events.append("failure") }
}

@main @MainActor private enum CourseHTMLHostTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CourseError.invalid("TEST FAILURE: " + message) }; checks += 1
    }
    static func main() async {
        do { try await run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
        var progress: [[String: String]] = [], errors: [String] = []
        let host = CourseHTMLTestCoordinator(initialValues: ["cmi.suspend_data": "TEST-ONLY restored"], onProgress: { progress.append($0) }, onError: { errors.append($0) })
        host.archive = try CourseZipArchive(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(host, forURLScheme: "nomad-course")
        config.userContentController.add(host, name: "courseProgress")
        config.userContentController.addUserScript(WKUserScript(source: host.bootstrap(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        host.webView = view; view.navigationDelegate = host
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = view
        defer { host.stop(); view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "courseProgress"); window.contentView = nil; window.close() }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nomad-course-test-offline", encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) } else { continuation.resume(throwing: error ?? CourseError.invalid("No offline rule list")) }
            }
        }
        config.userContentController.add(list)
        view.load(URLRequest(url: URL(string: "nomad-course://local/index.html")!))
        let deadline = Date().addingTimeInterval(30)
        while progress.isEmpty {
            if let error = errors.first { throw CourseError.invalid(error) }
            guard Date() < deadline else { throw CourseError.invalid("Timed out waiting for HTML5 local fetch/progress.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(progress.last?["cmi.core.score.raw"] == "8", "Packaged local JSON fetch succeeds and exact package score is recorded")
        try check(progress.last?["cmi.suspend_data"] == "TEST-ONLY restored", "SCORM resume data restored")
        let rejected = try await view.callAsyncJavaScript("return window.API.LMSSetValue('unsupported.key','value');", arguments: [:], in: nil, contentWorld: .page) as? String
        try check(rejected == "false", "Unsupported SCORM field is rejected")
        let blocked = try await view.callAsyncJavaScript("try { await fetch('https://example.invalid/nomad-test'); return false; } catch (_) { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check(blocked == true, "HTML5 external fetch blocked")
        let cancelled = CourseHTMLTestRequest("large.txt")
        host.webView(view, start: cancelled); host.webView(view, stop: cancelled)
        try await Task.sleep(for: .milliseconds(300))
        try check(cancelled.events.isEmpty, "Cancelled scheme request receives no late callback")
        let dismissed = CourseHTMLTestRequest("large.txt")
        host.webView(view, start: dismissed); host.stop()
        try await Task.sleep(for: .milliseconds(300))
        try check(!host.active && dismissed.events.isEmpty, "Dismissal deactivates host and prevents late callbacks")
        let late = CourseHTMLTestRequest("index.html"); host.webView(view, start: late)
        try check(late.events == ["failure"], "Dismissed host rejects late asset requests")
        print("PASS: \(checks) actual HTML5 coordinator WebKit/lifecycle checks using test-only packages.")
    }
}
#endif
