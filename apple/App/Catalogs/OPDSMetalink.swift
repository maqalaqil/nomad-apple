import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct OPDSResolvedAcquisition: Sendable {
    let url: URL
    let length: Int64?
    let sha256: String?
    let filename: String?

    static func resolve(_ link: OPDSLink) async throws -> Self {
        guard link.isDirectAcquisition else { throw OPDSError.invalid("This entry is not a direct acquisition.") }
        if link.url.pathExtension.lowercased() == "meta4" || link.mediaType.lowercased().contains("application/metalink4+xml") {
            let response = try await OPDSClient.fetch(link.url)
            return try OPDSMetalink.parse(response.data, sourceURL: response.url, declaredLength: link.length)
        }
        return Self(url: link.url, length: link.length, sha256: nil, filename: nil)
    }
}

/// Resolve a single-file Metalink document, never its payload. Public Kiwix catalogs use this indirection.
final class OPDSMetalink: NSObject, XMLParserDelegate {
    private var stack: [(name: String, text: String)] = []
    private var files = 0
    private var nodes = 0
    private var failure: Error?
    private var filename: String?
    private var length: Int64?
    private var sha256: String?
    private var currentHashType: String?
    private var currentPriority = 999_999
    private var mirrors: [(url: URL, priority: Int)] = []
    private let sourceURL: URL
    private init(sourceURL: URL) { self.sourceURL = sourceURL }

    static func parse(_ data: Data, sourceURL: URL, declaredLength: Int64?) throws -> OPDSResolvedAcquisition {
        guard OPDSSafety.https(sourceURL), data.count <= 1_024 * 1_024,
              let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw OPDSError.invalid("Metalink metadata must be UTF-8 XML under 1 MiB without entity declarations.") }
        let reader = OPDSMetalink(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.failure == nil else { throw reader.failure ?? OPDSError.invalid("The Metalink metadata could not be parsed.") }
        guard reader.files == 1, let length = reader.length, let mirror = reader.mirrors.enumerated().min(by: {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
        })?.element else { throw OPDSError.invalid("This Metalink needs exactly one file, a valid size and a direct HTTPS mirror.") }
        // The official Kiwix catalog publishes length rounded up to KiB; its
        // HTTPS Metalink supplies the exact byte count and hash.
        // Keep this compatibility narrow and never relax exact sizes elsewhere.
        let kiwixRoundedLength = ["lb.download.kiwix.org", "download.kiwix.org"].contains(sourceURL.host?.lowercased() ?? "") &&
            reader.sha256 != nil && declaredLength == ((length + 1_023) / 1_024) * 1_024
        guard declaredLength == nil || declaredLength == length || kiwixRoundedLength else { throw OPDSError.invalid("The catalog and Metalink disagree about the publication's size. The download was not queued.") }
        return OPDSResolvedAcquisition(url: mirror.url, length: length, sha256: reader.sha256, filename: reader.filename)
    }
    private func reject(_ parser: XMLParser, _ message: String) { failure = OPDSError.invalid(message); parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        nodes += 1
        guard nodes <= 10_000, stack.count < 16 else { reject(parser, "Metalink metadata exceeds its structure limit."); return }
        if stack.isEmpty {
            guard elementName == "metalink", namespaceURI == "urn:ietf:params:xml:ns:metalink" else { reject(parser, "Expected Metalink 4 metadata."); return }
        }
        // Unknown namespaces are not interpreted as file metadata.
        let name = namespaceURI == "urn:ietf:params:xml:ns:metalink" ? elementName : "ignored"
        stack.append((name, ""))
        if name == "file", stack.count == 2 {
            files += 1
            guard files == 1, let name = attributes["name"], !name.isEmpty, name.utf8.count <= 240,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                reject(parser, "Only one safe, named file can be acquired from a Metalink."); return
            }
            filename = name
        }
        if name == "hash", stack.count == 3, stack[1].name == "file" { currentHashType = attributes["type"]?.lowercased() }
        if name == "url", stack.count == 3, stack[1].name == "file" { currentPriority = Int(attributes["priority"] ?? "999999") ?? 999_999 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        guard stack[stack.count - 1].text.utf8.count + string.utf8.count <= 16_384 else { reject(parser, "Metalink metadata has an oversized text field."); return }
        stack[stack.count - 1].text += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let current = stack.last else { return }
        let value = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.count == 3, stack[1].name == "file" {
            if current.name == "size" {
                guard length == nil, let bytes = Int64(value), (1...OPDSSafety.maximumFileBytes).contains(bytes) else { reject(parser, "Metalink file size is invalid or duplicated."); return }
                length = bytes
            }
            if current.name == "hash", currentHashType == "sha-256" || currentHashType == "sha256" {
                guard value.count == 64, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), sha256 == nil || sha256 == value.lowercased() else {
                    reject(parser, "The Metalink SHA-256 is invalid or inconsistent."); return
                }
                sha256 = value.lowercased()
            }
            if current.name == "url", let url = OPDSSafety.resolved(value, base: sourceURL), url.pathExtension.lowercased() != "meta4", mirrors.count < 256 {
                mirrors.append((url, max(1, currentPriority)))
            }
        }
        if current.name == "hash" { currentHashType = nil }
        stack.removeLast()
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser, "External Metalink entities are forbidden."); return nil }
}
