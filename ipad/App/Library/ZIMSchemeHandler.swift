import Foundation
import WebKit

/// Serves only archive entries. No filesystem URL, HTTP proxy, or native JavaScript bridge is exposed.
final class ZIMSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let archive: NomadZIMArchive
    private let queue = DispatchQueue(label: "org.projectnomad.zim.resources", qos: .userInitiated)
    private let lock = NSLock()
    // Access is protected by lock, including cancellation and worker completion.
    nonisolated(unsafe) private var active: [ObjectIdentifier: UUID] = [:]

    init(archive: NomadZIMArchive) { self.archive = archive }

    nonisolated static func url(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "nomadzim"
        components.host = "archive"
        components.path = "/" + path
        return components.url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let token = UUID()
        lock.lock(); active[id] = token; lock.unlock()
        let request = ZIMSchemeRequest(task: urlSchemeTask)
        queue.async { [self, request] in
            do {
                guard let url = request.request.url, url.scheme == "nomadzim", url.host == "archive" else {
                    throw URLError(.unsupportedURL)
                }
                let path = String(url.path.dropFirst())
                guard !path.isEmpty, !path.contains("\0") else { throw URLError(.badURL) }
                let metadata = try archive.metadata(path: path)
                let mime = metadata["mime"] as? String ?? "application/octet-stream"
                let size = (metadata["size"] as? NSNumber)?.uint64Value ?? 0
                let canonicalPath = metadata["path"] as? String ?? path

                if mime.lowercased().contains("text/html") {
                    guard size <= 16 * 1_024 * 1_024 else {
                        throw NSError(domain: "NomadZIM", code: 2, userInfo: [NSLocalizedDescriptionKey: "This HTML article exceeds the reader's 16 MB safety limit."])
                    }
                    var bytes = Data()
                    var offset: UInt64 = 0
                    while offset < size {
                        guard isActive(id, token) else { return }
                        let chunk = try archive.read(path: path, offset: offset, length: 256 * 1_024)
                        guard !chunk.isEmpty else { throw URLError(.cannotDecodeContentData) }
                        bytes.append(chunk)
                        offset += UInt64(chunk.count)
                    }
                    let html = Self.protectedHTML(bytes, path: canonicalPath)
                    deliver( id: id, token: token) {
                        request.receive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: html.count, textEncodingName: "utf-8"))
                        request.receive(html)
                        request.finish()
                    }
                } else {
                    // Resources stream in bounded chunks, including local images and media.
                    let range = Self.byteRange(request.request.value(forHTTPHeaderField: "Range"), size: size)
                    var offset = range.start
                    let end = range.end
                    var headers = ["Content-Type": mime, "Content-Length": String(end - offset), "Accept-Ranges": "bytes"]
                    if range.partial { headers["Content-Range"] = "bytes \(offset)-\(end - 1)/\(size)" }
                    let response = HTTPURLResponse(url: url, statusCode: range.partial ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                    deliver( id: id, token: token) { request.receive(response) }
                    while offset < end {
                        guard isActive(id, token) else { return }
                        let delivered = try autoreleasepool { () throws -> UInt64 in
                            let data = try archive.read(path: path, offset: offset, length: min(256 * 1_024, end - offset))
                            guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
                            // deliver is synchronous: its main-actor callback finishes while
                            // this chunk is alive, then the bridge's autoreleased NSData drains.
                            deliver( id: id, token: token) { request.receive(data) }
                            return UInt64(data.count)
                        }
                        offset += delivered
                    }
                    deliver( id: id, token: token) { request.finish() }
                }
            } catch {
                deliver( id: id, token: token) { request.fail(error) }
            }
            lock.lock(); if active[id] == token { active.removeValue(forKey: id) }; lock.unlock()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.lock(); active.removeValue(forKey: ObjectIdentifier(urlSchemeTask)); lock.unlock()
    }

    nonisolated private func isActive(_ id: ObjectIdentifier, _ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active[id] == token
    }

    nonisolated private func deliver(id: ObjectIdentifier, token: UUID, action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.sync { if self.isActive(id, token) { action() } }
    }

    nonisolated private static func byteRange(_ header: String?, size: UInt64) -> (start: UInt64, end: UInt64, partial: Bool) {
        guard size > 0, let header, header.hasPrefix("bytes="), !header.contains(",") else { return (0, size, false) }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (0, size, false) }
        if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 { return (size - min(size, suffix), size, true) }
        guard let start = UInt64(parts[0]), start < size else { return (0, size, false) }
        let requestedEnd = UInt64(parts[1])
        let end = requestedEnd.map { $0 >= size - 1 ? size : $0 + 1 } ?? size
        guard end > start else { return (0, size, false) }
        return (start, end, true)
    }

    nonisolated private static func protectedHTML(_ data: Data, path: String) -> Data {
        var html = String(decoding: data, as: UTF8.self)
        let base = url(path: path)?.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") ?? "nomadzim://archive/"
        let policy = "default-src 'none'; img-src nomadzim: data: blob:; style-src nomadzim: 'unsafe-inline'; font-src nomadzim: data:; script-src nomadzim: 'unsafe-inline'; media-src nomadzim: data: blob:; connect-src nomadzim:; frame-src nomadzim:; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri nomadzim:"
        let protection = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><base href=\"\(base)\">"
        if let range = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: protection, at: range.upperBound)
        } else { html = "<head>\(protection)</head>" + html }
        return Data(html.utf8)
    }
}

// WebKit tasks never leave the main actor; only the immutable request is read by the worker.
private final class ZIMSchemeRequest: @unchecked Sendable {
    let request: URLRequest
    private let task: any WKURLSchemeTask
    @MainActor init(task: any WKURLSchemeTask) { self.task = task; request = task.request }
    @MainActor func receive(_ response: URLResponse) { task.didReceive(response) }
    @MainActor func receive(_ data: Data) { task.didReceive(data) }
    @MainActor func finish() { task.didFinish() }
    @MainActor func fail(_ error: Error) { task.didFailWithError(error) }
}
