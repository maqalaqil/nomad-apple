import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// OPDS 1.x Atom and OpenSearch metadata only. Feed markup is never rendered as HTML.
final class OPDSParser: NSObject, XMLParserDelegate {
    private let sourceURL: URL
    private let fetchedAt: Date
    private var stack: [(name: String, namespace: String, text: String, base: URL)] = []
    private var entry: EntryBuilder?
    private var entries: [OPDSEntry] = []
    private var links: [OPDSLink] = []
    private var title = ""
    private var updated = ""
    private var root = ""
    private var nodes = 0
    private var ignored = 0
    private var failure: Error?
    private var openLink: (entry: Bool, index: Int, depth: Int)?
    private var searchTemplates: [OPDSSearchTemplate] = []
    private var totalResults: Int?
    private var startIndex: Int?
    private var itemsPerPage: Int?
    private static let atom = "http://www.w3.org/2005/Atom"
    private static let openSearch = "http://a9.com/-/spec/opensearch/1.1/"

    private struct EntryBuilder {
        var id = "", title = "", summary = "", language = "", rights = "", updated = ""
        var authors: [String] = [], categories: [String] = [], links: [OPDSLink] = []
    }
    private init(sourceURL: URL, fetchedAt: Date) { self.sourceURL = sourceURL; self.fetchedAt = fetchedAt }

