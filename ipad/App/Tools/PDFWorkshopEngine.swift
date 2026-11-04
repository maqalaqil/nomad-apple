import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum PDFWorkshopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Coordinates shared by the editor and export engine: normalized, top-left origin.
/// They refer to the visible, rotated crop box, not the original PDF media box.
struct PDFWorkshopMark: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case redact, ink, highlight, text }
    let id: UUID
    let page: Int
    let kind: Kind
    let rectangle: CGRect
    let points: [CGPoint]
    let text: String

    init(page: Int, kind: Kind, rectangle: CGRect = .zero, points: [CGPoint] = [], text: String = "") {
        id = UUID(); self.page = page; self.kind = kind; self.rectangle = rectangle; self.points = points; self.text = text
    }
}

struct PDFWorkshopOCRLine: Sendable {
    let text: String
    /// Vision coordinates: normalized, bottom-left origin in the rendered page.
    let bounds: CGRect
}

struct PDFWorkshopImage: Sendable { let name: String; let data: Data }
struct PDFWorkshopOCRResult: Sendable { let data: Data; let lines: Int; let skippedPages: Int }

enum PDFWorkshopEngine {
    static let maximumBytes = 150 * 1_024 * 1_024
    static let maximumPages = 500
    static let maximumRasterPages = 100
    static let maximumPixels = 4_096

