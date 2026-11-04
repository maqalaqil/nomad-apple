import Foundation

enum OPDSError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum OPDSSafety {
    static let maximumFeedBytes = 4 * 1_024 * 1_024
    static let maximumFileBytes: Int64 = 10_000_000_000_000
    static func https(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty &&
        url.user == nil && url.password == nil && url.fragment == nil && url.absoluteString.utf8.count <= 8_192
    }
    static func resolved(_ value: String, base: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL, https(url) else { return nil }
        return url
    }
    static func plain(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

struct OPDSCatalog: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let url: URL
    let addedAt: Date
}

struct OPDSLink: Codable, Identifiable, Hashable, Sendable {
    let url: URL
    let relation: String
    let mediaType: String
    let title: String
    let length: Int64?
    let facetGroup: String?
    var unavailableReason: String?
    var id: String { relation + "|" + mediaType + "|" + url.absoluteString }
    var isFeed: Bool { mediaType.lowercased().contains("application/atom+xml") }
    var isAcquisition: Bool { relation == "http://opds-spec.org/acquisition" || relation.hasPrefix("http://opds-spec.org/acquisition/") }
    var isDirectAcquisition: Bool {
        unavailableReason == nil && ["http://opds-spec.org/acquisition", "http://opds-spec.org/acquisition/open-access", "http://opds-spec.org/acquisition/sample"].contains(relation)
    }
    var isFacet: Bool { relation == "http://opds-spec.org/facet" }
    var isSample: Bool { relation == "http://opds-spec.org/acquisition/sample" }
    var fileExtension: String? {
        switch mediaType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
        case "application/epub+zip": return "epub"
        case "application/pdf": return "pdf"
        case "application/x-zim", "application/zim": return "zim"
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        default: return nil
        }
    }
    var formatLabel: String { fileExtension?.uppercased() ?? (mediaType.isEmpty ? "Unspecified format" : mediaType) }
}

struct OPDSEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String
    let categories: [String]
    let language: String
    let rights: String
    let updated: String
    let links: [OPDSLink]
}

struct OPDSPage: Codable, Sendable {
    let sourceURL: URL
    let title: String
    let updated: String
    let entries: [OPDSEntry]
    let links: [OPDSLink]
    let ignoredUnsafeLinks: Int
    let fetchedAt: Date
    var categories: [String] { Array(Set(entries.flatMap(\.categories))).sorted() }

    func validate() throws {
        guard OPDSSafety.https(sourceURL), title.count <= 512, updated.count <= 128,
              entries.count <= 2_000, Set(entries.map(\.id)).count == entries.count,
              links.count <= 128, ignoredUnsafeLinks >= 0, fetchedAt.timeIntervalSince1970.isFinite else {
            throw OPDSError.invalid("The saved catalog page contains invalid metadata.")
        }
        for entry in entries {
            guard !entry.id.isEmpty, entry.id.count <= 2_048, entry.title.count <= 512,
                  entry.summary.count <= 6_000, entry.authors.count <= 16, entry.authors.allSatisfy({ $0.count <= 256 }),
                  entry.categories.count <= 64, entry.categories.allSatisfy({ $0.count <= 256 }),
                  entry.language.count <= 128, entry.rights.count <= 2_000, entry.updated.count <= 128, entry.links.count <= 64 else {
                throw OPDSError.invalid("The saved catalog entry contains invalid metadata.")
            }
        }
        for link in links + entries.flatMap(\.links) {
            guard OPDSSafety.https(link.url), link.title.count <= 512, link.relation.count <= 512, link.mediaType.count <= 256,
                  link.length == nil || (1...OPDSSafety.maximumFileBytes).contains(link.length!),
                  (link.facetGroup?.count ?? 0) <= 256, (link.unavailableReason?.count ?? 0) <= 512 else {
                throw OPDSError.invalid("The saved catalog page contains an unsafe link.")
            }
        }
    }
}

struct OPDSAcquisitionReceipt: Codable, Identifiable, Sendable {
    let id: UUID
    let catalogName: String
    let catalogURL: URL
    let feedURL: URL
    let entryID: String
    let entryTitle: String
    let acquisitionURL: URL
    var resolvedURL: URL? = nil
    var sha256: String? = nil
    let mediaType: String
    let declaredBytes: Int64?
    let requestedAt: Date
}

struct OPDSSearchTemplate: Codable, Sendable {
    let template: String
    let baseURL: URL
    var startIndex = 1
    var startPage = 1
    func url(query: String) throws -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300, template.utf8.count <= 8_192, OPDSSafety.https(baseURL),
              (0...1_000_000).contains(startIndex), (0...1_000_000).contains(startPage) else {
            throw OPDSError.invalid("Enter a catalog search of 1–300 characters.")
        }
        var value = template.replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive)
            .replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        guard value.contains("{searchTerms}") || value.contains("{searchTerms?}") else {
            throw OPDSError.invalid("The catalog does not provide a supported keyword-search template.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        value = value.replacingOccurrences(of: "{searchTerms}", with: encoded).replacingOccurrences(of: "{searchTerms?}", with: encoded)
        value = value.replacingOccurrences(of: "{language?}", with: "")
        for (key, replacement) in [("count", "40"), ("startIndex", String(startIndex)), ("startPage", String(startPage)), ("language", "*"), ("inputEncoding", "UTF-8"), ("outputEncoding", "UTF-8")] {
            value = value.replacingOccurrences(of: "{\(key)}", with: replacement).replacingOccurrences(of: "{\(key)?}", with: replacement)
        }
        // Unknown optional extensions can be omitted; required extensions must not be guessed.
        value = value.replacingOccurrences(of: "\\{[^{}]+\\?\\}", with: "", options: .regularExpression)
        guard !value.contains("{"), !value.contains("}"), let url = OPDSSafety.resolved(value, base: baseURL) else {
            throw OPDSError.invalid("The catalog search needs an unsupported required parameter or an unsafe URL.")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems?.filter { $0.value != "" }
        components?.queryItems = items
        return components?.url ?? url
    }
}
