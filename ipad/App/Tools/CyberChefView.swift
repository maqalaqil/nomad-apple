import SwiftUI
import WebKit
import UniformTypeIdentifiers
import UIKit

struct ToolWebExport: Identifiable {
    let id = UUID()
    let url: URL
}

struct ToolWebDialog {
    enum Kind { case alert, confirm, prompt }
    let kind: Kind
    let message: String
    let completion: (String?) -> Void
}

@MainActor
final class ToolCyberChefController: ObservableObject {
    let applicationName: String
    @Published var loading = true
    @Published var error: String?
    @Published var export: ToolWebExport?
    @Published var importing = false
    @Published var allowsMultipleImports = true
    @Published var importsDirectories = false
    @Published var dialog: ToolWebDialog?
    @Published var dialogPresented = false
    @Published var dialogText = ""
    fileprivate var importCompletion: (([URL]?) -> Void)?
    fileprivate var importedCopies: [URL] = []
    fileprivate weak var webView: WKWebView?
    private var pendingExports: [URL] = []

    init(applicationName: String = "CyberChef") { self.applicationName = applicationName }

    func offerExport(_ url: URL) {
        if export == nil { export = ToolWebExport(url: url) }
        else { pendingExports.append(url) }
    }

    func finishExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if !pendingExports.isEmpty {
            let next = pendingExports.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.export = ToolWebExport(url: next) }
        }
    }

    func answerDialog(_ value: String?) {
        let completion = dialog?.completion
        dialog = nil
        dialogPresented = false
        completion?(value)
    }

    func finishImport(_ result: Result<[URL], Error>) {
        let completion = importCompletion
        importCompletion = nil
        do {
            let urls = try result.get()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CyberChef-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            importedCopies.append(directory)
            var copies: [URL] = []
            for (index, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let subdirectory = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
                let copy = subdirectory.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                copies.append(copy)
            }
            completion?(copies)
        } catch {
            self.error = "Could not import into \(applicationName): \(error.localizedDescription)"
            completion?(nil)
        }
    }

    func cancelImport() {
        importCompletion?(nil)
        importCompletion = nil
    }

    func cleanupImports() {
        cancelImport()
        answerDialog(nil)
        for directory in importedCopies { try? FileManager.default.removeItem(at: directory) }
        importedCopies = []
    }
}

struct CyberChefView: View {
    @StateObject private var controller = ToolCyberChefController()
    @State private var showInformation = false
    private var resourceDirectory: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return [root.appendingPathComponent("Resources/WebTools/CyberChef", isDirectory: true),
                root.appendingPathComponent("WebTools/CyberChef", isDirectory: true)]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    var body: some View {
        Group {
            if let directory = resourceDirectory {
                ZStack(alignment: .top) {
                    ToolCyberChefWebView(directory: directory, controller: controller)
                    if controller.loading {
                        ProgressView("Loading bundled CyberChef…")
                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("CyberChef assets not bundled", systemImage: "shippingbox")
                } description: {
                    Text("This build is missing the offline CyberChef distribution. Run ipad/scripts/fetch-web-tools.py before rebuilding the app. No website is loaded as a fallback.")
                }
            }
        }
        .navigationTitle("CyberChef")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Offline information", systemImage: "info.circle") { showInformation = true }
            }
        }
        .sheet(isPresented: $showInformation) {
            NavigationStack {
                List {
                    Section("Complete bundled distribution") {
                        Text("CyberChef v11.5.0 · GCHQ · Apache 2.0")
                        Text("The complete upstream release and its operation catalog are stored inside this app. The desktop interface works best with the iPad in landscape.")
                    }
                    Section("Offline behavior") {
                        Text("Remote requests and external navigation are blocked. HTTP Request, DNS over HTTPS, online map tiles, and operations requiring remote resources cannot work in this offline workspace.")
                        Text("Use CyberChef's Open File control to import through Files. Save output and recipe downloads open the iPad share sheet; choose Save to Files to keep them.")
                        Text("Recipes saved in CyberChef use local web storage. Export important recipes and output before clearing app data or reinstalling. Large recipes are limited by WebKit memory.")
                    }
                    Section("Compatibility") {
                        Text("All upstream operations are included, but operation-by-operation iPad compatibility has not been established. Browser permissions, WebAssembly, file access, and worker requirements can differ from a desktop browser. A visible error should be treated as an unsupported operation, not a successful result.")
                    }
                }
                .navigationTitle("Offline CyberChef")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInformation = false } } }
            }
        }
        .fileImporter(isPresented: $controller.importing,
                      allowedContentTypes: controller.importsDirectories ? [.folder] : [.item],
                      allowsMultipleSelection: controller.allowsMultipleImports,
                      onCompletion: controller.finishImport,
                      onCancellation: controller.cancelImport)
        .sheet(item: $controller.export) { exported in
            ToolCyberChefShareSheet(url: exported.url)
                .onDisappear { controller.finishExport(exported.url) }
        }
        .alert("CyberChef message", isPresented: $controller.dialogPresented, presenting: controller.dialog) { dialog in
            if dialog.kind == .prompt { TextField("Response", text: $controller.dialogText) }
            Button("OK") { controller.answerDialog(dialog.kind == .prompt ? controller.dialogText : "yes") }
            if dialog.kind != .alert { Button("Cancel", role: .cancel) { controller.answerDialog(nil) } }
        } message: { dialog in Text(dialog.message) }
        .alert("CyberChef", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .onDisappear { controller.cleanupImports() }
    }
}