    static func readSelectedFile(_ url: URL, maximum: Int = maximumBytes) throws -> Data {
        guard url.isFileURL else { throw PDFWorkshopError.message("Choose a local file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { selected in
            result = Result {
                try Task.checkCancellation()
                let properties = try selected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      let size = properties.fileSize, size >= 0, size <= maximum else {
                    throw PDFWorkshopError.message("Choose a regular file within the operation's size limit.")
                }
                let descriptor = open(selected.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_size >= 0, metadata.st_size <= maximum else {
                    throw PDFWorkshopError.message("Choose a regular file within the operation's size limit.")
                }
                let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
                guard bytes.count <= maximum else { throw PDFWorkshopError.message("The selected file exceeds the size limit.") }
                return bytes
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PDFWorkshopError.message("Could not coordinate the selected file.") }
        return try result.get()
    }

    static func document(_ data: Data) throws -> PDFDocument {
        guard !data.isEmpty, data.count <= maximumBytes, let document = PDFDocument(data: data),
              !document.isLocked, document.pageCount > 0, document.pageCount <= maximumPages else {
            throw PDFWorkshopError.message("Use an unlocked PDF of at most 150 MB and 500 pages.")
        }
        return document
    }

    static func indices(_ indices: [Int], in document: PDFDocument, maximum: Int = maximumPages) throws {
        guard !indices.isEmpty, indices.count <= maximum, Set(indices).count == indices.count,
              indices.allSatisfy({ $0 >= 0 && $0 < document.pageCount }) else {
            throw PDFWorkshopError.message("Choose a nonempty set of distinct pages, at most \(maximum) per operation.")
        }
    }

    static func size(of page: PDFPage) throws -> CGSize {
        let box = page.bounds(for: .cropBox)
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width >= 1, box.height >= 1, box.width <= 14_400, box.height <= 14_400 else {
            throw PDFWorkshopError.message("A page has unsupported or invalid dimensions.")
        }
        let rotation = ((page.rotation % 360) + 360) % 360
        guard [0, 90, 180, 270].contains(rotation) else { throw PDFWorkshopError.message("Unsupported page rotation.") }
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    static func pageRectangle(_ normalized: CGRect, size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }

    private static func drawPage(_ page: PDFPage, in context: CGContext) {
        context.saveGState()
        page.displaysAnnotations = true
        // PDFKit applies crop-box origin and /Rotate itself, and draws visible annotations.
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    static func render(_ page: PDFPage, longestSide: Int = 2_800, masks: [CGRect] = []) throws -> CGImage {
        try Task.checkCancellation()
        let size = try size(of: page)
        let scale = min(CGFloat(maximumPixels), CGFloat(max(64, longestSide))) / max(size.width, size.height)
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFWorkshopError.message("Could not allocate the bounded page image.")
        }
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        drawPage(page, in: context)
        // Masks are painted INTO the sole exported bitmap, never as removable PDF objects.
        context.setBlendMode(.copy)
        context.setFillColor(gray: 0, alpha: 1)
        for mask in masks {
            let rect = pageRectangle(mask, size: size)
            // Expand one raster pixel to cover anti-aliased edges of a selected region.
            context.fill(rect.insetBy(dx: -size.width / CGFloat(width), dy: -size.height / CGFloat(height)))
        }
        guard let image = context.makeImage() else { throw PDFWorkshopError.message("Could not render a page.") }
        return image
    }

    static func preview(_ data: Data, page index: Int) throws -> CGImage {
        let document = try document(data)
        guard let page = document.page(at: index) else { throw PDFWorkshopError.message("Page is unavailable.") }
        return try render(page, longestSide: 1_600)
    }

    private static func writePDF(pageCount: Int, draw: (CGContext, Int) throws -> Void) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFWorkshopError.message("Could not create the output PDF.")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for index in 0..<pageCount {
            try Task.checkCancellation()
            try autoreleasepool { try draw(context, index) }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard bytes <= maximumBytes else { throw PDFWorkshopError.message("The generated output exceeds 150 MB. Use a smaller batch.") }
        }
        context.closePDF(); closed = true
        try Task.checkCancellation()
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumBytes else { throw PDFWorkshopError.message("The generated PDF is empty or exceeds 150 MB.") }
        let data = try Data(contentsOf: url)
        guard let result = PDFDocument(data: data), !result.isLocked, result.pageCount == pageCount else {
            throw PDFWorkshopError.message("The exported PDF could not be reopened with all expected pages.")
        }
        return data
    }

    private static func beginPage(_ context: CGContext, size: CGSize) {
        var bounds = CGRect(origin: .zero, size: size)
        let box = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
    }

    static func recognize(_ image: CGImage, languages: [String] = []) throws -> [PDFWorkshopOCRLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return PDFWorkshopOCRLine(text: candidate.string, bounds: observation.boundingBox)
        }
    }

    /// CoreText provides Unicode font fallback. Fit the visible glyph bounds, not
    /// the font's line-height box, to Vision's bottom-left image coordinates.
    static func drawOCR(_ line: PDFWorkshopOCRLine, size: CGSize, in context: CGContext) throws {
        guard !line.text.isEmpty, line.text.utf8.count <= 64 * 1_024,
              [line.bounds.minX, line.bounds.minY, line.bounds.width, line.bounds.height].allSatisfy(\.isFinite),
              line.bounds.width > 0, line.bounds.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(line.bounds) else {
            throw PDFWorkshopError.message("OCR returned an invalid text rectangle.")
        }
        let attributed = NSAttributedString(string: line.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let textLine = CTLineCreateWithAttributedString(attributed)
        let glyphBounds = CTLineGetBoundsWithOptions(textLine, [.useGlyphPathBounds])
        guard glyphBounds.width > 0, glyphBounds.height > 0 else { return }
        let target = CGRect(x: line.bounds.minX * size.width, y: line.bounds.minY * size.height,
                            width: line.bounds.width * size.width, height: line.bounds.height * size.height)
        context.saveGState()
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: target.width / glyphBounds.width, y: target.height / glyphBounds.height)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -glyphBounds.minX, y: -glyphBounds.minY)
        context.setTextDrawingMode(.invisible)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }

    static func searchablePDF(_ data: Data, pages: [Int], languages: [String] = [],
                              progress: (Double) -> Void = { _ in },
                              recognizer: ((CGImage) throws -> [PDFWorkshopOCRLine])? = nil) throws -> PDFWorkshopOCRResult {
        let source = try document(data)
        guard source.allowsCopying, source.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit text extraction and document changes.") }
        try indices(pages, in: source, maximum: maximumRasterPages)
        let chosen = Set(pages)
        var lineCount = 0, skipped = 0
        let output = try writePDF(pageCount: source.pageCount) { context, index in
            guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
            let size = try size(of: page)
            beginPage(context, size: size)
            drawPage(page, in: context)
            if chosen.contains(index) {
                if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skipped += 1 }
                else {
                    let image = try render(page)
                    let lines = try recognizer?(image) ?? recognize(image, languages: languages)
                    guard lines.count <= 10_000 else { throw PDFWorkshopError.message("OCR returned too many text regions on a page.") }
                    for line in lines { try Task.checkCancellation(); try drawOCR(line, size: size, in: context) }
                    lineCount += lines.count
                }
            }
            context.endPDFPage()
            progress(Double(index + 1) / Double(source.pageCount))
        }
        guard lineCount > 0 else {
            throw PDFWorkshopError.message(skipped == pages.count ? "Selected pages already have embedded text; no duplicate OCR layer was added." : "No text was recognized. Try clearer scans or a supported recognition language.")
        }
        guard let checked = PDFDocument(data: output), !(checked.string ?? "").isEmpty else {
            throw PDFWorkshopError.message("The OCR PDF did not contain extractable text after reopening.")
        }
        return PDFWorkshopOCRResult(data: output, lines: lineCount, skippedPages: skipped)
    }

