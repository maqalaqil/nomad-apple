import Foundation

private func expectFailure(_ name: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted \(name)") } catch { }
}
private func check(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); precondition(value) }
private let base = URL(string: "https://catalog.example/root/feed.xml")!
private func feed(_ entries: String, extra: String = "") -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog" xmlns:dc="http://purl.org/dc/terms/">
      <id>urn:test:root</id><title>Original test catalog</title><updated>2026-11-03T12:00:00Z</updated>
      <link rel="next" type="application/atom+xml" href="?page=2"/>
      <link rel="search" type="application/opensearchdescription+xml" href="../search.xml"/>
      <link rel="http://opds-spec.org/facet" opds:facetGroup="Topic" title="Science" href="science.xml"/>
      \(extra)\(entries)
    </feed>
    """.utf8)
}
private let publication = """
<entry xml:base="../books/">
 <id>urn:book:1</id><title>كتاب &amp; Science</title><author><name>Test Author</name></author>
 <category term="science" label="Science"/><dc:language>ar</dc:language><rights>Original test fixture</rights>
 <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First paragraph.</p><p>Second paragraph.</p></div></summary>
 <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="download/1" length="1234"/>
 <link rel="http://opds-spec.org/acquisition/buy" type="application/epub+zip" href="buy/1"/>
 <link rel="http://opds-spec.org/acquisition" type="application/vnd.adobe.adept+xml" href="license/1"/>
 <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="indirect/1"><opds:indirectAcquisition type="application/pdf"/></link>
 <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="wrong-length.pdf" length="-12"/>
 <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="http://insecure.example/book.pdf"/>
 <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="https://user:pass@example.org/book.pdf"/>
