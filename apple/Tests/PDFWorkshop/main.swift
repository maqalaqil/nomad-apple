import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

var checks = 0
func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PDFWorkshopError.message("FAILED: \(message)") }
    checks += 1
}
func rejects(_ operation: () throws -> Void, _ message: String) throws {
    do { try operation() } catch { checks += 1; return }
    throw PDFWorkshopError.message("FAILED: \(message)")
}

func visibleText(_ text: String, at point: CGPoint, in context: CGContext) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil)]))
    context.textMatrix = .identity; context.textPosition = point; context.setTextDrawingMode(.fill)
    CTLineDraw(line, context)
}

func fixture(imageOnly: Bool = false, rotation: Int = 0, crop: CGRect? = nil, pages: Int = 1) throws -> Data {
    let buffer = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    let consumer = CGDataConsumer(data: buffer)!
    let context = CGContext(consumer: consumer, mediaBox: &bounds, [kCGPDFContextTitle as String: "hidden metadata SECRET42"] as CFDictionary)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        func draw(_ context: CGContext) {
            context.setFillColor(gray: 1, alpha: 1); context.fill(bounds)
            context.setFillColor(gray: 0, alpha: 1)
            visibleText("SECRET42", at: CGPoint(x: 100, y: 650), in: context)
            visibleText("PUBLIC INFORMATION", at: CGPoint(x: 100, y: 100), in: context)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 30, height: 30))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 500, y: 700, width: 30, height: 30))
        }
        if imageOnly {
            let bitmap = CGContext(data: nil, width: 1200, height: 1600, bitsPerComponent: 8, bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            bitmap.scaleBy(x: 2, y: 2); draw(bitmap)
            context.draw(bitmap.makeImage()!, in: bounds)
        } else { draw(context) }
        context.endPDFPage()
    }
    context.closePDF()
    let doc = PDFDocument(data: buffer as Data)!
    for index in 0..<pages {
        doc.page(at: index)!.rotation = rotation
        if let crop { doc.page(at: index)!.setBounds(crop, for: .cropBox) }
    }
    return doc.dataRepresentation()!
}

func rgba(_ image: CGImage) -> [UInt8] {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}
func png(_ image: CGImage, _ name: String) throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDF_TEST_ARTIFACTS"] ?? "/tmp/nomad-pdf-workshop")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "write visual artifact")
}

