import Foundation

struct OPDSFetchedData: Sendable {
    let data: Data
    let url: URL
}

enum OPDSClient {
    /// Streaming limits apply to decompressed response bytes, not just Content-Length.
    static func fetch(_ url: URL, configuration: URLSessionConfiguration? = nil) async throws -> OPDSFetchedData {
        guard OPDSSafety.https(url) else { throw OPDSError.invalid("Only HTTPS catalog URLs without credentials or fragments are allowed.") }
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let guardDelegate = OPDSHTTPSDelegate()
        let session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/atom+xml, application/opensearchdescription+xml, application/xml;q=0.8, text/xml;q=0.7", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, OPDSSafety.https(finalURL), (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 401 || status == 403 { throw OPDSError.invalid("This catalog requires authentication. Public HTTPS OPDS feeds are supported; sign-in and private catalogs are not.") }
            throw OPDSError.invalid("The catalog request did not return a successful HTTPS response\(status.map { " (HTTP \($0))" } ?? "").")
        }
        guard response.expectedContentLength <= OPDSSafety.maximumFeedBytes else {
            throw OPDSError.invalid("The catalog response exceeds 4 MiB. Use a paginated feed.")
        }
        var data = Data()
        data.reserveCapacity(min(OPDSSafety.maximumFeedBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < OPDSSafety.maximumFeedBytes else { throw OPDSError.invalid("The catalog response exceeds 4 MiB. Use a paginated feed.") }
            data.append(byte)
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return OPDSFetchedData(data: data, url: finalURL)
    }

    static func page(_ url: URL) async throws -> OPDSPage {
        let response = try await fetch(OPDSPublisherCompatibility.pageRequest(url))
        return try await Task.detached(priority: .utility) {
            try OPDSParser.page(data: response.data, sourceURL: response.url)
        }.value
    }

    static func searchTemplate(_ link: OPDSLink) async throws -> OPDSSearchTemplate {
        if link.isFeed {
            let template = OPDSSearchTemplate(template: link.url.absoluteString, baseURL: link.url)
            _ = try template.url(query: "validation")
            return template
        }
        guard link.mediaType.lowercased().contains("application/opensearchdescription+xml") else {
            throw OPDSError.invalid("This catalog advertises an unsupported search format.")
        }
        let response = try await fetch(link.url)
        return try OPDSParser.search(data: response.data, sourceURL: response.url)
    }
}

private final class OPDSHTTPSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, OPDSSafety.https(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
