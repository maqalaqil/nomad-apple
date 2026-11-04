import Foundation
import Observation
import WebKit
@preconcurrency import Translation

@MainActor @Observable
final class ZIMArticleTranslation {
    private(set) var ready = false
    private(set) var busy = false
    private(set) var translated = false
    private(set) var progress = ""
    private(set) var notice = ""
    var error: String?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: TranslationSession?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private let world = WKContentWorld.world(name: "org.projectnomad.article-translation")

    func attach(_ view: WKWebView) { webView = view; ready = true }
    func navigationStarted() {
        cancel(); ready = false; translated = false; notice = ""; error = nil
    }
    func detach(_ view: WKWebView) {
        if webView === view { navigationStarted(); webView = nil }
    }
    func cancel() {
        let wasBusy = busy
        task?.cancel(); session?.cancel(); task = nil; session = nil
        operation = UUID(); busy = false; progress = ""
        if wasBusy, let webView {
            // Queue restoration after any in-flight DOM operation. This also
            // invalidates its snapshot so a stale apply cannot commit later.
            webView.callAsyncJavaScript(ZIMTranslationDOM.restore, arguments: [:], in: nil, in: world) { _ in }
            translated = false; notice = "Translation stopped."
        }
    }
    func translate(source: String, target: String) {
        guard ready, !busy, !translated, let view = webView else { return }
        guard source != target else { error = "Choose two different languages."; return }
        let token = UUID()
        operation = token; busy = true; progress = "Checking installed languages…"; error = nil; notice = ""
        task = Task {
            defer {
                if operation == token { busy = false; progress = ""; session = nil; task = nil }
            }
            do {
                let translator = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
                session = translator
                guard !translator.canRequestDownloads, await translator.isReady else {
                    throw ZIMTranslationError.message("This language pair is not installed. Prepare it while online, then use Translate article again.")
                }
                try Task.checkCancellation()
                let texts = try await capture(view, token: token.uuidString)
                var results = Array(repeating: "", count: texts.count)
                var translatedBytes = 0
                for start in stride(from: 0, to: texts.count, by: 20) {
                    try Task.checkCancellation()
                    guard operation == token, webView === view, ready else { throw CancellationError() }
                    progress = "Translating \(start + 1)–\(min(start + 20, texts.count)) of \(texts.count) text runs…"
                    let end = min(start + 20, texts.count)
                    let batch = (start..<end).map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
                    let responses = try await translator.translations(from: batch)
                    var seen: Set<Int> = []
                    for response in responses {
                        guard let identifier = response.clientIdentifier, let index = Int(identifier), (start..<end).contains(index),
                              seen.insert(index).inserted, !response.targetText.isEmpty, response.targetText.utf8.count <= 32_000 else {
                            throw ZIMTranslationError.message("The translation service returned an incomplete or invalid text batch. The article was not changed.")
                        }
                        results[index] = response.targetText
                        translatedBytes += response.targetText.utf8.count
                        guard translatedBytes <= 512_000 else { throw ZIMTranslationError.message("The translated text exceeded the article limit. The original was kept.") }
                    }
                    guard seen.count == end - start else { throw ZIMTranslationError.message("Some article text was not translated. The original was kept.") }
                }
                try Task.checkCancellation()
                guard operation == token, webView === view, ready else { throw CancellationError() }
                try await run(view, script: ZIMTranslationDOM.apply, arguments: ["token": token.uuidString, "values": results, "target": target,
                    "rtl": Locale.Language(identifier: target).characterDirection == .rightToLeft])
                guard operation == token else { return }
                translated = true
                notice = "Translated with installed Apple language models. Links, images and archive files remain intact. Restore original to compare."
            } catch {
                if operation == token, !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func restore() {
        guard !busy, let view = webView, ready else { return }
        let token = UUID(); operation = token; busy = true
        task = Task {
            defer { if operation == token { busy = false; task = nil } }
            do {
                try await run(view, script: ZIMTranslationDOM.restore)
                guard operation == token else { return }
                translated = false; notice = "Original article restored."
            } catch { if operation == token { self.error = error.localizedDescription } }
        }
    }
    private func capture(_ view: WKWebView, token: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(ZIMTranslationDOM.capture, arguments: ["token": token], in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    guard let strings = value as? [String], !strings.isEmpty, strings.count <= 512 else {
                        continuation.resume(throwing: ZIMTranslationError.message("The article did not return readable text.")); return
                    }
                    continuation.resume(returning: strings)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func run(_ view: WKWebView, script: String, arguments: [String: Any] = [:]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    if value as? Bool == true { continuation.resume() }
                    else { continuation.resume(throwing: ZIMTranslationError.message("The article could not be updated.")) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ZIMTranslationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
