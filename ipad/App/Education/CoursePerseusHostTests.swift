#if NOMAD_PERSEUS_HOST_TESTS && os(macOS)
import Foundation
import AppKit
import WebKit

/// Uses the production native host and the unmodified official sorter test item.
@main @MainActor private enum CoursePerseusHostTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw CourseError.invalid("TEST FAILURE: " + message) }; checks += 1
    }
    static func until(_ test: () -> Bool, controller: CoursePerseusController) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !test() {
            if let error = controller.error { throw CourseError.invalid(error) }
            guard Date() < deadline else { throw CourseError.invalid("Timed out waiting for the native WebKit exercise host.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    static func main() async {
        do { try await run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1]), archive = URL(fileURLWithPath: CommandLine.arguments[2])
        let controller = CoursePerseusController()
        var saved: [(String, Int)] = [], scores: [(String, Double?, Double?)] = []
        let state = CourseExerciseState(learnerID: UUID(), contentID: String(repeating: "a", count: 32), itemID: "test-item",
            answerStateJSON: #"{"userInput":{"sorter 1":{"options":["1","2","3","4","5"],"changed":true}},"hintsVisible":0}"#,
            hintsVisible: 0, updatedAt: Date())
        let host = CoursePerseusCoordinator(controller: controller, archiveURL: archive, rendererRoot: bundle, itemID: "test-item", locale: "en", initial: state,
            onState: { saved.append(($0, $1)) }, onResult: { type, earned, total, _, _ in scores.append((type, earned, total)) })
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: host.configuration())
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        host.start(view)
        defer { host.stop(); window.contentView = nil; window.close() }
        try await until({ controller.ready }, controller: controller)
        try check(controller.ready, "Official renderer loads through the production scheme, CSP, and network filter")
        let text = try await view.callAsyncJavaScript("return document.body.innerText;", arguments: [:], in: nil, contentWorld: .page) as? String
        try check(text?.contains("Sort the numbers") == true, "Official sorter question rendered")
        controller.checkAnswer()
        try await until({ !scores.isEmpty }, controller: controller)
        try check(scores[0].0 == "points" && scores[0].1 == 1 && scores[0].2 == 1, "Original scorer accepts restored correct sorter state")
        host.flush()
        try check(!saved.isEmpty && saved.last?.1 == 0, "Actual renderer state crosses native validation and persistence callback")
        let fetched = try await view.callAsyncJavaScript("const r = await fetch('nomad-perseus://local/package/test-item.json'); return (await r.json()).question.content;", arguments: [:], in: nil, contentWorld: .page) as? String
        try check(fetched?.contains("Sort the numbers") == true, "Package JSON can be fetched offline for Graphie and assets")
        let blocked = try await view.callAsyncJavaScript("try { await fetch('https://example.invalid/nomad-test'); return false; } catch (_) { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool
        try check(blocked == true, "External fetch blocked")
        view.load(URLRequest(url: URL(string: "nomad-perseus://local/package/test-item.json")!))
        try await Task.sleep(for: .milliseconds(300))
        try check(view.url?.path == "/renderer/index.html", "Imported package cannot replace the trusted renderer main frame")
        print("PASS: \(checks) production-host WebKit checks with the official sorter fixture; no production learning data.")
    }
}
#endif
