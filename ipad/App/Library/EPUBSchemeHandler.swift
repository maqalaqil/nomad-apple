import Foundation
import WebKit

@MainActor
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    private let worker: EPUBResourceWorker
    init(archive: EPUBArchive) { worker = EPUBResourceWorker(archive: archive) }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) { worker.start(EPUBResourceRequest(task: urlSchemeTask)) }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { worker.stop(ObjectIdentifier(urlSchemeTask)) }
}

private final class EPUBResourceWorker: @unchecked Sendable {
    let archive: EPUBArchive
    private let queue = DispatchQueue(label: "org.projectnomad.epub.resources", qos: .userInitiated)
    private let lock = NSLock()
    private var active: [ObjectIdentifier: UUID] = [:]
    init(archive: EPUBArchive) { self.archive = archive }
    func stop(_ id: ObjectIdentifier) { lock.lock(); active.removeValue(forKey: id); lock.unlock() }
    func isActive(_ id: ObjectIdentifier, _ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active[id] == token }
    func start(_ request: EPUBResourceRequest) {
        let id = request.id, token = UUID()
        lock.lock(); active[id] = token; lock.unlock()
        queue.async { [self, request] in
            defer { lock.lock(); if active[id] == token { active.removeValue(forKey: id) }; lock.unlock() }
            guard isActive(id, token) else { return }
            do {
                guard let url = request.url, url.scheme == "nomadepub", url.host == "book" else { throw URLError(.unsupportedURL) }
                let path = String(url.path.dropFirst())
                var data = try archive.data(path: path)
                let mime = archive.mimeType(path)
                let html = mime == "application/xhtml+xml" || mime == "text/html"
                if html { data = try Self.protectHTML(data, path: path) }
                let response = URLResponse(url: url, mimeType: html ? "text/html" : mime, expectedContentLength: data.count, textEncodingName: html ? "utf-8" : nil)
                deliver(id, token) { request.receive(response) }
                var offset = 0
                while offset < data.count {
                    guard isActive(id, token) else { return }
                    let end = min(data.count, offset + 256 * 1_024), chunk = data.subdata(in: offset..<min(data.count, offset + 256 * 1_024))
                    deliver(id, token) { request.receive(chunk) }
                    offset = end
                }
                deliver(id, token) { request.finish() }
            } catch { deliver(id, token) { request.fail(error) } }
        }
    }
    private func deliver(_ id: ObjectIdentifier, _ token: UUID, action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.sync { if self.isActive(id, token) { action() } }
    }
    private static func protectHTML(_ data: Data, path: String) throws -> Data {
        guard data.count <= 16 * 1_024 * 1_024 else { throw EPUBFailure(message: "This chapter exceeds the reader's 16 MB HTML limit.") }
        guard var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw EPUBFailure(message: "This chapter uses an unsupported text encoding.")
        }
        let base = EPUBArchive.url(path: path)!.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let policy = "default-src 'none'; img-src nomadepub: data:; style-src nomadepub: 'unsafe-inline'; font-src nomadepub: data:; media-src nomadepub: data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri nomadepub:"
        let protection = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><base href=\"\(base)\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>html{color-scheme:light dark}body{overflow-wrap:break-word;padding:16px;line-height:1.5}img,svg,video{max-width:100%;height:auto}</style>"
        if let range = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) { html.insert(contentsOf: protection, at: range.upperBound) }
        else { html = "<head>\(protection)</head>" + html }
        return Data(html.utf8)
    }
}

private final class EPUBResourceRequest: @unchecked Sendable {
    let id: ObjectIdentifier
    let url: URL?
    private let task: any WKURLSchemeTask
    @MainActor init(task: any WKURLSchemeTask) { self.task = task; id = ObjectIdentifier(task); url = task.request.url }
    @MainActor func receive(_ response: URLResponse) { task.didReceive(response) }
    @MainActor func receive(_ data: Data) { task.didReceive(data) }
    @MainActor func finish() { task.didFinish() }
    @MainActor func fail(_ error: Error) { task.didFailWithError(error) }
}