</entry>
"""

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        let body: Data
        let status: Int
        if mode == "large" { body = Data(repeating: 65, count: OPDSSafety.maximumFeedBytes + 1); status = 200 }
        else if mode == "denied" { body = Data(); status = 401 }
        else { body = feed(publication); status = 200 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/atom+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct OPDSRegression {
    @MainActor static func main() async throws {
        let page = try OPDSParser.page(data: feed(publication), sourceURL: base)
        precondition(page.entries.count == 1 && page.entries[0].title == "كتاب & Science")
        precondition(page.entries[0].authors == ["Test Author"] && page.entries[0].language == "ar")
        precondition(page.entries[0].summary.contains("First paragraph.") && page.entries[0].summary.contains("Second paragraph."))
        precondition(page.categories == ["Science"] && page.ignoredUnsafeLinks == 2)
        let entry = page.entries[0], link = page.entries[0].links[0]
        precondition(link.url.absoluteString == "https://catalog.example/books/download/1" && link.length == 1234 && link.fileExtension == "epub")
        precondition(entry.links.filter(\.isDirectAcquisition).count == 1)
        precondition(entry.links[1...].allSatisfy { $0.unavailableReason != nil })
        precondition(page.links.first { $0.isFacet }?.facetGroup == "Topic")
        precondition(page.links.first { $0.relation == "next" }?.url.absoluteString == "https://catalog.example/root/feed.xml?page=2")
        let standalone = Data("<entry xmlns=\"http://www.w3.org/2005/Atom\"><id>single</id><title>Single</title><link rel=\"http://opds-spec.org/acquisition\" href=\"book.pdf\" type=\"application/pdf\"/></entry>".utf8)
        try check(try OPDSParser.page(data: standalone, sourceURL: base).entries.count == 1)

        for (name, data) in [
            ("DOCTYPE", Data("<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><feed xmlns='http://www.w3.org/2005/Atom'><title>&x;</title></feed>".utf8)),
            ("entity", Data("<!ENTITY x 'foo'><feed xmlns='http://www.w3.org/2005/Atom'/>".utf8)),
            ("wrong namespace", Data("<feed xmlns='https://malicious.example/atom'><title>Fake</title></feed>".utf8)),
            ("webpage", Data("<html><body>Sign in</body></html>".utf8)),
            ("OPDS 2 JSON", Data("{\"metadata\":{\"title\":\"JSON\"}}".utf8)),
            ("duplicate IDs", feed(publication + publication)),
            ("unsafe XML base", feed(publication.replacingOccurrences(of: "../books/", with: "http://insecure.example/"))),
            ("excessive nesting", feed(String(repeating: "<x>", count: 35) + String(repeating: "</x>", count: 35))),
            ("oversize text", feed("<title>" + String(repeating: "x", count: 65_537) + "</title>")),
            ("oversize data", Data(repeating: 65, count: OPDSSafety.maximumFeedBytes + 1))
        ] { expectFailure(name) { _ = try OPDSParser.page(data: data, sourceURL: base) } }
        expectFailure("HTTP source") { _ = try OPDSParser.page(data: feed(publication), sourceURL: URL(string: "http://example.org/catalog")!) }

        let searchXML = Data("""
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <Url type="text/html" template="https://example.org/web?q={searchTerms}"/>
          <Url type="application/atom+xml;profile=opds-catalog" indexOffset="0" template="../find?q={searchTerms}&amp;count={count?}&amp;start={startIndex?}&amp;lang={language?}&amp;extra={custom?}"/>
        </OpenSearchDescription>
        """.utf8)
        let template = try OPDSParser.search(data: searchXML, sourceURL: base)
        let queryURL = try template.url(query: "عربي & title#one")
        let components = URLComponents(url: queryURL, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems?.first { $0.name == "q" }?.value == "عربي & title#one" && queryURL.fragment == nil)
        precondition(components.queryItems?.first { $0.name == "count" }?.value == "40")
        precondition(components.queryItems?.first { $0.name == "start" }?.value == "0" && components.queryItems?.first { $0.name == "lang" } == nil)
        expectFailure("required search extension") { _ = try OPDSSearchTemplate(template: "https://example.org/?q={searchTerms}&x={mustSupply}", baseURL: base).url(query: "test") }
        expectFailure("insecure search") { _ = try OPDSSearchTemplate(template: "http://example.org/?q={searchTerms}", baseURL: base).url(query: "test") }
        expectFailure("oversize search") { _ = try template.url(query: String(repeating: "q", count: 301)) }

        let metalink = Data("""
        <metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="fixture.zim">
        <size>1234</size><hash type="sha-256">\(String(repeating: "a", count: 64))</hash>
        <url priority="1">http://insecure.example/fixture.zim</url>
        <url priority="2">https://mirror.example/fixture.zim</url><url priority="3">https://backup.example/fixture.zim</url>
        </file></metalink>
        """.utf8)
        let resolved = try OPDSMetalink.parse(metalink, sourceURL: base, declaredLength: 1234)
        precondition(resolved.url.host == "mirror.example" && resolved.length == 1234 && resolved.sha256 == String(repeating: "a", count: 64))
        expectFailure("conflicting archive size") { _ = try OPDSMetalink.parse(metalink, sourceURL: base, declaredLength: 1235) }
        expectFailure("unsafe Metalink name") { _ = try OPDSMetalink.parse(Data(String(decoding: metalink, as: UTF8.self).replacingOccurrences(of: "name=\"fixture.zim\"", with: "name=\"../fixture.zim\"").utf8), sourceURL: base, declaredLength: nil) }
        expectFailure("invalid publisher hash") { _ = try OPDSMetalink.parse(Data(String(decoding: metalink, as: UTF8.self).replacingOccurrences(of: String(repeating: "a", count: 64), with: "invalid-hash").utf8), sourceURL: base, declaredLength: nil) }

        let root = URL.temporaryDirectory.appendingPathComponent("nomad-opds-regression-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OPDSCatalogStore(rootURL: root)
        let catalog = try store.add(name: "Fixture Catalog", urlText: base.absoluteString)
        expectFailure("duplicate catalog") { _ = try store.add(name: "Duplicate", urlText: base.absoluteString) }
        try store.cache(page, catalogID: catalog.id, requestedURL: base)
        let searchLink = page.links.first { $0.relation == "search" }!
        try store.cacheSearch(template, catalogID: catalog.id, link: searchLink)
        let receiptID = try store.recordAcquisition(catalog: catalog, page: page, entry: entry, link: link)
        let restored = OPDSCatalogStore(rootURL: root)
        precondition(restored.canWrite && restored.catalogs == [catalog] && restored.acquisitions.first?.id == receiptID)
        try check(try restored.cachedPage(catalogID: catalog.id, url: base)?.entries == page.entries)
        try check(try restored.cachedSearch(catalogID: catalog.id, link: searchLink)?.url(query: "test") == template.url(query: "test"))
        expectFailure("purchase receipt") { _ = try restored.recordAcquisition(catalog: catalog, page: page, entry: entry, link: entry.links[1]) }
        let manifest = root.appendingPathComponent("catalogs.json")
        let validManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        expectFailure("atomic write failure") { _ = try restored.add(name: "Another", urlText: "https://example.org/another") }
        precondition(restored.catalogs == [catalog])
        try FileManager.default.removeItem(at: manifest)
        let corrupt = Data("preserve this corrupt saved manifest".utf8)
        try corrupt.write(to: manifest)
        let broken = OPDSCatalogStore(rootURL: root)
        precondition(!broken.canWrite && broken.error != nil)
        expectFailure("overwrite corrupt settings") { _ = try broken.add(name: "Unsafe overwrite", urlText: "https://example.org/new") }
        try check(try Data(contentsOf: manifest) == corrupt)
        try validManifest.write(to: manifest)
        broken.reload()
        precondition(broken.canWrite && broken.catalogs == [catalog])
        try broken.remove(catalog.id)
        precondition(broken.catalogs.isEmpty && broken.acquisitions.count == 1)
        try check(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Cache"), includingPropertiesForKeys: nil).isEmpty)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let fetched = try await OPDSClient.fetch(URL(string: "https://fixture.example/good")!, configuration: configuration)
        try check(try OPDSParser.page(data: fetched.data, sourceURL: fetched.url).entries.count == 1)
        do { _ = try await OPDSClient.fetch(URL(string: "https://fixture.example/large")!, configuration: configuration); fatalError("Accepted streaming overflow") } catch {}
        do { _ = try await OPDSClient.fetch(URL(string: "https://fixture.example/denied")!, configuration: configuration); fatalError("Accepted HTTP 401") } catch {}
        do { _ = try await OPDSClient.fetch(URL(string: "http://fixture.example/good")!, configuration: configuration); fatalError("Accepted HTTP request") } catch {}
        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1].contains("entries") ? "entries?count=2&start=0" : "root.xml"
            let real = try OPDSParser.page(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), sourceURL: URL(string: "https://library.kiwix.org/catalog/v2/" + path)!)
            if path.hasPrefix("entries") { precondition(real.links.contains(where: { $0.relation == "next" && $0.url.query?.contains("start=2") == true })) }
            print("PASS: real catalog metadata parsed (\(real.entries.count) entries, \(real.links.count) links): \(real.title)")
        }
        if CommandLine.arguments.count > 2 {
            let realSearch = try OPDSParser.search(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), sourceURL: URL(string: "https://library.kiwix.org/catalog/v2/searchdescription.xml")!)
            print("PASS: real OpenSearch URL: \(try realSearch.url(query: "wikipedia"))")
        }
        if CommandLine.arguments.count > 3 {
            let realMetalink = try OPDSMetalink.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), sourceURL: URL(string: "https://lb.download.kiwix.org/zim/devdocs/devdocs_en_influxdata_2026-10.zim.meta4")!, declaredLength: 1873920)
            precondition(realMetalink.sha256 != nil && realMetalink.filename?.hasSuffix(".zim") == true)
            print("PASS: real Metalink resolved exact size, SHA-256 and HTTPS archive URL; no payload downloaded")
        }
        print("PASS: OPDS namespaces/relative bases, navigation/facets/paging, direct vs protected acquisitions, bounded no-entity XML, Unicode search encoding, persistent pages/search/provenance, write rollback/corrupt preservation, HTTPS/status/stream limits")
    }
}
