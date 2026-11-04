import Foundation
import CryptoKit
import Observation

@MainActor @Observable
final class OPDSCatalogStore {
    static let shared = OPDSCatalogStore()
    private(set) var catalogs: [OPDSCatalog] = []
    private(set) var acquisitions: [OPDSAcquisitionReceipt] = []
    private(set) var error: String?
    private(set) var canWrite = false
    let root: URL
    private let maximumSavedPages = 64
    private struct Manifest: Codable { var catalogs: [OPDSCatalog]; var acquisitions: [OPDSAcquisitionReceipt] }
    private struct CachedPage: Codable { let catalogID: UUID; let requestedURL: URL; let page: OPDSPage }
    private struct CachedSearch: Codable { let catalogID: UUID; let linkURL: URL; let template: OPDSSearchTemplate }
    private var manifestURL: URL { root.appendingPathComponent("catalogs.json") }
    private var cacheRoot: URL { root.appendingPathComponent("Cache", isDirectory: true) }

    init(rootURL: URL? = nil) {
        root = rootURL ?? URL.applicationSupportDirectory.appendingPathComponent("NomadPad/Catalogs", isDirectory: true)
        reload()
    }
    func reload() {
        canWrite = false
        do {
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let saved = try JSONDecoder().decode(Manifest.self, from: read(manifestURL, limit: 8 * 1_024 * 1_024))
                guard saved.catalogs.count <= 50, Set(saved.catalogs.map(\.id)).count == saved.catalogs.count,
                      Set(saved.catalogs.map(\.url)).count == saved.catalogs.count,
                      saved.catalogs.allSatisfy({ OPDSSafety.https($0.url) && !$0.name.isEmpty && $0.name.count <= 120 && $0.addedAt.timeIntervalSince1970.isFinite }),
                      saved.acquisitions.count <= 1_000, Set(saved.acquisitions.map(\.id)).count == saved.acquisitions.count,
                      saved.acquisitions.allSatisfy({ OPDSSafety.https($0.catalogURL) && OPDSSafety.https($0.feedURL) && OPDSSafety.https($0.acquisitionURL) &&
                          ($0.resolvedURL == nil || OPDSSafety.https($0.resolvedURL!)) &&
                          ($0.sha256 == nil || ($0.sha256!.count == 64 && $0.sha256!.allSatisfy { $0.isASCII && $0.isHexDigit })) &&
                          $0.catalogName.count <= 120 && $0.entryID.count <= 2_048 && $0.entryTitle.count <= 512 && $0.mediaType.count <= 256 &&
                          ($0.declaredBytes == nil || (1...OPDSSafety.maximumFileBytes).contains($0.declaredBytes!)) && $0.requestedAt.timeIntervalSince1970.isFinite }) else {
                    throw OPDSError.invalid("Saved catalog settings or acquisition provenance contain invalid metadata.")
                }
                catalogs = saved.catalogs; acquisitions = saved.acquisitions
            }
            canWrite = true; error = nil
        } catch { self.error = "Catalog settings could not be opened. The saved data was preserved. \(error.localizedDescription)" }
    }
    @discardableResult func add(name: String, urlText: String) throws -> OPDSCatalog {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), OPDSSafety.https(url) else {
            throw OPDSError.invalid("Enter a name of 1–120 characters and a public HTTPS OPDS URL without credentials or a fragment.")
        }
        guard catalogs.count < 50, !catalogs.contains(where: { $0.url == url }) else {
            throw OPDSError.invalid("This catalog is already saved, or the 50-catalog limit has been reached.")
        }
        let catalog = OPDSCatalog(id: UUID(), name: name, url: url, addedAt: Date())
        try save(catalogs: catalogs + [catalog], acquisitions: acquisitions)
        catalogs.append(catalog)
        return catalog
    }
    func remove(_ id: UUID) throws {
        let remaining = catalogs.filter { $0.id != id }
        try save(catalogs: remaining, acquisitions: acquisitions)
        catalogs = remaining
        // Cache eviction is best-effort; publication files and Downloads are never touched.
        for url in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix(id.uuidString + "-") {
            try? FileManager.default.removeItem(at: url)
        }
    }
    func cachedPage(catalogID: UUID, url: URL) throws -> OPDSPage? {
        try requireCatalog(catalogID, url: url)
        let location = cacheURL(catalogID: catalogID, url: url, kind: "page")
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let cached = try JSONDecoder().decode(CachedPage.self, from: read(location, limit: 12 * 1_024 * 1_024))
        guard cached.catalogID == catalogID, cached.requestedURL == url else { throw OPDSError.invalid("The cached catalog page has the wrong provenance.") }
        try cached.page.validate()
        return cached.page
    }
    func cache(_ page: OPDSPage, catalogID: UUID, requestedURL: URL) throws {
        try requireCatalog(catalogID, url: requestedURL)
        try page.validate()
        try write(CachedPage(catalogID: catalogID, requestedURL: requestedURL, page: page), to: cacheURL(catalogID: catalogID, url: requestedURL, kind: "page"), limit: 12 * 1_024 * 1_024)
        trimCache()
    }
    func cachedSearch(catalogID: UUID, link: OPDSLink) throws -> OPDSSearchTemplate? {
        try requireCatalog(catalogID, url: link.url)
        let location = cacheURL(catalogID: catalogID, url: link.url, kind: "search")
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let cached = try JSONDecoder().decode(CachedSearch.self, from: read(location, limit: 32_768))
        guard cached.catalogID == catalogID, cached.linkURL == link.url else { throw OPDSError.invalid("The cached search has the wrong provenance.") }
        _ = try cached.template.url(query: "validation")
        return cached.template
    }
    func cacheSearch(_ template: OPDSSearchTemplate, catalogID: UUID, link: OPDSLink) throws {
        try requireCatalog(catalogID, url: link.url)
        _ = try template.url(query: "validation")
        try write(CachedSearch(catalogID: catalogID, linkURL: link.url, template: template), to: cacheURL(catalogID: catalogID, url: link.url, kind: "search"), limit: 32_768)
        trimCache()
    }
    /// Persist provenance before queueing. Receipts describe requests, not transfer completion.
    func recordAcquisition(catalog: OPDSCatalog, page: OPDSPage, entry: OPDSEntry, link: OPDSLink, resolved: OPDSResolvedAcquisition? = nil) throws -> UUID {
        try requireCatalog(catalog.id, url: link.url)
        guard page.entries.contains(entry), entry.links.contains(link), link.isDirectAcquisition else { throw OPDSError.invalid("This is not a supported direct acquisition from the current catalog page.") }
        if let resolved {
            guard OPDSSafety.https(resolved.url), resolved.length == nil || (1...OPDSSafety.maximumFileBytes).contains(resolved.length!),
                  resolved.sha256 == nil || (resolved.sha256!.count == 64 && resolved.sha256!.allSatisfy({ $0.isASCII && $0.isHexDigit })) else {
                throw OPDSError.invalid("The resolved acquisition metadata is invalid.")
            }
        }
        let receipt = OPDSAcquisitionReceipt(id: UUID(), catalogName: catalog.name, catalogURL: catalog.url,
            feedURL: page.sourceURL, entryID: entry.id, entryTitle: entry.title, acquisitionURL: link.url,
            resolvedURL: resolved?.url, sha256: resolved?.sha256, mediaType: link.mediaType,
            declaredBytes: resolved?.length ?? link.length, requestedAt: Date())
        let updated = Array(([receipt] + acquisitions).prefix(1_000))
        try save(catalogs: catalogs, acquisitions: updated)
        acquisitions = updated
        return receipt.id
    }
    func removeAcquisition(_ id: UUID) throws {
        let updated = acquisitions.filter { $0.id != id }
        try save(catalogs: catalogs, acquisitions: updated); acquisitions = updated
    }
    private func requireCatalog(_ id: UUID, url: URL) throws {
        guard canWrite else { throw OPDSError.invalid(error ?? "Saved catalog settings are unavailable; data has been preserved.") }
        guard catalogs.contains(where: { $0.id == id }), OPDSSafety.https(url) else { throw OPDSError.invalid("This catalog is no longer saved or its link is unsafe.") }
    }
    private func save(catalogs: [OPDSCatalog], acquisitions: [OPDSAcquisitionReceipt]) throws {
        guard canWrite else { throw OPDSError.invalid(error ?? "Saved catalog data is unavailable and was preserved.") }
        try write(Manifest(catalogs: catalogs, acquisitions: acquisitions), to: manifestURL, limit: 8 * 1_024 * 1_024)
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize, count <= limit else { throw OPDSError.invalid("The saved catalog file is unsafe or too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw OPDSError.invalid("The saved catalog file is too large.") }
        return data
    }
    private func write<T: Encodable>(_ value: T, to url: URL, limit: Int) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw OPDSError.invalid("Saved catalog data exceeds its storage limit.") }
        try data.write(to: url, options: .atomic)
    }
    private func cacheURL(catalogID: UUID, url: URL, kind: String) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appendingPathComponent("\(catalogID.uuidString)-\(kind)-\(digest).json")
    }
    private func trimCache() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in files.dropFirst(maximumSavedPages) { try? FileManager.default.removeItem(at: file) }
    }
}