    static func validate(_ marks: [PDFWorkshopMark], pageCount: Int) throws {
        guard marks.count <= 2_000 else { throw PDFWorkshopError.message("Use at most 2,000 marks per output.") }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for mark in marks {
            guard (0..<pageCount).contains(mark.page), mark.text.utf8.count <= 4_096, mark.points.count <= 20_000 else {
                throw PDFWorkshopError.message("An annotation exceeds the page or size limits.")
            }
            if mark.kind == .ink {
                guard mark.points.count >= 2, mark.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                    throw PDFWorkshopError.message("A drawing contains invalid points.")
                }
            } else {
                guard [mark.rectangle.minX, mark.rectangle.minY, mark.rectangle.width, mark.rectangle.height].allSatisfy(\.isFinite),
                      mark.rectangle.width > 0, mark.rectangle.height > 0, unit.contains(mark.rectangle),
                      mark.kind != .text || !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PDFWorkshopError.message("Draw a rectangle fully inside the visible page and enter annotation text when needed.")
                }
            }
        }
    }

    static func redactedPDF(_ data: Data, marks: [PDFWorkshopMark], progress: (Double) -> Void = { _ in }) throws -> Data {
        let source = try document(data)
        guard source.allowsDocumentChanges, source.allowsCopying else { throw PDFWorkshopError.message("This PDF does not permit redaction and extraction.") }
        guard source.pageCount <= maximumRasterPages, !marks.isEmpty, marks.allSatisfy({ $0.kind == .redact }) else {
            throw PDFWorkshopError.message("Select at least one redaction rectangle. Redact documents of at most 100 pages per output.")
        }
        try validate(marks, pageCount: source.pageCount)
        let output = try writePDF(pageCount: source.pageCount) { context, index in
            guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
            let size = try size(of: page)
            let image = try render(page, masks: marks.filter { $0.page == index }.map(\.rectangle))
            beginPage(context, size: size)
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.endPDFPage()
            progress(Double(index + 1) / Double(source.pageCount))
        }
        // No source pages, text, metadata, links, forms, attachments or annotations
        // are copied. Each new PDF page has only its already-masked raster image.
        let checked = try document(output)
        guard (checked.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0..<checked.pageCount).allSatisfy({ checked.page(at: $0)?.annotations.isEmpty == true }) else {
            throw PDFWorkshopError.message("Redaction output unexpectedly retained text or annotations. No output was accepted.")
        }
        return output
    }

    static func annotatedPDF(_ data: Data, marks: [PDFWorkshopMark], progress: (Double) -> Void = { _ in }) throws -> Data {
        let source = try document(data)
        guard source.allowsDocumentChanges, !marks.isEmpty, marks.allSatisfy({ $0.kind != .redact }) else {
            throw PDFWorkshopError.message("Add a visible annotation first. Redaction uses its separate permanent-output workflow.")
        }
        try validate(marks, pageCount: source.pageCount)
        return try writePDF(pageCount: source.pageCount) { context, index in
            guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
            let size = try size(of: page)
            beginPage(context, size: size); drawPage(page, in: context)
            for mark in marks where mark.page == index {
                context.saveGState()
                switch mark.kind {
                case .ink:
                    context.setStrokeColor(CGColor(red: 0.06, green: 0.16, blue: 0.55, alpha: 1))
                    context.setLineWidth(max(1, min(size.width, size.height) * 0.003))
                    context.setLineCap(.round); context.setLineJoin(.round)
                    context.beginPath()
                    for (offset, point) in mark.points.enumerated() {
                        let p = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                        if offset == 0 { context.move(to: p) } else { context.addLine(to: p) }
                    }
                    context.strokePath()
                case .highlight:
                    context.setBlendMode(.multiply)
                    context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 0.4))
                    context.fill(pageRectangle(mark.rectangle, size: size))
                case .text:
                    let rect = pageRectangle(mark.rectangle, size: size)
                    let attributed = NSAttributedString(string: mark.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, max(8, min(24, rect.height * 0.65)), nil),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.06, green: 0.16, blue: 0.55, alpha: 1)
                    ])
                    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
                    guard CTFrameGetVisibleStringRange(frame).length == attributed.length else {
                        throw PDFWorkshopError.message("An annotation's text does not fit its rectangle. Enlarge the rectangle or shorten the text.")
                    }
                    context.textMatrix = .identity; CTFrameDraw(frame, context)
                case .redact: break
                }
                context.restoreGState()
            }
            context.endPDFPage(); progress(Double(index + 1) / Double(source.pageCount))
        }
    }

    static func pageImages(_ data: Data, pages: [Int], progress: (Double) -> Void = { _ in }) throws -> [PDFWorkshopImage] {
        let source = try document(data)
        guard source.allowsCopying else { throw PDFWorkshopError.message("This PDF does not permit image extraction.") }
        try indices(pages, in: source, maximum: 50)
        var result: [PDFWorkshopImage] = [], total = 0
        for (offset, index) in pages.enumerated() {
            try Task.checkCancellation()
            let encoded: Data = try autoreleasepool {
                guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
                let image = try render(page)
                let buffer = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
                    throw PDFWorkshopError.message("Could not create a PNG image.")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw PDFWorkshopError.message("PNG encoding failed.") }
                return buffer as Data
            }
            total += encoded.count
            guard total <= maximumBytes else { throw PDFWorkshopError.message("The image batch exceeds 150 MB. Select fewer pages.") }
            guard CGImageSourceCreateWithData(encoded as CFData, nil) != nil else { throw PDFWorkshopError.message("An exported image could not be reopened.") }
            result.append(PDFWorkshopImage(name: "page-\(index + 1).png", data: encoded))
            progress(Double(offset + 1) / Double(pages.count))
        }
        return result
    }

    static func flattenedPDF(_ data: Data, progress: (Double) -> Void = { _ in }) throws -> Data {
        let source = try document(data)
        guard source.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
        let output = try writePDF(pageCount: source.pageCount) { context, index in
            guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
            beginPage(context, size: try size(of: page)); drawPage(page, in: context); context.endPDFPage()
            progress(Double(index + 1) / Double(source.pageCount))
        }
        let checked = try document(output)
        guard (0..<checked.pageCount).allSatisfy({ checked.page(at: $0)?.annotations.isEmpty == true }) else {
            throw PDFWorkshopError.message("The flattened output still has interactive annotations.")
        }
        return output
    }

    static func decoratedPDF(_ data: Data, pages: [Int], watermark: String? = nil, firstPageNumber: Int? = nil,
                             progress: (Double) -> Void = { _ in }) throws -> Data {
        let source = try document(data)
        guard source.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
        try indices(pages, in: source)
        guard watermark != nil || firstPageNumber != nil,
              watermark.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1_024 }) ?? true,
              firstPageNumber.map({ (0...1_000_000).contains($0) }) ?? true else {
            throw PDFWorkshopError.message("Enter a watermark up to 1 KB or a starting page number from 0 to 1,000,000.")
        }
        let order = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element, $0.offset) })
        return try writePDF(pageCount: source.pageCount) { context, index in
            guard let page = source.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
            let size = try size(of: page)
            beginPage(context, size: size); drawPage(page, in: context)
            if let offset = order[index] {
                if let watermark {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: watermark, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.25, alpha: 0.2)
                    ]))
                    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                    let scale = min(1, size.width * 0.75 / max(1, bounds.width))
                    context.saveGState(); context.translateBy(x: size.width / 2, y: size.height / 2)
                    context.rotate(by: .pi / 6); context.scaleBy(x: scale, y: scale)
                    context.textMatrix = .identity; context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
                    CTLineDraw(line, context); context.restoreGState()
                }
                if let firstPageNumber {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(firstPageNumber + offset), attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil)
                    ]))
                    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                    context.saveGState(); context.textMatrix = .identity
                    context.textPosition = CGPoint(x: size.width / 2 - bounds.midX, y: min(18, size.height * 0.03))
                    CTLineDraw(line, context); context.restoreGState()
                }
            }
            context.endPDFPage(); progress(Double(index + 1) / Double(source.pageCount))
        }
    }

    static func imagesPDF(_ images: [Data], progress: (Double) -> Void = { _ in }) throws -> Data {
        guard !images.isEmpty, images.count <= 50, images.reduce(0, { $0 + $1.count }) <= maximumBytes else {
            throw PDFWorkshopError.message("Choose 1–50 images, at most 150 MB combined.")
        }
        return try writePDF(pageCount: images.count) { context, index in
            guard let source = CGImageSourceCreateWithData(images[index] as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels
                  ] as CFDictionary) else { throw PDFWorkshopError.message("An image could not be decoded. Use PNG, JPEG, HEIC or a supported still-image format.") }
            let pageSize = CGSize(width: 612, height: 792)
            beginPage(context, size: pageSize)
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(origin: .zero, size: pageSize))
            let scale = min(540 / CGFloat(image.width), 720 / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: (612 - size.width) / 2, y: (792 - size.height) / 2, width: size.width, height: size.height))
            context.endPDFPage(); progress(Double(index + 1) / Double(images.count))
        }
    }

    static func textPDF(_ text: String) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2 * 1_024 * 1_024 else {
            throw PDFWorkshopError.message("Enter text up to 2 MB.")
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 36, y: 36, width: 540, height: 720), transform: nil)
        var ranges: [CFRange] = [], offset = 0
        while offset < attributed.length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let range = CTFrameGetVisibleStringRange(frame)
            guard range.length > 0, ranges.count < maximumPages else { throw PDFWorkshopError.message("Text does not fit within the 500-page output limit.") }
            ranges.append(range); offset += range.length
        }
        return try writePDF(pageCount: ranges.count) { context, index in
            beginPage(context, size: CGSize(width: 612, height: 792)); context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, ranges[index], path, nil), context)
            context.endPDFPage()
        }
    }

    static func textHTML(_ text: String) throws -> String {
        guard text.utf8.count <= 8 * 1_024 * 1_024 else { throw PDFWorkshopError.message("Extracted text exceeds the 8 MB HTML limit.") }
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>PDF extracted text</title><style>body{font:17px system-ui;max-width:70ch;margin:2rem auto;padding:1rem}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style></head><body><pre>\(escaped)</pre></body></html>"
    }
}
