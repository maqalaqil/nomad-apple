import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit
import zlib

struct EPUBFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct EPUBChapter: Identifiable, Sendable {
    let title: String
    let path: String
    let fragment: String?
    var id: String { path + "#" + (fragment ?? "") }
}

/// Immutable ZIP directory and mapped archive bytes. No archive entry is extracted into the filesystem.
final class EPUBArchive: @unchecked Sendable {
    let title: String
    let author: String
    let chapters: [EPUBChapter]
    let contents: [EPUBChapter]
    private let zip: EPUBZIP
    private let mediaTypes: [String: String]
    private let fontKeys: [String: (key: [UInt8], count: Int)]

    init(url: URL) throws {
        let zip = try EPUBZIP(url: url)
        guard String(data: try zip.read("mimetype"), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw EPUBFailure(message: "This file is not an EPUB container.")
        }
        let container = try EPUBXML.parse(zip.read("META-INF/container.xml"))
        guard let packagePath = container.descendants("rootfile").first?.attributes["full-path"], EPUBZIP.safePath(packagePath) else {
            throw EPUBFailure(message: "The EPUB does not name a valid package document.")
        }
        let package = try EPUBXML.parse(zip.read(packagePath))
        title = package.descendants("title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? url.deletingPathExtension().lastPathComponent
        author = package.descendants("creator").first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var manifest: [String: (path: String, mime: String, properties: String)] = [:]
        var types: [String: String] = [:]
        for item in package.descendants("manifest").first?.children ?? [] where item.name == "item" {
            guard let id = item.attributes["id"], let href = item.attributes["href"],
                  let resolved = Self.resolve(href, relativeTo: packagePath), zip.contains(resolved.path) else { continue }
            let mime = item.attributes["media-type"] ?? "application/octet-stream"
            manifest[id] = (resolved.path, mime, item.attributes["properties"] ?? "")
            types[resolved.path] = mime
        }
        let spine = package.descendants("spine").first
        var chapters: [EPUBChapter] = []
        for item in spine?.children ?? [] where item.name == "itemref" {
            guard let id = item.attributes["idref"], let resource = manifest[id],
                  ["application/xhtml+xml", "text/html", "image/svg+xml"].contains(resource.mime) else { continue }
            chapters.append(EPUBChapter(title: "Chapter \(chapters.count + 1)", path: resource.path, fragment: nil))
        }
        guard !chapters.isEmpty else { throw EPUBFailure(message: "The EPUB contains no readable HTML or SVG chapters.") }
        var contents: [EPUBChapter] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let xml = try? EPUBXML.parse(zip.read(nav.path)),
           let toc = xml.descendants("nav").first(where: { ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").split(separator: " ").contains("toc") }) {
            contents = toc.descendants("a").compactMap { node in
                guard let href = node.attributes["href"], let resolved = Self.resolve(href, relativeTo: nav.path), zip.contains(resolved.path) else { return nil }
                return EPUBChapter(title: node.text.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "Section", path: resolved.path, fragment: resolved.fragment)
            }
        } else if let tocID = spine?.attributes["toc"], let ncx = manifest[tocID], let xml = try? EPUBXML.parse(zip.read(ncx.path)) {
            contents = xml.descendants("navPoint").compactMap { node in
                guard let href = node.children.first(where: { $0.name == "content" })?.attributes["src"],
                      let resolved = Self.resolve(href, relativeTo: ncx.path), zip.contains(resolved.path) else { return nil }
                let label = node.children.first(where: { $0.name == "navLabel" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return EPUBChapter(title: label?.nonempty ?? "Section", path: resolved.path, fragment: resolved.fragment)
            }
        }
        chapters = chapters.map { chapter in
            EPUBChapter(title: contents.first(where: { $0.path == chapter.path })?.title ?? chapter.title, path: chapter.path, fragment: nil)
        }
        self.chapters = chapters
        self.contents = contents.isEmpty ? chapters : contents
        mediaTypes = types
        self.zip = zip
        var fontKeys: [String: (key: [UInt8], count: Int)] = [:]
        if zip.contains("META-INF/encryption.xml") {
            let encryption = try EPUBXML.parse(zip.read("META-INF/encryption.xml"))
            let uniqueID = package.attributes["unique-identifier"]
            let identifier = package.descendants("identifier").first(where: { $0.attributes["id"] == uniqueID })?.text ?? ""
            for encrypted in encryption.descendants("EncryptedData") {
                let algorithm = encrypted.descendants("EncryptionMethod").first?.attributes["Algorithm"]
                guard let href = encrypted.descendants("CipherReference").first?.attributes["URI"],
                      let resolved = Self.resolve(href, relativeTo: ""), zip.contains(resolved.path) else {
                    throw EPUBFailure(message: "The EPUB has invalid encryption metadata.")
                }
                if algorithm == "http://www.idpf.org/2008/embedding", !identifier.isEmpty {
                    let normalized = identifier.filter { !$0.isWhitespace }
                    fontKeys[resolved.path] = (Array(Insecure.SHA1.hash(data: Data(normalized.utf8))), 1040)
                } else if algorithm == "http://ns.adobe.com/pdf/enc#RC", let uuid = UUID(uuidString: identifier.replacingOccurrences(of: "urn:uuid:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                    var value = uuid.uuid
                    fontKeys[resolved.path] = (withUnsafeBytes(of: &value) { Array($0) }, 1024)
                } else { throw EPUBFailure(message: "This EPUB uses DRM or an unsupported encryption method. Import an unencrypted EPUB to read it offline.") }
            }
        }
        self.fontKeys = fontKeys
    }

    func data(path: String) throws -> Data {
        var result = try zip.read(path)
        if let font = fontKeys[path] {
            for index in 0..<min(result.count, font.count) { result[index] ^= font.key[index % font.key.count] }
        }
        return result
    }

    func contains(_ path: String) -> Bool { zip.contains(path) }
    func mimeType(_ path: String) -> String {
        if let mime = mediaTypes[path] { return mime }
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": return "application/xhtml+xml"
        case "css": return "text/css"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    static func url(path: String, fragment: String? = nil) -> URL? {
        guard EPUBZIP.safePath(path) else { return nil }
        var parts = URLComponents(); parts.scheme = "nomadepub"; parts.host = "book"; parts.path = "/" + path; parts.fragment = fragment
        return parts.url
    }
    static func resolve(_ href: String, relativeTo path: String) -> (path: String, fragment: String?)? {
        let base = path.isEmpty ? URL(string: "nomadepub://book/")! : url(path: path)
        guard let base, let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme == "nomadepub", url.host == "book", url.user == nil, url.password == nil else { return nil }
        let normalized = url.standardized.path
        let resolved = String(normalized.dropFirst())
        guard normalized.hasPrefix("/"), EPUBZIP.safePath(resolved) else { return nil }
        return (resolved, url.fragment)
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }

private struct EPUBZIP: Sendable {
    struct Entry: Sendable { let offset: Int; let compressed: Int; let size: Int; let method: UInt16; let checksum: UInt32 }
    let bytes: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 2_000_000_000 else {
            throw EPUBFailure(message: "Choose an EPUB file smaller than 2 GB.")
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 22 else { throw EPUBFailure(message: "The EPUB archive is truncated.") }
        var end: Int?
        for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if bytes.u32(index) == 0x06054b50, index + 22 + Int(bytes.u16(index + 20)) == bytes.count { end = index; break }
        }
        guard let end, bytes.u16(end + 4) == 0, bytes.u16(end + 6) == 0,
              bytes.u16(end + 8) == bytes.u16(end + 10), bytes.u16(end + 10) < 50_000 else {
            throw EPUBFailure(message: "Split, ZIP64, or oversized EPUB directories are not supported.")
        }
        let count = Int(bytes.u16(end + 10)), directorySize = Int(bytes.u32(end + 12)), directory = Int(bytes.u32(end + 16))
        guard directory <= end, directorySize <= end - directory else { throw EPUBFailure(message: "The EPUB ZIP directory is invalid.") }
        var entries: [String: Entry] = [:], cursor = directory, totalSize = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, bytes.u32(cursor) == 0x02014b50 else { throw EPUBFailure(message: "The EPUB ZIP directory is damaged.") }
            let flags = bytes.u16(cursor + 8), method = bytes.u16(cursor + 10)
            let compressed = Int(bytes.u32(cursor + 20)), size = Int(bytes.u32(cursor + 24))
            let nameLength = Int(bytes.u16(cursor + 28)), extraLength = Int(bytes.u16(cursor + 30)), commentLength = Int(bytes.u16(cursor + 32))
            let offset = Int(bytes.u32(cursor + 42))
            guard flags & 1 == 0, [0, 8].contains(method), bytes.u16(cursor + 34) == 0,
                  size <= 64 * 1_024 * 1_024, compressed <= 64 * 1_024 * 1_024,
                  cursor + 46 + nameLength + extraLength + commentLength <= directory + directorySize,
                  offset + 30 <= directory else {
                throw EPUBFailure(message: "This EPUB uses unsupported encryption, compression, or an entry over 64 MB.")
            }
            guard let name = String(data: bytes.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else {
                throw EPUBFailure(message: "An EPUB filename is not UTF-8.")
            }
            cursor += 46 + nameLength + extraLength + commentLength
            if name.hasSuffix("/") { continue }
            guard Self.safePath(name), entries[name] == nil else { throw EPUBFailure(message: "The EPUB contains unsafe or duplicate file paths.") }
            totalSize += size
            guard totalSize <= 2_000_000_000 else { throw EPUBFailure(message: "The expanded EPUB exceeds the 2 GB reading limit.") }
            guard bytes.u32(offset) == 0x04034b50, bytes.u16(offset + 6) & 1 == 0, bytes.u16(offset + 8) == method else {
                throw EPUBFailure(message: "The EPUB entry header is invalid.")
            }
            let localNameLength = Int(bytes.u16(offset + 26)), localExtra = Int(bytes.u16(offset + 28))
            let payload = offset + 30 + localNameLength + localExtra
            guard payload <= directory, compressed <= directory - payload,
                  String(data: bytes.subdata(in: offset + 30..<offset + 30 + localNameLength), encoding: .utf8) == name else {
                throw EPUBFailure(message: "The EPUB entry is truncated or has inconsistent names.")
            }
            entries[name] = Entry(offset: payload, compressed: compressed, size: size, method: method, checksum: bytes.u32(cursor - 46 - nameLength - extraLength - commentLength + 16))
        }
        self.bytes = bytes; self.entries = entries
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < 4_096 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
    func contains(_ path: String) -> Bool { entries[path] != nil }
    func read(_ path: String) throws -> Data {
        guard let entry = entries[path] else { throw EPUBFailure(message: "The EPUB resource ‘\(path)’ is missing.") }
        let compressed = bytes.subdata(in: entry.offset..<entry.offset + entry.compressed)
        var result: Data
        if entry.method == 0 {
            guard entry.compressed == entry.size else { throw EPUBFailure(message: "An uncompressed EPUB entry has an invalid size.") }
            result = compressed
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw EPUBFailure(message: "EPUB decompression could not start.") }
            defer { inflateEnd(&stream) }
            result = Data(count: max(1, entry.size))
            let status = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output in
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(entry.compressed)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(max(1, entry.size))
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == entry.compressed else { throw EPUBFailure(message: "The EPUB contains damaged compressed data.") }
            result.count = entry.size
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(result.count)) }
        guard UInt32(checksum) == entry.checksum else { throw EPUBFailure(message: "An EPUB resource failed its CRC integrity check.") }
        return result
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}

private final class EPUBXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func descendants(_ name: String) -> [Node] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var nodes = 0
    private var textBytes = 0
    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 4 * 1_024 * 1_024 else { throw EPUBFailure(message: "The EPUB metadata exceeds 4 MB.") }
        let delegate = EPUBXML(), parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else { throw EPUBFailure(message: "The EPUB metadata is invalid XML. \(parser.parserError?.localizedDescription ?? "")") }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes += 1
        guard nodes <= 50_000, stack.count < 100 else { parser.abortParsing(); return }
        let node = Node(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributeDict)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count * stack.count
        guard textBytes <= 16 * 1_024 * 1_024 else { parser.abortParsing(); return }
        for node in stack { node.text += string }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
}
