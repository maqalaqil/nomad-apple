import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct CourseHTMLView: UIViewRepresentable {
    let archiveURL: URL
    let initialValues: [String: String]
    let onProgress: ([String: String]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(initialValues: initialValues, onProgress: onProgress, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "nomad-course")
        configuration.userContentController.add(context.coordinator, name: "courseProgress")
        configuration.userContentController.addUserScript(WKUserScript(source: context.coordinator.bootstrap(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = view
        do {
            context.coordinator.archive = try CourseZipArchive(url: archiveURL)
            let entry = try context.coordinator.archive!.entryPoint()
            var components = URLComponents()
            components.scheme = "nomad-course"; components.host = "local"; components.path = "/" + entry
            guard let url = components.url else { throw CourseError.invalid("The course launch path is invalid.") }
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nomad-course-offline-v1", encodedContentRuleList: rules) { list, error in
                guard context.coordinator.active, context.coordinator.webView === view else { return }
                if let list {
                    view.configuration.userContentController.add(list)
                    view.load(URLRequest(url: url))
                } else { onError("The offline content filter could not be prepared. \(error?.localizedDescription ?? "")") }
            }
        } catch { DispatchQueue.main.async { onError(error.localizedDescription) } }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "courseProgress")
        coordinator.webView = nil
    }

    @MainActor final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var active = true
        var archive: CourseZipArchive?
        weak var webView: WKWebView?
        private var values: [String: String]
        private let onProgress: ([String: String]) -> Void
        private let onError: (String) -> Void
        private var changed = false
        private var pendingSave: DispatchWorkItem?
        private var requests: [ObjectIdentifier: WKURLSchemeTask] = [:]
        private let assetQueue = DispatchQueue(label: "nomad.course.html.assets", qos: .userInitiated)
        init(initialValues: [String: String], onProgress: @escaping ([String: String]) -> Void, onError: @escaping (String) -> Void) {
            values = initialValues; self.onProgress = onProgress; self.onError = onError
        }
        func bootstrap() -> String {
            let initial = (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let keys = (try? JSONSerialization.data(withJSONObject: CourseStore.scormKeys.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            (() => {
              const values = \(initial), allowed = new Set(\(keys));
              let lastError = '0';
              function send(op, key, value) { window.webkit.messageHandlers.courseProgress.postMessage({op, key, value}); }
              function get(key) { if (!allowed.has(key)) { lastError='401'; return ''; } lastError='0'; return values[key] || ''; }
              function set(key,value) { value=String(value); if (!allowed.has(key) || value.length>65536) { lastError='401'; return 'false'; } values[key]=value; lastError='0'; send('set',key,value); return 'true'; }
              function commit() { send('commit','',''); return 'true'; }
              const api = {
                LMSInitialize:()=> 'true', LMSFinish:commit, LMSCommit:commit, LMSGetValue:get, LMSSetValue:set,
                LMSGetLastError:()=>lastError, LMSGetErrorString:()=> 'Unsupported field or value', LMSGetDiagnostic:()=> 'NOMAD supports local status, score, location and suspend_data only.'
              };
              window.API=api;
              window.API_1484_11={Initialize:()=> 'true', Terminate:commit, Commit:commit, GetValue:get, SetValue:set,
                GetLastError:()=>lastError, GetErrorString:api.LMSGetErrorString, GetDiagnostic:api.LMSGetDiagnostic};
            })();
            """
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.securityOrigin.protocol == "nomad-course", message.frameInfo.securityOrigin.host == "local",
                  let body = message.body as? [String: String], let op = body["op"] else { return }
            if op == "set", let key = body["key"], CourseStore.scormKeys.contains(key), let value = body["value"], value.utf8.count <= 64 * 1_024 {
                values[key] = value; changed = true
                pendingSave?.cancel()
                let save = DispatchWorkItem { [weak self] in self?.flush() }
                pendingSave = save; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
            } else if op == "commit" { flush() }
        }
        func flush() {
            pendingSave?.cancel(); pendingSave = nil
            if changed { onProgress(values); changed = false }
        }
        func stop() {
            flush(); active = false; requests.removeAll()
        }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard active, requests.count < 128, let url = urlSchemeTask.request.url, url.scheme == "nomad-course", url.host == "local",
                  let archive, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding else {
                urlSchemeTask.didFailWithError(CourseError.invalid("The course requested an invalid or excessive local resource.")); return
            }
            let identity = ObjectIdentifier(urlSchemeTask as AnyObject)
            requests[identity] = urlSchemeTask
            assetQueue.async { [weak self] in
                let name = String(path.dropFirst())
                let result = Result { try archive.read(name) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, let urlSchemeTask = self.requests.removeValue(forKey: identity) else { return }
                    switch result {
                    case .success(let data):
                        let type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                        let policy = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; connect-src 'self'; form-action 'none'; object-src 'none'; base-uri 'self'"
                        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Content-Security-Policy": policy, "X-Content-Type-Options": "nosniff"])!
                        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                    case .failure(let error): urlSchemeTask.didFailWithError(error)
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject)) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(active && url?.scheme == "nomad-course" && url?.host == "local" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if active { onError(error.localizedDescription) } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if active { onError(error.localizedDescription) } }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { onError("The lesson renderer stopped. Reopen the lesson to restore its last saved progress.") } }
    }
}
