import SwiftUI
import WebKit

private struct EPUBReadingPosition: Codable {
    let path: String
    let fragment: String?
    let fraction: Double
}

@MainActor
struct EPUBReaderView: View {
    let url: URL
    @State private var archive: EPUBArchive?
    @State private var selected: EPUBChapter?
    @State private var currentPath = ""
    @State private var currentFragment: String?
    @State private var currentFraction: Double = 0
    @State private var restoredFraction: Double = 0
    @State private var showingContents = false
    @State private var errorMessage: String?
    @State private var findRequest = 0
    @State private var navigationRequest = 0
    @State private var readerActions = EPUBReaderActions()
    @State private var showingMarks = false
    @State private var editingMark: ReadingMark?
    @AppStorage("epub.reader.zoom") private var zoom = 1.0
    private var positionKey: String { "epub.position." + url.lastPathComponent }

    var body: some View {
        Group {
            if let archive, let selected {
                VStack(spacing: 0) {
                    HStack {
                        Button { showingContents = true } label: { Label("Contents", systemImage: "list.bullet") }
                        Button { findRequest += 1 } label: { Label("Find in chapter", systemImage: "magnifyingglass") }
                        Menu {
                            Button("Bookmark this position", systemImage: "bookmark") { Task { await createMark(archive, edit: false) } }.disabled(!readerActions.ready)
                            Button("Add note at this position", systemImage: "square.and.pencil") { Task { await createMark(archive, edit: true) } }.disabled(!readerActions.ready)
                            Button("Bookmarks and notes", systemImage: "list.bullet.rectangle") { showingMarks = true }
                        } label: { Label("Reading marks", systemImage: "bookmark") }
                        Spacer()
                        Menu {
                            ForEach([0.85, 1.0, 1.15, 1.3, 1.5, 1.75], id: \.self) { value in
                                Button("\(Int(value * 100))%") { zoom = value }
                            }
                        } label: { Label("Text size", systemImage: "textformat.size") }
                    }.padding()
                    Divider()
                    EPUBWebContent(archive: archive, chapter: selected, navigationRequest: navigationRequest, initialFraction: restoredFraction, zoom: zoom, findRequest: findRequest, actions: readerActions,
                        onPosition: { path, fragment, fraction in
                            currentPath = path
                            currentFragment = fragment; currentFraction = fraction
                            let position = EPUBReadingPosition(path: path, fragment: fragment, fraction: fraction)
                            if let data = try? JSONEncoder().encode(position) { UserDefaults.standard.set(data, forKey: positionKey) }
                        }, onError: { errorMessage = $0 })
                    Divider()
                    HStack {
                        Button { step(-1, archive: archive) } label: { Label("Previous", systemImage: "chevron.left") }
                            .disabled(chapterIndex(archive) <= 0)
                        Spacer()
                        Text("\(chapterIndex(archive) + 1) of \(archive.chapters.count) · offline").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { step(1, archive: archive) } label: { Label("Next", systemImage: "chevron.right") }
                            .disabled(chapterIndex(archive) >= archive.chapters.count - 1)
                    }.padding()
                }
                .sheet(isPresented: $showingContents) {
                    NavigationStack {
                        List(Array(archive.contents.enumerated()), id: \.offset) { _, chapter in
                            Button(chapter.title) { restoredFraction = 0; self.selected = chapter; currentPath = chapter.path; navigationRequest += 1; showingContents = false }
                                .foregroundStyle(.primary)
                        }
                        .navigationTitle(archive.title)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingContents = false } } }
                    }
                }
                .sheet(isPresented: $showingMarks) {
                    NavigationStack {
                        ReadingMarksView(bookKey: url.lastPathComponent) { mark in
                            guard archive.contains(mark.chapterPath) else { errorMessage = "This saved location is not present in the current book."; return }
                            restoredFraction = mark.fraction
                            self.selected = EPUBChapter(title: mark.title, path: mark.chapterPath, fragment: mark.fragment)
                            currentPath = mark.chapterPath; currentFragment = mark.fragment; currentFraction = mark.fraction
                            navigationRequest += 1; showingMarks = false
                        }
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMarks = false } } }
                    }
                }
                .sheet(item: $editingMark) { mark in ReadingMarkEditor(mark: mark) }
            } else if let errorMessage {
                ContentUnavailableView("Cannot open this EPUB", systemImage: "book.closed", description: Text(errorMessage))
            } else { ProgressView("Opening local book…") }
        }
        .task {
            guard archive == nil else { return }
            do {
                let book = try await Task.detached(priority: .userInitiated) { try EPUBArchive(url: url) }.value
                let saved = UserDefaults.standard.data(forKey: positionKey).flatMap { try? JSONDecoder().decode(EPUBReadingPosition.self, from: $0) }
                if let saved, book.contains(saved.path), saved.fraction.isFinite {
                    selected = EPUBChapter(title: book.title, path: saved.path, fragment: saved.fragment)
                    restoredFraction = min(1, max(0, saved.fraction))
                } else { selected = book.chapters.first }
                currentPath = selected?.path ?? ""
                currentFragment = selected?.fragment; currentFraction = restoredFraction
                archive = book
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Book reader", isPresented: Binding(get: { archive != nil && errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    private func chapterIndex(_ archive: EPUBArchive) -> Int { archive.chapters.firstIndex(where: { $0.path == currentPath }) ?? 0 }
    private func step(_ change: Int, archive: EPUBArchive) {
        let index = min(archive.chapters.count - 1, max(0, chapterIndex(archive) + change))
        restoredFraction = 0; selected = archive.chapters[index]; currentPath = archive.chapters[index].path; navigationRequest += 1
    }
    private func createMark(_ archive: EPUBArchive, edit: Bool) async {
        guard readerActions.ready, archive.contains(currentPath) else { return }
        let path = currentPath, fragment = currentFragment, fraction = currentFraction
        do {
            let quote = try await readerActions.selectedText()
            guard currentPath == path, readerActions.ready else { throw ReadingMarkError.message("The chapter changed before the mark was created. Try again.") }
            let chapterTitle = archive.chapters.first(where: { $0.path == path })?.title ?? archive.title
            let mark = ReadingMark(id: UUID(), bookKey: url.lastPathComponent, bookTitle: String(archive.title.prefix(512)),
                chapterPath: path, fragment: fragment, fraction: fraction, title: String(chapterTitle.prefix(200)),
                quote: quote, note: "", createdAt: Date(), updatedAt: Date())
            if edit { editingMark = mark }
            else { try ReadingMarkStore.shared.save(mark); showingMarks = true }
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct EPUBWebContent: UIViewRepresentable {
    let archive: EPUBArchive
    let chapter: EPUBChapter
    let navigationRequest: Int
    let initialFraction: Double
    let zoom: Double
    let findRequest: Int
    let actions: EPUBReaderActions
    let onPosition: (String, String?, Double) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(archive: archive, initialFraction: initialFraction, actions: actions, onPosition: onPosition, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "nomadepub")
        context.coordinator.pendingChapter = chapter
        context.coordinator.pendingRequest = navigationRequest
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        view.isFindInteractionEnabled = true
        view.allowsBackForwardNavigationGestures = true
        view.pageZoom = zoom
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadEPUBOfflineOnly-v1", encodedContentRuleList: rules) { list, error in
            guard let list else { onError("Offline reader protection could not start: \(error?.localizedDescription ?? "unknown error")"); return }
            view.configuration.userContentController.add(list)
            context.coordinator.ready = true
            if let pending = context.coordinator.pendingChapter { context.coordinator.load(pending, request: context.coordinator.pendingRequest, fraction: initialFraction, in: view) }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.pageZoom = zoom
        context.coordinator.pendingChapter = chapter
        context.coordinator.pendingRequest = navigationRequest
        if context.coordinator.ready { context.coordinator.load(chapter, request: navigationRequest, fraction: initialFraction, in: view) }
        if findRequest != context.coordinator.findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.save(view.scrollView)
        view.stopLoading()
        coordinator.actions.detach(view)
        view.scrollView.delegate = nil
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        let handler: EPUBSchemeHandler
        let archive: EPUBArchive
        let onPosition: (String, String?, Double) -> Void
        let onError: (String) -> Void
        let actions: EPUBReaderActions
        var ready = false, findRequest = 0
        var pendingChapter: EPUBChapter?
        var pendingRequest = 0
        private var lastRequested: String?
        private var lastNavigationRequest = -1
        private var currentURL: URL?
        private var initialFraction: Double?
        private var loading = true
        init(archive: EPUBArchive, initialFraction: Double, actions: EPUBReaderActions, onPosition: @escaping (String, String?, Double) -> Void, onError: @escaping (String) -> Void) {
            self.archive = archive; handler = EPUBSchemeHandler(archive: archive)
            self.actions = actions
            self.initialFraction = initialFraction; self.onPosition = onPosition; self.onError = onError
        }
        func load(_ chapter: EPUBChapter, request: Int, fraction: Double, in view: WKWebView) {
            guard lastRequested != chapter.id || lastNavigationRequest != request else { return }
            guard let url = EPUBArchive.url(path: chapter.path, fragment: chapter.fragment) else { return }
            save(view.scrollView)
            initialFraction = min(1, max(0, fraction))
            lastRequested = chapter.id; lastNavigationRequest = request; loading = true
            actions.loading()
            view.load(URLRequest(url: url))
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.scheme == "nomadepub", url.host == "book", archive.contains(String(url.path.dropFirst())) else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated { onError("This link is outside the saved book. External links remain blocked in the offline reader.") }
                return
            }
            if navigationAction.targetFrame == nil { webView.load(URLRequest(url: url)); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; actions.loading() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            currentURL = webView.url
            let restore = initialFraction
            initialFraction = nil
            if let restore, restore > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webView] in
                    guard let self, let webView, self.currentURL == webView.url else { return }
                    let maximum = max(0, webView.scrollView.contentSize.height - webView.scrollView.bounds.height)
                    webView.scrollView.setContentOffset(CGPoint(x: 0, y: maximum * restore), animated: false)
                    self.loading = false; self.save(webView.scrollView); self.actions.attach(webView)
                }
            } else { loading = false; save(webView.scrollView); actions.attach(webView) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false; onError(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { loading = false; onError(error.localizedDescription) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { save(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { save(scrollView) } }
        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { save(scrollView) }
        func save(_ scrollView: UIScrollView) {
            guard !loading, let url = currentURL else { return }
            let maximum = max(1, scrollView.contentSize.height - scrollView.bounds.height)
            onPosition(String(url.path.dropFirst()), url.fragment, min(1, max(0, scrollView.contentOffset.y / maximum)))
        }
    }
}