@main struct PDFWorkshopTests {
    static func main() async throws {
        let source = try fixture(pages: 2)
        let original = try PDFWorkshopEngine.document(source)
        try expect(original.string!.contains("SECRET42"), "source secret is extractable")
        let mask = PDFWorkshopMark(page: 0, kind: .redact, rectangle: CGRect(x: 0.14, y: 0.14, width: 0.39, height: 0.08))
        let result = try PDFWorkshopEngine.redactedPDF(source, marks: [mask])
        let redacted = try PDFWorkshopEngine.document(result)
        try expect(redacted.pageCount == 2, "redaction preserves all pages")
        try expect((redacted.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no text can be extracted, including untouched pages")
        try expect(!String(describing: redacted.documentAttributes).contains("SECRET42"), "original metadata removed")
        try expect(!result.contains(Data("SECRET42".utf8)), "source string absent from exported bytes")
        for index in 0..<redacted.pageCount {
            let page = redacted.page(at: index)!
            try expect(page.annotations.isEmpty, "no surviving annotations or widgets")
            var fonts: CGPDFDictionaryRef?
            var resources: CGPDFDictionaryRef?
            let dictionary = page.pageRef!.dictionary!
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            try expect(resources != nil, "raster output has resources")
            try expect(!CGPDFDictionaryGetDictionary(resources!, "Font", &fonts), "raster output contains no font resources")
            var xobjects: CGPDFDictionaryRef?
            try expect(CGPDFDictionaryGetDictionary(resources!, "XObject", &xobjects), "raster output contains page image")
            final class ResourceCheck { var count = 0; var imageOnly = true }
            let resource = ResourceCheck()
            CGPDFDictionaryApplyFunction(xobjects!, { _, object, pointer in
                let check = Unmanaged<ResourceCheck>.fromOpaque(pointer!).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { check.imageOnly = false; return }
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(CGPDFStreamGetDictionary(stream)!, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" { check.count += 1 }
                else { check.imageOnly = false }
            }, Unmanaged.passUnretained(resource).toOpaque())
            try expect(resource.imageOnly && resource.count == 1, "no original form XObjects retained; single raster only")
        }
        try expect(original.string!.contains("SECRET42"), "original unchanged after redaction")
        try png(PDFWorkshopEngine.render(redacted.page(at: 0)!, longestSide: 800), "redacted.png")
        let pixels = rgba(try PDFWorkshopEngine.render(redacted.page(at: 0)!, longestSide: 800))
        // CGImage's first scanline is the visual top of the rendered page.
        let blackOffset = (150 * 600 + 180) * 4
        try expect(pixels[blackOffset] < 8 && pixels[blackOffset + 1] < 8 && pixels[blackOffset + 2] < 8, "redaction covers selected top-left coordinates")
        let redactedRecognition = try PDFWorkshopEngine.recognize(PDFWorkshopEngine.render(redacted.page(at: 0)!), languages: ["en-US"]).map(\.text).joined(separator: " ")
        try expect(!redactedRecognition.contains("SECRET42") && redactedRecognition.contains("PUBLIC"), "OCR cannot recover masked text but still recognizes public pixels")
        try rejects({ _ = try PDFWorkshopEngine.redactedPDF(source, marks: []) }, "unselected redaction rejected")
        try rejects({ _ = try PDFWorkshopEngine.redactedPDF(source, marks: [PDFWorkshopMark(page: 0, kind: .redact, rectangle: CGRect(x: -0.1, y: 0, width: 0.5, height: 0.2))]) }, "off-page redaction rejected")

        let scan = try fixture(imageOnly: true)
        let scanned = try PDFWorkshopEngine.document(scan)
        try expect((scanned.string ?? "").isEmpty, "scan has no embedded text")
        let box = CGRect(x: 0.16, y: 0.80, width: 0.38, height: 0.045)
        let searchable = try PDFWorkshopEngine.searchablePDF(scan, pages: [0], recognizer: { _ in [PDFWorkshopOCRLine(text: "SEARCHABLE SECRET42", bounds: box)] })
        let ocr = try PDFWorkshopEngine.document(searchable.data)
        try expect(searchable.lines == 1 && searchable.skippedPages == 0, "OCR counts recorded")
        try expect(ocr.string?.contains("SEARCHABLE SECRET42") == true, "invisible Unicode text survives reopen")
        let selections = ocr.findString("SEARCHABLE SECRET42", withOptions: [])
        try expect(selections.count == 1, "OCR result is searchable")
        let actual = selections[0].bounds(for: ocr.page(at: 0)!)
        let target = CGRect(x: box.minX * 600, y: box.minY * 800, width: box.width * 600, height: box.height * 800)
        try expect(abs(actual.midX - target.midX) < 2 && abs(actual.width - target.width) < 3, "OCR text x/width matches recognized rectangle")
        try expect(actual.intersection(target).height >= target.height * 0.75, "OCR selectable bounds overlap recognized text vertically")
        let before = rgba(try PDFWorkshopEngine.render(scanned.page(at: 0)!, longestSide: 800))
        let after = rgba(try PDFWorkshopEngine.render(ocr.page(at: 0)!, longestSide: 800))
        try expect(zip(before, after).filter { abs(Int($0) - Int($1)) > 3 }.count < 100, "OCR layer does not visibly change page")
        try png(PDFWorkshopEngine.render(ocr.page(at: 0)!, longestSide: 800), "searchable.png")
        try rejects({ _ = try PDFWorkshopEngine.searchablePDF(source, pages: [0]) }, "already-searchable pages avoid duplicate OCR")
        try rejects({ _ = try PDFWorkshopEngine.searchablePDF(scan, pages: [0], recognizer: { _ in [] }) }, "empty OCR output rejected")
        let unicode = try PDFWorkshopEngine.searchablePDF(scan, pages: [0], recognizer: { _ in [PDFWorkshopOCRLine(text: "Ελληνικά Русский 日本語", bounds: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.1))] })
        let unicodeText = try PDFWorkshopEngine.document(unicode.data).string ?? ""
        try expect(unicodeText.contains("Ελληνικά") && unicodeText.contains("Русский") && unicodeText.contains("日本語"), "CoreText fallback keeps Greek, Cyrillic and Japanese Unicode extractable")

        for rotation in [0, 90, 180, 270] {
            let cropped = try fixture(imageOnly: true, rotation: rotation, crop: CGRect(x: 50, y: 70, width: 500, height: 660))
            let input = try PDFWorkshopEngine.document(cropped)
            let exported = try PDFWorkshopEngine.searchablePDF(cropped, pages: [0], recognizer: { _ in [PDFWorkshopOCRLine(text: "Rotation \(rotation)", bounds: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.08))] })
            let output = try PDFWorkshopEngine.document(exported.data)
            let size = try PDFWorkshopEngine.size(of: input.page(at: 0)!)
            try expect(output.page(at: 0)!.bounds(for: .mediaBox).size == size, "crop and rotation dimensions \(rotation)")
            let first = rgba(try PDFWorkshopEngine.render(input.page(at: 0)!, longestSide: 800))
            let second = rgba(try PDFWorkshopEngine.render(output.page(at: 0)!, longestSide: 800))
            try expect(first.count == second.count && zip(first, second).filter { abs(Int($0) - Int($1)) > 3 }.count < 200, "crop and rotation visual geometry \(rotation)")
            let found = output.findString("Rotation", withOptions: []).first!
            let rect = found.bounds(for: output.page(at: 0)!)
            try expect(rect.minX >= size.width * 0.19 && rect.maxX <= size.width * 0.61 && rect.midY >= size.height * 0.28 && rect.midY <= size.height * 0.42, "crop and rotation text geometry \(rotation)")
            let masked = try PDFWorkshopEngine.redactedPDF(cropped, marks: [PDFWorkshopMark(page: 0, kind: .redact, rectangle: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))])
            let maskedDocument = try PDFWorkshopEngine.document(masked)
            let maskedPage = maskedDocument.page(at: 0)!
            let maskedImage = try PDFWorkshopEngine.render(maskedPage, longestSide: 800)
            let bytes = rgba(maskedImage), offset = (Int(Double(maskedImage.height) * 0.3) * maskedImage.width + Int(Double(maskedImage.width) * 0.3)) * 4
            try expect(bytes[offset] < 8 && bytes[offset + 1] < 8 && bytes[offset + 2] < 8, "crop and rotation redaction location \(rotation)")
        }

        let annotated = try PDFWorkshopEngine.annotatedPDF(source, marks: [
            PDFWorkshopMark(page: 0, kind: .ink, points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.3, y: 0.45), CGPoint(x: 0.45, y: 0.52)]),
            PDFWorkshopMark(page: 0, kind: .highlight, rectangle: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.1)),
            PDFWorkshopMark(page: 1, kind: .text, rectangle: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2), text: "Visible note")
        ])
        let annotations = try PDFWorkshopEngine.document(annotated)
        try expect(annotations.pageCount == 2 && annotations.string!.contains("Visible note"), "visible note export survives reopen")
        try expect(annotations.string!.contains("SECRET42"), "annotations retain source text; never called redaction")
        try png(PDFWorkshopEngine.render(annotations.page(at: 0)!, longestSide: 800), "annotated.png")
        try rejects({ _ = try PDFWorkshopEngine.annotatedPDF(source, marks: [mask]) }, "redaction marks cannot use annotation export")
        let decorated = try PDFWorkshopEngine.decoratedPDF(source, pages: [1, 0], watermark: "LOCAL COPY", firstPageNumber: 7)
        let decoratedDoc = try PDFWorkshopEngine.document(decorated)
        try expect(decoratedDoc.page(at: 0)!.string!.contains("LOCAL COPY") && decoratedDoc.page(at: 1)!.string!.contains("LOCAL COPY"), "watermark is present on each chosen page")
        try expect(decoratedDoc.page(at: 0)!.string!.contains("8") && decoratedDoc.page(at: 1)!.string!.contains("7"), "page numbering follows selected page order")
        let formDocument = try PDFWorkshopEngine.document(source)
        let widget = PDFAnnotation(bounds: CGRect(x: 80, y: 300, width: 400, height: 50), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text; widget.fieldName = "user-note"; widget.widgetStringValue = "FILLED FIELD"
        formDocument.page(at: 0)!.addAnnotation(widget)
        let flattened = try PDFWorkshopEngine.flattenedPDF(formDocument.dataRepresentation()!)
        let flatDocument = try PDFWorkshopEngine.document(flattened)
        try expect(flatDocument.page(at: 0)!.annotations.isEmpty, "flattened widget is no longer interactive")
        try expect(flatDocument.string?.contains("FILLED FIELD") == true, "flattened form retains visible filled text")
        try expect(flatDocument.string?.contains("SECRET42") == true, "flatten preserves source text and is explicitly not redaction")
        let longText = String(repeating: "A paragraph of offline text.\n", count: 200)
        let text = try PDFWorkshopEngine.textPDF(longText)
        let textDoc = try PDFWorkshopEngine.document(text)
        try expect(textDoc.pageCount > 1 && textDoc.string!.contains("offline text"), "text PDF paginates and is searchable")
        let html = try PDFWorkshopEngine.textHTML("<script>alert(1)</script> & offline")
        try expect(html.contains("&lt;script&gt;") && !html.contains("<script>"), "HTML text escaped")
        try expect(html.contains("default-src 'none'"), "HTML has no network dependencies")
        let imageExports = try PDFWorkshopEngine.pageImages(source, pages: [1, 0])
        try expect(imageExports.count == 2 && imageExports[0].name == "page-2.png", "PNG preserves selected order")
        let fromImages = try PDFWorkshopEngine.imagesPDF(imageExports.map(\.data))
        try expect(try PDFWorkshopEngine.document(fromImages).pageCount == 2, "images become PDF pages")
        try rejects({ _ = try PDFWorkshopEngine.imagesPDF([Data("not an image".utf8)]) }, "invalid image rejected")
        try rejects({ _ = try PDFWorkshopEngine.pageImages(source, pages: [0, 0]) }, "duplicate selected pages rejected")
        try rejects({ _ = try PDFWorkshopEngine.document(Data(repeating: 0, count: PDFWorkshopEngine.maximumBytes + 1)) }, "oversized input rejected")
        let temporary = FileManager.default.temporaryDirectory
        let beforeFiles = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("nomad-pdf-") && $0.hasSuffix(".pdf") })
        let cancelled = Task.detached { () throws -> Data in
            try PDFWorkshopEngine.redactedPDF(source, marks: [mask]) { progress in
                if progress >= 0.5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; throw PDFWorkshopError.message("FAILED: cancellation") }
        catch is CancellationError { checks += 1 }
        let afterFiles = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("nomad-pdf-") && $0.hasSuffix(".pdf") })
        try expect(beforeFiles == afterFiles, "cancelled PDF export removes its partial temporary file")
        let fileFolder = temporary.appendingPathComponent("nomad-pdf-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fileFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileFolder) }
        let regular = fileFolder.appendingPathComponent("source.pdf"), link = fileFolder.appendingPathComponent("link.pdf")
        try source.write(to: regular)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        try expect(try PDFWorkshopEngine.readSelectedFile(regular) == source, "coordinated input reads exact bytes")
        try rejects({ _ = try PDFWorkshopEngine.readSelectedFile(link) }, "symlink input rejected")
        try rejects({ _ = try PDFWorkshopEngine.readSelectedFile(regular, maximum: 2) }, "bounded input rejects oversized file before reading")

        // Real Vision recognition supplements deterministic positioning tests.
        let real = try PDFWorkshopEngine.searchablePDF(scan, pages: [0], languages: ["en-US"])
        let recognized = try PDFWorkshopEngine.document(real.data)
        try expect(recognized.string?.contains("SECRET42") == true, "actual on-device Vision OCR recognizes fixture")
        print("PASS: \(checks) PDF Workshop checks; permanent raster redaction, hidden searchable text, crop/rotation geometry, annotations, conversions, limits and Vision OCR")
    }
}
