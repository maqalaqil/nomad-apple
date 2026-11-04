import Foundation
import zlib

/// A bounded, read-only ZIP reader. No archive paths are extracted to the filesystem.
/// Supports stored/deflated ZIP32 HTML5 packages; rejects encrypted, ZIP64 and symlink entries.
struct CourseZipArchive: Sendable {
    struct Entry: Sendable { let name: String; let flags: UInt16; let method: UInt16; let crc: UInt32; let compressed: Int; let size: Int; let offset: Int }
    private let data: Data
    private var entries: [String: Entry] = [:]
    var names: [String] { entries.keys.sorted() }

    init(url: URL) throws {
        try CoursePaths.regularFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 1_073_741_824 else { throw CourseError.invalid("HTML5 ZIP packages must be at most 1 GB.") }
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw CourseError.invalid("The HTML5 package is not a complete ZIP archive.") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(offset) == 0x06054b50, offset + 22 + Int(u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10),
              u16(end + 10) < 10_000, u32(end + 12) != UInt32.max, u32(end + 16) != UInt32.max else {
            throw CourseError.invalid("Split, ZIP64, or oversized HTML5 archives are not supported.")
        }
        let directorySize = Int(u32(end + 12)), directoryOffset = Int(u32(end + 16))
        guard directoryOffset <= end, directorySize <= end - directoryOffset else { throw CourseError.invalid("The ZIP directory is invalid.") }
        var offset = directoryOffset, total = 0
        for _ in 0..<Int(u16(end + 10)) {
            guard offset + 46 <= end, u32(offset) == 0x02014b50 else { throw CourseError.invalid("The ZIP directory is damaged.") }
            let flags = u16(offset + 8), method = u16(offset + 10)
            let compressed = Int(u32(offset + 20)), size = Int(u32(offset + 24))
            let nameLength = Int(u16(offset + 28)), extraLength = Int(u16(offset + 30)), commentLength = Int(u16(offset + 32))
            let localOffset = Int(u32(offset + 42)), unixMode = u32(offset + 38) >> 16
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= directoryOffset + directorySize, flags & 1 == 0, [UInt16(0), 8].contains(method),
                  size <= 128 * 1_024 * 1_024, compressed <= data.count,
                  (unixMode & 0xf000) != 0xa000,
                  let name = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)), encoding: .utf8),
                  Self.safePath(name), entries[name] == nil else {
                throw CourseError.invalid("The ZIP contains unsupported, duplicate, unsafe, or oversized entries.")
            }
            total += size
            guard total <= 512 * 1_024 * 1_024 else { throw CourseError.invalid("The HTML5 package expands beyond the 512 MB limit.") }
            entries[name] = Entry(name: name, flags: flags, method: method, crc: u32(offset + 16), compressed: compressed, size: size, offset: localOffset)
            offset = next
        }
        guard offset == directoryOffset + directorySize else { throw CourseError.invalid("The ZIP directory length does not match its entries.") }
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
    }
    private func u16(_ index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= data.count else { return 0 }
        return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }
    private func u32(_ index: Int) -> UInt32 { UInt32(u16(index)) | UInt32(u16(index + 2)) << 16 }

    func read(_ path: String) throws -> Data {
        guard Self.safePath(path), let entry = entries[path], !path.hasSuffix("/"),
              entry.offset >= 0, entry.offset + 30 <= data.count, u32(entry.offset) == 0x04034b50,
              u16(entry.offset + 6) == entry.flags, u16(entry.offset + 8) == entry.method else {
            throw CourseError.invalid("The requested HTML5 resource is missing or invalid.")
        }
        let nameLength = Int(u16(entry.offset + 26)), extraLength = Int(u16(entry.offset + 28))
        let start = entry.offset + 30 + nameLength + extraLength
        guard start <= data.count, entry.compressed <= data.count - start,
              String(data: data.subdata(in: (entry.offset + 30)..<(entry.offset + 30 + nameLength)), encoding: .utf8) == entry.name else {
            throw CourseError.invalid("The ZIP entry header is inconsistent.")
        }
        let compressed = data.subdata(in: start..<(start + entry.compressed))
        let result: Data
        if entry.method == 0 {
            guard compressed.count == entry.size else { throw CourseError.invalid("The ZIP entry size is invalid.") }
            result = compressed
        } else {
            var output = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw CourseError.invalid("The HTML5 decompressor could not start.")
            }
            defer { inflateEnd(&stream) }
            let status = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { target in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == compressed.count else {
                throw CourseError.invalid("The compressed HTML5 entry is damaged.")
            }
            result = output.prefix(entry.size)
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(result.count)) }
        guard UInt32(checksum) == entry.crc else { throw CourseError.invalid("The HTML5 entry failed its checksum check.") }
        return result
    }

    func entryPoint() throws -> String {
        if entries["index.html"] != nil { return "index.html" }
        if entries["index.htm"] != nil { return "index.htm" }
        if entries["imsmanifest.xml"] != nil {
            let parser = XMLParser(data: try read("imsmanifest.xml"))
            let delegate = CourseManifestParser()
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), let entry = delegate.entry, Self.safePath(entry), entries[entry] != nil else {
                throw CourseError.invalid("The SCORM package has no supported local launch resource.")
            }
            return entry
        }
        throw CourseError.invalid("This package has no index.html or supported SCORM launch manifest.")
    }
}

private final class CourseManifestParser: NSObject, XMLParserDelegate {
    var entry: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.split(separator: ":").last == "resource", entry == nil, let href = attributeDict["href"],
           let components = URLComponents(string: href), components.scheme == nil, components.host == nil {
            entry = components.path.removingPercentEncoding
        }
    }
}
