import Foundation
import WebKit

/// Serves bundled map assets and bounded reads from explicitly imported archives.
final class PMTilesAssetHandler: NSObject, WKURLSchemeHandler {
    let assets: URL
    var archives: [String: URL] = [:]
    private(set) var archiveReads = 0
    private(set) var assetReads = 0

    init(assets: URL) { self.assets = assets.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "nomad-map" else {
            task.didFailWithError(PMTilesFailure.message("Invalid local map URL.")); return
        }
        do {
            let data: Data
            var headers = ["Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
            var status = 200
            if url.host == "archive" {
                guard let file = archives[url.lastPathComponent] else { throw PMTilesFailure.message("This archive is no longer available.") }
                let size = UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let range = try PMTilesByteRange.parse(task.request.value(forHTTPHeaderField: "Range"), fileSize: size)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: range.start)
                data = try handle.read(upToCount: range.count) ?? Data()
                guard data.count == range.count else { throw PMTilesFailure.message("Incomplete map read. Reimport this archive.") }
                status = 206
                headers["Content-Type"] = "application/octet-stream"
                headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(size)"
                headers["Accept-Ranges"] = "bytes"
                headers["ETag"] = "\"\(url.lastPathComponent)-\(size)\""
                archiveReads += 1
            } else if url.host == "assets" {
                let relative = url.path == "/" ? "index.html" : String(url.path.dropFirst())
                let file = assets.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(assets.resolvingSymlinksInPath().path + "/") else { throw PMTilesFailure.message("Invalid asset path.") }
                data = try Data(contentsOf: file, options: .mappedIfSafe)
                headers["Content-Type"] = Self.mime(file.pathExtension)
                assetReads += 1
            } else { throw PMTilesFailure.message("External map resources are disabled.") }
            headers["Content-Length"] = String(data.count)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "pbf": return "application/x-protobuf"
        default: return "application/octet-stream"
        }
    }
}
