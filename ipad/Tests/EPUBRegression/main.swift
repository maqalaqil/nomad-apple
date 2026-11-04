import Foundation

@main struct EPUBRegression {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for filename in ["valid.epub", "epub2.epub"] {
            let book = try EPUBArchive(url: root.appendingPathComponent(filename))
            precondition(book.title == "Offline Test Book")
            precondition(book.author == "Nomad Tests")
            precondition(book.chapters.count == 2 && book.contents.count == 2)
            precondition(book.chapters[0].path == "BOOK/chapter one.xhtml")
            precondition(book.chapters[0].title == "First chapter")
            precondition(book.contents[1].fragment == "second")
            let text = String(decoding: try book.data(path: book.chapters[0].path), as: UTF8.self)
            precondition(text.contains("Navigation by stars"))
            precondition(book.mimeType("BOOK/images/diagram.svg") == "image/svg+xml")
            let image = try book.data(path: "BOOK/images/diagram.svg")
            precondition(!image.isEmpty)
            precondition(EPUBArchive.resolve("../images/diagram.svg", relativeTo: "BOOK/styles/book.css")?.path == "BOOK/images/diagram.svg")
            precondition(EPUBArchive.resolve("https://example.com/remote", relativeTo: book.chapters[0].path) == nil)
            precondition(EPUBArchive.resolve("file:///private/secret", relativeTo: book.chapters[0].path) == nil)
        }
        for filename in ["idpf-font.epub", "adobe-font.epub"] {
            let book = try EPUBArchive(url: root.appendingPathComponent(filename))
            let decoded = try book.data(path: "BOOK/test.otf")
            precondition(decoded == Data((0..<2560).map { UInt8($0 % 256) }))
        }
        for filename in ["unsafe.epub", "drm.epub", "entities.epub", "truncated.epub"] {
            do { _ = try EPUBArchive(url: root.appendingPathComponent(filename)); fatalError("Accepted invalid fixture: \(filename)") }
            catch { print("Rejected \(filename): \(error.localizedDescription)") }
        }
        let corrupt = try EPUBArchive(url: root.appendingPathComponent("crc.epub"))
        do { _ = try corrupt.data(path: "BOOK/chapter2.xhtml"); fatalError("Accepted invalid CRC") }
        catch { print("Rejected corrupt resource: \(error.localizedDescription)") }
        print("PASS: EPUB2/3 spine/navigation, percent paths, compressed chapters/assets, remote/path rejection, font deobfuscation, DRM/XML entity/truncated archive rejection, CRC integrity")
    }
}