    static func page(data: Data, sourceURL: URL, fetchedAt: Date = Date()) throws -> OPDSPage {
        let reader = try parse(data: data, sourceURL: sourceURL, fetchedAt: fetchedAt)
        guard reader.root == "feed" || reader.root == "entry" else {
            throw OPDSError.invalid("This is not an OPDS 1.x Atom feed. OPDS 2 JSON, sign-in pages and ordinary webpages are not supported here.")
        }
        let paging = OPDSPublisherCompatibility.paging(sourceURL, total: reader.totalResults, start: reader.startIndex, count: reader.itemsPerPage,
            existing: reader.links)
        let page = OPDSPage(sourceURL: sourceURL, title: reader.title.isEmpty ? sourceURL.host ?? "Catalog" : reader.title,
            updated: reader.updated, entries: reader.entries, links: reader.links + paging,
            ignoredUnsafeLinks: reader.ignored, fetchedAt: fetchedAt)
        try page.validate()
        return page
    }
    static func search(data: Data, sourceURL: URL) throws -> OPDSSearchTemplate {
        let reader = try parse(data: data, sourceURL: sourceURL, fetchedAt: Date())
        guard reader.root == "OpenSearchDescription", let template = reader.searchTemplates.first else {
            throw OPDSError.invalid("No supported Atom keyword search was found in the OpenSearch description.")
        }
        _ = try template.url(query: "validation")
        return template
    }
    private static func parse(data: Data, sourceURL: URL, fetchedAt: Date) throws -> OPDSParser {
        guard OPDSSafety.https(sourceURL), !data.isEmpty, data.count <= OPDSSafety.maximumFeedBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw OPDSError.invalid("Catalog XML must be UTF-8 and no larger than 4 MiB.")
        }
        guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw OPDSError.invalid("Catalog XML entity and document-type declarations are not permitted.")
        }
        let reader = OPDSParser(sourceURL: sourceURL, fetchedAt: fetchedAt)
        let parser = XMLParser(data: OPDSPublisherCompatibility.xml(text, sourceURL: sourceURL))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.failure == nil else {
            throw reader.failure ?? OPDSError.invalid("Catalog XML could not be parsed. \(parser.parserError?.localizedDescription ?? "")")
        }
        return reader
    }
    private func reject(_ parser: XMLParser, _ message: String) { failure = OPDSError.invalid(message); parser.abortParsing() }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        nodes += 1
        guard nodes <= 60_000, stack.count < 32 else { reject(parser, "The catalog XML exceeds the supported depth or element count."); return }
        let namespace = namespaceURI ?? ""
        let parentBase = stack.last?.base ?? sourceURL
        let base: URL
        if let declared = attributes["xml:base"] {
            guard let resolved = OPDSSafety.resolved(declared, base: parentBase) else { reject(parser, "The catalog declares an unsafe XML base URL."); return }
            base = resolved
        } else { base = parentBase }
        if stack.isEmpty {
            guard (["feed", "entry"].contains(elementName) && namespace == Self.atom) ||
                    (elementName == "OpenSearchDescription" && namespace == Self.openSearch) else {
                reject(parser, "Expected an OPDS 1.x Atom feed or OpenSearch description, not a webpage or OPDS 2 JSON."); return
            }
            root = elementName
        }
        stack.append((elementName, namespace, "", base))
        if elementName == "entry", namespace == Self.atom, (stack.count == 1 || stack.count == 2) {
            guard entry == nil, entries.count < 2_000 else { reject(parser, "A catalog page may contain at most 2,000 entries."); return }
            entry = EntryBuilder()
        }
        if elementName == "category", namespace == Self.atom, entry != nil, isEntryChild {
            let category = OPDSSafety.plain(attributes["label"] ?? attributes["term"] ?? "", limit: 256)
            if !category.isEmpty, entry!.categories.count < 64, !entry!.categories.contains(category) { entry!.categories.append(category) }
        }
        if elementName == "link", namespace == Self.atom, isEntryChild || (stack.count == 2 && root == "feed") {
            guard let href = attributes["href"], let url = OPDSSafety.resolved(href, base: base) else { ignored += 1; return }
            let relation = OPDSSafety.plain(attributes["rel"] ?? "alternate", limit: 512)
            let type = OPDSSafety.plain(attributes["type"] ?? "", limit: 256)
            var reason: String?
            var length: Int64?
            if let raw = attributes["length"] {
                if let number = Int64(raw), (1...OPDSSafety.maximumFileBytes).contains(number) { length = number }
                else { reason = "The publisher supplied an invalid file size; this acquisition cannot be queued." }
            }
            if relation.contains("/acquisition/"), !["http://opds-spec.org/acquisition/open-access", "http://opds-spec.org/acquisition/sample"].contains(relation) {
                reason = "Purchases, borrowing, subscriptions and authenticated acquisitions are not supported."
            }
            if type.lowercased().contains("adobe.adept") || type.lowercased().contains("readium.lcp") {
                reason = "This is a DRM license or protected acquisition, not a directly readable book."
            }
            let link = OPDSLink(url: url, relation: relation, mediaType: type,
                title: OPDSSafety.plain(attributes["title"] ?? "", limit: 512), length: length,
                facetGroup: attributes["opds:facetGroup"].map { OPDSSafety.plain($0, limit: 256) }, unavailableReason: reason)
            if entry != nil {
                guard entry!.links.count < 64 else { reject(parser, "A catalog entry has too many links."); return }
                entry!.links.append(link); openLink = (true, entry!.links.count - 1, stack.count)
            } else {
                guard links.count < 128 else { reject(parser, "A catalog page has too many links."); return }
                links.append(link); openLink = (false, links.count - 1, stack.count)
            }
        }
        if elementName == "indirectAcquisition", namespace == "http://opds-spec.org/2010/catalog", let link = openLink {
            if link.entry { entry?.links[link.index].unavailableReason = "Indirect or protected acquisitions require a provider workflow and cannot be queued as a direct file." }
            else { links[link.index].unavailableReason = "Indirect acquisitions are not supported." }
        }
        if elementName == "Url", namespace == Self.openSearch, root == "OpenSearchDescription", stack.count == 2,
           (attributes["type"] ?? "").lowercased().contains("application/atom+xml"),
           (attributes["method"] ?? "GET").uppercased() == "GET", let template = attributes["template"], template.utf8.count <= 8_192 {
            let indexOffset = Int(attributes["indexOffset"] ?? "1") ?? 1
            let pageOffset = Int(attributes["pageOffset"] ?? "1") ?? 1
            guard (0...1_000_000).contains(indexOffset), (0...1_000_000).contains(pageOffset) else { return }
            let candidate = OPDSSearchTemplate(template: template, baseURL: base, startIndex: indexOffset, startPage: pageOffset)
            if (try? candidate.url(query: "validation")) != nil { searchTemplates.append(candidate) }
        }
    }
    private var isEntryChild: Bool { stack.count >= 2 && stack[stack.count - 2].name == "entry" && stack[stack.count - 2].namespace == Self.atom }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        guard stack[stack.count - 1].text.utf8.count + string.utf8.count <= 64 * 1_024 else { reject(parser, "A catalog text field exceeds 64 KiB."); return }
        stack[stack.count - 1].text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { reject(parser, "Catalog CDATA is not UTF-8."); return }
        self.parser(parser, foundCharacters: string)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let current = stack.last else { return }
        let parent = stack.dropLast().last
        let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAtom = current.namespace == Self.atom
        if isAtom, isEntryChild, entry != nil {
            switch elementName {
            case "id": entry?.id = OPDSSafety.plain(text, limit: 2_048)
            case "title": entry?.title = OPDSSafety.plain(text, limit: 512)
            case "summary", "content":
                if entry!.summary.isEmpty { entry?.summary = OPDSSafety.plain(text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression), limit: 6_000) }
            case "rights": entry?.rights = OPDSSafety.plain(text, limit: 2_000)
            case "updated": entry?.updated = OPDSSafety.plain(text, limit: 128)
            default: break
            }
        }
        if elementName == "language", ["http://purl.org/dc/terms/", "http://purl.org/dc/elements/1.1/"].contains(current.namespace), isEntryChild {
            entry?.language = OPDSSafety.plain(text, limit: 128)
        }
        if elementName == "name", isAtom, parent?.name == "author", parent?.namespace == Self.atom, entry != nil,
           stack.count >= 3, stack[stack.count - 3].name == "entry", !text.isEmpty, entry!.authors.count < 16 {
            entry?.authors.append(OPDSSafety.plain(text, limit: 256))
        }
        if isAtom, stack.count == 2, root == "feed" {
            if elementName == "title" { title = OPDSSafety.plain(text, limit: 512) }
            if elementName == "updated" { updated = OPDSSafety.plain(text, limit: 128) }
        }
        if stack.count == 2, root == "feed", [Self.atom, Self.openSearch].contains(current.namespace),
           let number = Int(text), (0...1_000_000_000).contains(number) {
            if elementName == "totalResults" { totalResults = number }
            if elementName == "startIndex" { startIndex = number }
            if elementName == "itemsPerPage" { itemsPerPage = number }
        }
        if elementName == "entry", isAtom, (stack.count == 1 || stack.count == 2), let item = entry {
            guard !item.id.isEmpty, !item.title.isEmpty, !entries.contains(where: { $0.id == item.id }) else {
                reject(parser, "Catalog entries must have a title and a unique Atom ID."); return
            }
            entries.append(OPDSEntry(id: item.id, title: item.title, authors: item.authors, summary: item.summary,
                categories: item.categories, language: item.language, rights: item.rights, updated: item.updated, links: item.links))
            if root == "entry" { title = item.title; updated = item.updated }
            entry = nil
        }
        if openLink?.depth == stack.count { openLink = nil }
        stack.removeLast()
        // Preserve human-readable text from XHTML content without interpreting its markup.
        if !stack.isEmpty, !text.isEmpty, current.namespace != Self.atom,
           stack.contains(where: { ["title", "summary", "content"].contains($0.name) && $0.namespace == Self.atom }) {
            self.parser(parser, foundCharacters: text + " ")
        }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser, "External catalog entities are forbidden."); return nil
    }
}