struct ToolCyberChefShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ToolCyberChefWebView: UIViewRepresentable {
    let directory: URL
    @ObservedObject var controller: ToolCyberChefController
    var useLocalScheme = false

    func makeCoordinator() -> Coordinator { Coordinator(directory: directory, controller: controller) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if useLocalScheme { configuration.setURLSchemeHandler(ToolLocalAssetHandler(directory: directory), forURLScheme: "nomad-local") }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        controller.webView = webView
        // The content rule list also applies to subresources. CSP in index.html
        // constrains worker and document requests to local/blob/data resources.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadCyberChefOffline-v1", encodedContentRuleList: rules) { ruleList, error in
            Task { @MainActor in
                guard let ruleList else {
                    controller.loading = false
                    controller.error = "Could not establish offline request blocking: \(error?.localizedDescription ?? "unknown error")"
                    return
                }
                configuration.userContentController.add(ruleList)
                if useLocalScheme {
                    guard let url = URL(string: "nomad-local://\(directory.lastPathComponent.lowercased())/") else { return }
                    webView.load(URLRequest(url: url))
                } else {
                    webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
                }
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.controller.cleanupImports()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let directory: URL
        let controller: ToolCyberChefController
        private var downloadLocations: [ObjectIdentifier: URL] = [:]
        init(directory: URL, controller: ToolCyberChefController) { self.directory = directory; self.controller = controller }

        private func isLocal(_ url: URL?) -> Bool {
            guard let url else { return false }
            if url.scheme == "nomad-local", url.host == directory.lastPathComponent.lowercased() { return true }
            if url.scheme == "blob" || url.scheme == "data" || url.absoluteString == "about:blank" { return true }
            guard url.isFileURL else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard isLocal(navigationAction.request.url) else {
                controller.error = "External links and network requests are unavailable in this offline workspace."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard isLocal(navigationResponse.response.url) else { decisionHandler(.cancel); return }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { controller.loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            controller.loading = false
            controller.error = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.loading = false
            controller.error = error.localizedDescription
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            controller.loading = false
            controller.error = "WebKit stopped the \(controller.applicationName) process, possibly because it used too much memory. Reopen the tool and use a smaller input. Unsaved work may have been lost."
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard isLocal(navigationAction.request.url) else {
                controller.error = "External links are disabled in this offline workspace."
                return nil
            }
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            controller.cancelImport()
            controller.allowsMultipleImports = parameters.allowsMultipleSelection
            controller.importsDirectories = parameters.allowsDirectories
            controller.importCompletion = completionHandler
            controller.importing = true
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            // Missing privacy strings must fail visibly instead of terminating the app.
            let camera = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
            let microphone = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
            guard camera?.isEmpty == false, microphone?.isEmpty == false else {
                controller.error = "This build has not enabled camera/microphone access. Other offline tools remain available."
                decisionHandler(.deny); return
            }
            decisionHandler(.prompt)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            controller.answerDialog(nil)
            controller.dialog = ToolWebDialog(kind: .alert, message: message) { _ in completionHandler() }
            controller.dialogPresented = true
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            controller.answerDialog(nil)
            controller.dialog = ToolWebDialog(kind: .confirm, message: message) { completionHandler($0 != nil) }
            controller.dialogPresented = true
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            controller.answerDialog(nil)
            controller.dialogText = defaultText ?? ""
            controller.dialog = ToolWebDialog(kind: .prompt, message: prompt, completion: completionHandler)
            controller.dialogPresented = true
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CyberChef-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let basename = (suggestedFilename as NSString).lastPathComponent
                let name = basename.isEmpty || basename == "." || basename == ".." ? "cyberchef-output.bin" : basename
                let url = folder.appendingPathComponent(name)
                downloadLocations[ObjectIdentifier(download)] = url
                completionHandler(url)
            } catch { controller.error = error.localizedDescription; completionHandler(nil) }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = downloadLocations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            controller.offerExport(url)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let url = downloadLocations.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            controller.error = "Could not export output: \(error.localizedDescription)"
        }

        func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
            decisionHandler(.cancel)
        }
    }
}

/// A stable local origin supports SPA routes and ES modules without a network server.
final class ToolLocalAssetHandler: NSObject, WKURLSchemeHandler {
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.host == directory.lastPathComponent.lowercased() else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let path = requestURL.path.isEmpty || requestURL.path == "/" ? "index.html" : String(requestURL.path.dropFirst())
        var file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/") else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        if !FileManager.default.fileExists(atPath: file.path), file.pathExtension.isEmpty {
            file = directory.appendingPathComponent("index.html")
        }
        do {
            let data = try Data(contentsOf: file)
            let types = ["js": "application/javascript", "mjs": "application/javascript", "html": "text/html", "css": "text/css", "json": "application/json", "wasm": "application/wasm", "svg": "image/svg+xml", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "webmanifest": "application/manifest+json"]
            let mime = types[file.pathExtension.lowercased()] ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]) else { throw URLError(.badServerResponse) }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
