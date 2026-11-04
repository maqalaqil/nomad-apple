import Foundation
import WebKit
import Observation
import UniformTypeIdentifiers
#if canImport(UIKit)
import SwiftUI
#endif

@MainActor @Observable
final class CoursePerseusController {
    var ready = false
    var error: String?
    var feedback: String?
    @ObservationIgnored weak var webView: WKWebView?
    func checkAnswer() { invoke("checkAnswer") }
    func showHint() { invoke("showHint") }
    private func invoke(_ method: String) {
        guard ready, let webView else { return }
        Task { @MainActor in
            do { _ = try await webView.callAsyncJavaScript("return window.NomadPerseus.\(method)();", arguments: [:], in: nil, contentWorld: .page) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Shared with the macOS WebKit harness, so it tests the same host used on iPad.
@MainActor
final class CoursePerseusCoordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
    let controller: CoursePerseusController
    let itemID: String
    private let archiveURL: URL
    private let rendererRoot: URL
    private let locale: String
    private let initial: CourseExerciseState?
    private let onState: (String, Int) -> Void
    private let onResult: (String, Double?, Double?, String?, Int) -> Void
    private var archive: CourseZipArchive?
    private var item: [String: Any]?
    private var active = true
    private var pending: (String, Int)?
    private var saveWork: DispatchWorkItem?
    private var requests: [ObjectIdentifier: WKURLSchemeTask] = [:]
    private let queue = DispatchQueue(label: "nomad.course.perseus.assets", qos: .userInitiated)

    init(controller: CoursePerseusController, archiveURL: URL, rendererRoot: URL, itemID: String, locale: String, initial: CourseExerciseState?,
         onState: @escaping (String, Int) -> Void, onResult: @escaping (String, Double?, Double?, String?, Int) -> Void) {
        self.controller = controller; self.archiveURL = archiveURL; self.rendererRoot = rendererRoot.resolvingSymlinksInPath()
        self.itemID = itemID; self.locale = locale; self.initial = initial; self.onState = onState; self.onResult = onResult
    }
    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "nomad-perseus")
        configuration.userContentController.add(self, name: "perseus")
        return configuration
    }
    func start(_ view: WKWebView) {
        controller.webView = view; view.navigationDelegate = self
        controller.ready = false; controller.error = nil; controller.feedback = nil
        do {
            guard CoursePaths.validItemID(itemID) else { throw CourseError.invalid("The assessment item identifier is invalid.") }
            let archive = try CourseZipArchive(url: archiveURL)
            let data = try archive.read(itemID + ".json")
            guard data.count <= 8 * 1_024 * 1_024, let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CourseError.invalid("The assessment item is invalid or larger than 8 MB.")
            }
            self.archive = archive; self.item = item
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nomad-perseus-offline-v1", encodedContentRuleList: rules) { [weak self, weak view] list, error in
                guard let self, self.active, let view else { return }
                guard let list else { self.fail("The offline exercise filter could not be prepared. \(error?.localizedDescription ?? "")"); return }
                view.configuration.userContentController.add(list)
                view.load(URLRequest(url: URL(string: "nomad-perseus://local/renderer/index.html")!))
            }
        } catch { fail(error.localizedDescription) }
    }
    private func loadItem() {
        guard active, let view = controller.webView, let item else { return }
        var payload: [String: Any] = ["item": item, "itemId": itemID, "locale": locale, "assetBaseURL": "nomad-perseus://local/package/", "hintsVisible": initial?.hintsVisible ?? 0]
        if let initial, let data = initial.answerStateJSON.data(using: .utf8), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { payload["answerState"] = state }
        else { payload["answerState"] = NSNull() }
        Task { @MainActor [weak self, weak view] in
            guard let self, self.active, let view else { return }
            do { _ = try await view.callAsyncJavaScript("return window.NomadPerseus.loadItem(payload);", arguments: ["payload": payload], in: nil, contentWorld: .page) }
            catch { if self.active { self.fail(error.localizedDescription) } }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard active, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "nomad-perseus",
              message.frameInfo.securityOrigin.host == "local", message.frameInfo.request.url?.path == "/renderer/index.html" else { return }
        do {
            switch try CoursePerseusMessage.decode(message.body, itemID: itemID) {
            case .ready: loadItem()
            case .loaded: controller.ready = true
            case .state(let json, let hints):
                pending = (json, hints); saveWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.flush() }; saveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            case .result(let json, let hints, let type, let earned, let total, let message):
                pending = (json, hints); flush()
                onResult(type, earned, total, message, hints)
                controller.feedback = type == "points" ? "Score: \((earned ?? 0).formatted()) / \((total ?? 0).formatted())" : (message ?? "The answer is not ready to score.")
            case .error(let message): fail(message)
            }
        } catch { fail(error.localizedDescription) }
    }
    func flush() {
        saveWork?.cancel(); saveWork = nil
        if let pending { self.pending = nil; onState(pending.0, pending.1) }
    }
    func stop() {
        flush(); active = false; requests.removeAll()
        // Read the current widget state as well as flushing already delivered messages.
        // This covers dismissing immediately after typing, before the renderer's RAF.
        if let view = controller.webView, controller.ready {
            let save = onState, itemID = itemID
            view.evaluateJavaScript("window.NomadPerseus?.getState()") { [view] value, _ in
                defer { view.stopLoading() }
                guard let state = value as? [String: Any], let hints = state["hintsVisible"],
                      let event = try? CoursePerseusMessage.decode(["type": "state", "itemId": itemID, "answerState": state, "hintsVisible": hints], itemID: itemID),
                      case .state(let json, let count) = event else { return }
                save(json, count)
            }
        } else { controller.webView?.stopLoading() }
        controller.ready = false
        controller.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "perseus")
        controller.webView?.navigationDelegate = nil; controller.webView = nil
    }
    private func fail(_ message: String) { controller.error = message; controller.ready = false }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard active, requests.count < 128, let url = urlSchemeTask.request.url, url.scheme == "nomad-perseus", url.host == "local",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding else {
            urlSchemeTask.didFailWithError(CourseError.invalid("Invalid local exercise resource.")); return
        }
        let identity = ObjectIdentifier(urlSchemeTask as AnyObject)
        requests[identity] = urlSchemeTask
        let archive = self.archive, root = rendererRoot
        queue.async { [weak self] in
            let result: Result<(Data, String), Error> = Result {
                let data: Data, name: String
                if path.hasPrefix("/renderer/") {
                    name = String(path.dropFirst("/renderer/".count))
                    guard CourseZipArchive.safePath(name), !name.hasSuffix("/") else { throw CourseError.invalid("Invalid renderer resource path.") }
                    let file = root.appendingPathComponent(name).standardizedFileURL
                    guard file.path.hasPrefix(root.path + "/"), file.resolvingSymlinksInPath().path == file.path else { throw CourseError.invalid("Invalid renderer resource path.") }
                    try CoursePaths.regularFile(file)
                    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 128 * 1_024 * 1_024 else { throw CourseError.invalid("Oversized renderer resource.") }
                    data = try Data(contentsOf: file, options: .mappedIfSafe)
                } else if path.hasPrefix("/package/"), let archive {
                    name = String(path.dropFirst("/package/".count)); data = try archive.read(name)
                } else { throw CourseError.invalid("The exercise requested a resource outside its package.") }
                let ext = (name as NSString).pathExtension.lowercased()
                let type = ["js": "text/javascript", "mjs": "text/javascript", "json": "application/json", "html": "text/html", "css": "text/css", "svg": "image/svg+xml", "woff2": "font/woff2", "graphie": "application/octet-stream"][ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                return (data, type)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, let urlSchemeTask = self.requests.removeValue(forKey: identity) else { return }
                switch result {
                case .success(let (data, type)):
                    let policy = "default-src 'none'; script-src nomad-perseus://local/renderer/ 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' blob:; connect-src 'self'; worker-src 'none'; frame-src 'none'; form-action 'none'; object-src 'none'; base-uri 'none'"
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Content-Security-Policy": policy, "X-Content-Type-Options": "nosniff", "Access-Control-Allow-Origin": "nomad-perseus://local"])!
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                case .failure(let error): urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(active && navigationAction.targetFrame?.isMainFrame == true && url?.scheme == "nomad-perseus" && url?.host == "local" && url?.path == "/renderer/index.html" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if active { fail(error.localizedDescription) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if active { fail(error.localizedDescription) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { fail("The exercise renderer stopped. Reopen the question to restore its last saved answer.") } }
}

#if canImport(UIKit)
struct CoursePerseusView: UIViewRepresentable {
    let controller: CoursePerseusController
    let archiveURL: URL
    let rendererRoot: URL
    let itemID: String
    let locale: String
    let initial: CourseExerciseState?
    let onState: (String, Int) -> Void
    let onResult: (String, Double?, Double?, String?, Int) -> Void
    func makeCoordinator() -> CoursePerseusCoordinator { CoursePerseusCoordinator(controller: controller, archiveURL: archiveURL, rendererRoot: rendererRoot, itemID: itemID, locale: locale, initial: initial, onState: onState, onResult: onResult) }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: context.coordinator.configuration())
        context.coordinator.start(view); return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: CoursePerseusCoordinator) { coordinator.stop() }
}
#endif