/// Verified Kiwix v2 compatibility: it omits next links and currently leaves query
/// ampersands unescaped in XML attributes. Other providers keep strict XML parsing.
enum OPDSPublisherCompatibility {
    private static func isKiwix(_ url: URL) -> Bool { url.host?.lowercased() == "library.kiwix.org" && url.path.hasPrefix("/catalog/v2/") }
    private static func isEntries(_ url: URL) -> Bool { isKiwix(url) && ["/catalog/v2/entries", "/catalog/v2/partial_entries"].contains(url.path) }
    static func pageRequest(_ url: URL) -> URL {
        guard isEntries(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "count" }) { items.append(URLQueryItem(name: "count", value: "40")) }
        if !items.contains(where: { $0.name == "start" }) { items.append(URLQueryItem(name: "start", value: "0")) }
        components.queryItems = items
        return components.url ?? url
    }
    static func xml(_ text: String, sourceURL: URL) -> Data {
        guard isKiwix(sourceURL) else { return Data(text.utf8) }
        // Escape only the raw '&parameter=' spelling. Custom entities and DTDs
        // remain forbidden by the parser's earlier declaration check.
        let repaired = text.replacingOccurrences(of: "&(?=[A-Za-z_][A-Za-z0-9_.:-]*=)", with: "&amp;", options: .regularExpression)
        return Data(repaired.utf8)
    }
    static func paging(_ url: URL, total: Int?, start: Int?, count: Int?, existing: [OPDSLink]) -> [OPDSLink] {
        guard isEntries(url), let total, let start, let count, count > 0, start < total,
              count <= 2_000, existing.count <= 126 else { return [] }
        var links: [OPDSLink] = []
        func add(_ relation: String, offset: Int) {
            guard !existing.contains(where: { $0.relation == relation }), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            var items = (components.queryItems ?? []).filter { $0.name != "start" && $0.name != "count" }
            items.append(URLQueryItem(name: "start", value: String(offset)))
            items.append(URLQueryItem(name: "count", value: String(count)))
            components.queryItems = items
            if let destination = components.url, OPDSSafety.https(destination) {
                links.append(OPDSLink(url: destination, relation: relation, mediaType: "application/atom+xml", title: relation.capitalized + " page", length: nil, facetGroup: nil))
            }
        }
        if start > 0 { add("previous", offset: max(0, start - count)) }
        if start + count < total { add("next", offset: start + count) }
        return links
    }
}
