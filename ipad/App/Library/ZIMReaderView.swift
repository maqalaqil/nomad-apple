import SwiftUI
import WebKit

// The bridge synchronizes every archive operation with @synchronized and exposes immutable metadata.
extension NomadZIMArchive: @unchecked Sendable {}

private struct ZIMArticle: Identifiable, Sendable {
    let path: String
    let title: String
    let snippet: String
    var id: String { path }
}

@MainActor
struct ZIMReaderView: View {
    let url: URL
    @State private var archive: NomadZIMArchive?
    @State private var query = ""
    @State private var fullText = false
    @State private var articles: [ZIMArticle] = []
    @State private var selectedPath: String?
    @State private var mainPath: String?
    @State private var errorMessage: String?
    @State private var searching = false
    @State private var showingSearch = true
    @State private var translation = ZIMArticleTranslation()
    @State private var showingTranslation = false

    var body: some View {
        Group {
            if let archive {
                VStack(spacing: 0) {
                    HStack {
                        Button { showingSearch.toggle() } label: { Label("Articles", systemImage: "list.bullet") }
                        if let mainPath { Button { selectedPath = mainPath; showingSearch = false } label: { Label("Home", systemImage: "house") } }
                        if !showingSearch {
                            Button { showingTranslation = true } label: { Label("Translate", systemImage: "character.bubble") }.disabled(!translation.ready)
                        }
                        Spacer()
                        Text("\(archive.articleCount.formatted()) articles · offline").font(.caption).foregroundStyle(.secondary)
                    }.padding()
                    Divider()
                    if translation.busy {
                        HStack { ProgressView(translation.progress); Button("Cancel") { translation.cancel() } }.padding(.horizontal)
                    } else if translation.translated {
                        HStack {
                            Text("Translated display · archived original unchanged").font(.caption).foregroundStyle(.secondary)
                            Button("Restore original") { translation.restore() }
                        }.padding(.horizontal)
                    }
                    if showingSearch {
                        HStack {
                            TextField("Search this archive", text: $query).textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            if searching { ProgressView() }
                        }.padding(.horizontal).padding(.top)
                        Picker("Search mode", selection: $fullText) {
                            Text("Titles").tag(false)
                            Text("Full text").tag(true)
                        }.pickerStyle(.segmented).padding(.horizontal).disabled(!archive.hasFullTextIndex)
                        if !archive.hasFullTextIndex {
                            Text("This archive has no full-text index. Title search remains available.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        }
                        List(articles) { article in
                            Button {
                                selectedPath = article.path
                                showingSearch = false
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(article.title).font(.headline).foregroundStyle(.primary)
                                    if !article.snippet.isEmpty {
                                        Text(article.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }
                        }.overlay {
                            if articles.isEmpty && !searching { ContentUnavailableView.search(text: query) }
                        }
                    } else if let selectedPath {
                        ZIMWebContent(archive: archive, path: selectedPath, translation: translation, onError: { errorMessage = $0 })
                    } else {
                        ContentUnavailableView("Select an article", systemImage: "book")
                    }
                }
                .task(id: "\(query)|\(fullText)") { await search(archive: archive) }
            } else if let errorMessage {
                ContentUnavailableView("Cannot open this ZIM", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else { ProgressView("Opening local archive…") }
        }
        .task {
            guard archive == nil else { return }
            do {
                let opened = try await Task.detached(priority: .userInitiated) { try NomadZIMArchive(url: url) }.value
                archive = opened
                mainPath = try? opened.mainPath()
                selectedPath = mainPath
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Archive reader", isPresented: Binding(get: { archive != nil && errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .sheet(isPresented: $showingTranslation) { ZIMTranslationPanel(translation: translation) }
    }

    private func search(archive: NomadZIMArchive) async {
        searching = true
        do {
            try await Task.sleep(for: .milliseconds(250))
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullText = fullText
            let results = try await Task.detached(priority: .userInitiated) {
                try archive.search(query, fullText: fullText, limit: 50).compactMap { row -> ZIMArticle? in
                    guard let path = row["path"] as? String else { return nil }
                    let snippet = (row["snippet"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    return ZIMArticle(path: path, title: row["title"] as? String ?? path, snippet: snippet)
                }
            }.value
            try Task.checkCancellation()
            articles = results
            searching = false
        } catch is CancellationError {
            // A replacement search owns the progress indicator.
        } catch {
            searching = false
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct ZIMWebContent: UIViewRepresentable {
    let archive: NomadZIMArchive
    let path: String
    let translation: ZIMArticleTranslation
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(archive: archive, translation: translation, onError: onError) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "nomadzim")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        // Do not load any archive content until the network-denial rule has compiled.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadZIMOfflineOnly-v1", encodedContentRuleList: rules) { list, error in
            guard let list else {
                onError("Offline content protection could not be initialized: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            view.configuration.userContentController.add(list)
            context.coordinator.ready = true
            context.coordinator.load(path: path, in: view)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.ready { context.coordinator.load(path: path, in: view) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        coordinator.translation.detach(view)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let handler: ZIMSchemeHandler
        let onError: (String) -> Void
        let translation: ZIMArticleTranslation
        var ready = false
        private var requestedPath: String?

        init(archive: NomadZIMArchive, translation: ZIMArticleTranslation, onError: @escaping (String) -> Void) {
            handler = ZIMSchemeHandler(archive: archive)
            self.translation = translation
            self.onError = onError
        }

        func load(path: String, in view: WKWebView) {
            guard requestedPath != path, let url = ZIMSchemeHandler.url(path: path) else { return }
            requestedPath = path
            view.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            guard url?.scheme == "nomadzim", url?.host == "archive" else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated { onError("External links are disabled in the offline reader.") }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { translation.navigationStarted() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { translation.attach(webView) }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}
