import SwiftUI
import PDFKit
import Vision
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PDFToolDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    let filename: String
    init(data: Data, filename: String = "document.pdf") { self.data = data; self.filename = filename }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ToolFailure.message("Could not read this PDF.") }
        self.data = data
        filename = configuration.file.preferredFilename ?? "document.pdf"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        return wrapper
    }
}

struct PDFToolInput: Identifiable {
    let id = UUID()
    let name: String
    let document: PDFDocument
    let byteCount: Int
}

struct PDFToolOutput: Identifiable {
    let id = UUID()
    let name: String
    let document: PDFDocument
    let data: Data
    var export: PDFToolDocument { PDFToolDocument(data: data, filename: name) }
}

struct PDFWorkshopExport: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .html] }
    let data: Data
    let filename: String
    init(data: Data, filename: String) { self.data = data; self.filename = filename }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PDFWorkshopError.message("Could not read the export.") }
        self.data = data; filename = configuration.file.preferredFilename ?? "output"
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data); wrapper.preferredFilename = filename; return wrapper
    }
}

private struct PDFMarkupRequest: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let redaction: Bool
}

private enum PDFAdvancedResult {
    case pdf(Data, String, String)
    case images([PDFWorkshopImage])
    case text(String, String)
}

enum PDFPageSelection {
    /// Returns zero-based indices in the requested order; duplicate pages are rejected.
    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw ToolFailure.message("This document has no readable pages.") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<pageCount) }
        var result: [Int] = []
        var seen = Set<Int>()
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = item.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  let start = Int(parts[0].trimmingCharacters(in: .whitespaces)), start >= 1 else {
                throw ToolFailure.message("Use page numbers such as 1-3,5. Page numbers start at 1.")
            }
            let end: Int
            if parts.count == 2 {
                guard let value = Int(parts[1].trimmingCharacters(in: .whitespaces)), value >= start else {
                    throw ToolFailure.message("Each range must run from a lower page number to a higher one.")
                }
                end = value
            } else { end = start }
            guard end <= pageCount else { throw ToolFailure.message("Page \(end) is outside this \(pageCount)-page document.") }
            for page in start...end {
                guard seen.insert(page).inserted else { throw ToolFailure.message("Page \(page) was selected more than once.") }
                result.append(page - 1)
            }
        }
        return result
    }
}

#if os(macOS)
struct PDFToolPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#else
struct PDFToolPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif

struct PDFToolsView: View {
    @State private var inputs: [PDFToolInput] = []
    @State private var selectedInputID: UUID?
    @State private var outputs: [PDFToolOutput] = []
    @State private var selectedOutputID: UUID?
    @State private var pageSelection = ""
    @State private var unlockPassword = ""
    @State private var outputPassword = ""
    @State private var textOutput = ""
    @State private var notice = ""
    @State private var error: String?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportingAll = false
    @State private var exportingText = false
    @State private var previewRevision = 0
    @State private var ocrBusy = false
    @State private var ocrProgress = 0.0
    @State private var ocrTask: Task<Void, Never>?
    @State private var workTitle = "Working on this device"
    @State private var workGeneration = UUID()
    @State private var ocrLanguageTags = ""
    @State private var markupRequest: PDFMarkupRequest?
    @State private var imageOutputs: [PDFWorkshopImage] = []
    @State private var exportingImages = false
    @State private var exportingHTML = false
    @State private var htmlOutput = ""
    @State private var importingImages = false
    @State private var importingText = false
    @State private var creatingText = false
    @State private var sourceText = ""
    @State private var watermarkText = ""
    @State private var firstPageNumber = "1"

    private var selectedInput: PDFToolInput? { inputs.first { $0.id == selectedInputID } }
    private var selectedOutput: PDFToolOutput? { outputs.first { $0.id == selectedOutputID } }
    private var previewDocument: PDFDocument? { selectedOutput?.document ?? selectedInput?.document }
    private var totalBytes: Int { inputs.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        Form {
            Section {
                Label("PDF tools work on local copies.", systemImage: "doc.richtext")
                Text("Import PDFs, make changes, then export the results. The imported files are never overwritten. Temporary work is cleared when you leave this module.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Import PDFs", systemImage: "plus") { importing = true }
                    .disabled(ocrBusy)
                Button("Create PDF from images", systemImage: "photo.on.rectangle") { importingImages = true }.disabled(ocrBusy)
                DisclosureGroup("Create PDF from text", isExpanded: $creatingText) {
                    TextEditor(text: $sourceText).frame(minHeight: 140).accessibilityLabel("Text for new PDF")
                    HStack {
                        Button("Import text file") { importingText = true }
                        Button("Create text PDF") {
                            let text = sourceText
                            runAdvanced("Creating text PDF") { _ in .pdf(try PDFWorkshopEngine.textPDF(text), "text.pdf", "Created a paginated, searchable text PDF. Export to keep it.") }
                        }.disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.buttonStyle(.borderless)
                    Text("Text is typeset on letter-size pages. This does not convert Office documents or preserve HTML layout.").font(.caption).foregroundStyle(.secondary)
                }.disabled(ocrBusy)
            }
            if !inputs.isEmpty {
                inputSection
                if let input = selectedInput {
                    if input.document.isLocked {
                        Section("Unlock \(input.name)") {
                            SecureField("Document password", text: $unlockPassword)
                            Button("Unlock local copy") {
                                if input.document.unlock(withPassword: unlockPassword) {
                                    unlockPassword = ""; previewRevision += 1; notice = "Document unlocked."
                                } else { error = "The password did not unlock this document." }
                            }
                        }
                    } else {
                        operationSection(input)
                    }
                }
            }
            if ocrBusy {
                Section(workTitle) {
                    ProgressView(value: ocrProgress)
                    Button("Cancel operation", role: .cancel) { ocrTask?.cancel() }
                    Text("Processing continues while this view is open. Cancellation takes effect between pages or recognition requests. Partial PDF outputs are discarded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !notice.isEmpty { Section { Text(notice).font(.callout).foregroundStyle(.secondary) } }
            if !outputs.isEmpty { outputSection }
            if !imageOutputs.isEmpty {
                Section("Page images · export to keep") {
                    Text("\(imageOutputs.count) PNG images, in the selected page order.")
                    Button("Export all page images", systemImage: "square.and.arrow.up") { exportingImages = true }
                }.disabled(ocrBusy)
            }
            if let document = previewDocument {
                Section(selectedOutput == nil ? "Input preview" : "Output preview") {
                    PDFToolPreview(document: document).frame(height: 480).id(previewRevision)
                }
            }
            if !textOutput.isEmpty {
                Section("Extracted text") {
                    Text(textOutput).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Copy text", systemImage: "doc.on.doc") { NomadClipboard.copy(textOutput) }
                        Button("Export text", systemImage: "square.and.arrow.up") { exportingText = true }
                        Button("Export text as HTML") {
                            perform { htmlOutput = try PDFWorkshopEngine.textHTML(textOutput); exportingHTML = true }
                        }
                    }.buttonStyle(.borderless)
                }
            }
            Section("Current coverage") {
                Text("Merge, extract/reorder, split, rotate, searchable-PDF OCR, OCR to text, permanent raster redaction, visible ink/signatures/highlights/text, watermarks, page numbering, form/annotation flattening, PDF↔images, text→PDF, extracted text→HTML, image optimization and password protection. Office conversion, certificate signing/validation, PDF/A certification and automatic sensitive-data detection are not available.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("PDFKit exports can alter interactive forms, annotations, and signature validity. Verify exported documents before relying on them. OCR accuracy and supported languages depend on Apple's on-device recognizer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("PDF workshop")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            do { try importFiles(result.get()) }
            catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: selectedOutput?.export, contentType: .pdf, defaultFilename: selectedOutput?.name ?? "document.pdf") { result in
            handleExport(result.map { _ in () })
        }
        .fileExporter(isPresented: $exportingAll, documents: outputs.map(\.export), contentType: .pdf) { result in
            handleExport(result.map { _ in () })
        }
        .fileExporter(isPresented: $exportingText, document: ToolTextDocument(text: textOutput), contentType: .plainText, defaultFilename: "pdf-extracted-text") { result in
            handleExport(result.map { _ in () })
        }
        .fileImporter(isPresented: $importingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                guard !urls.isEmpty, urls.count <= 50 else { throw PDFWorkshopError.message("Select 1–50 images.") }
                runAdvanced("Creating PDF from images") { progress in
                    var images: [Data] = [], total = 0
                    for url in urls {
                        let bytes = try PDFWorkshopEngine.readSelectedFile(url, maximum: 32 * 1_024 * 1_024)
                        total += bytes.count
                        guard total <= PDFWorkshopEngine.maximumBytes else { throw PDFWorkshopError.message("Choose images totaling at most 150 MB.") }
                        images.append(bytes)
                    }
                    return .pdf(try PDFWorkshopEngine.imagesPDF(images, progress: progress), "images.pdf", "Created one PDF page per image in picker order. Images are fitted to letter-size pages; only the first frame of animated/multipage images is used.")
                }
            } catch { self.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingText, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let data = try PDFWorkshopEngine.readSelectedFile(url, maximum: 2 * 1_024 * 1_024)
                guard let text = String(data: data, encoding: .utf8) else { throw PDFWorkshopError.message("Choose a UTF-8 text file.") }
                sourceText = text
            } catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingImages, documents: imageOutputs.map { PDFWorkshopExport(data: $0.data, filename: $0.name) }, contentType: .png) { handleExport($0.map { _ in () }) }
        .fileExporter(isPresented: $exportingHTML, document: PDFWorkshopExport(data: Data(htmlOutput.utf8), filename: "pdf-text.html"), contentType: .html, defaultFilename: "pdf-text.html") { handleExport($0.map { _ in () }) }
        .sheet(item: $markupRequest) { request in
            PDFMarkupEditor(data: request.data, name: request.name, redaction: request.redaction) { data, name in
                perform { try acceptAdvancedPDF(data, name: name) }
            }
        }
        .alert("PDF operation failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { workGeneration = UUID(); ocrTask?.cancel(); ocrTask = nil; ocrBusy = false }
    }

    private var inputSection: some View {
        Section("Inputs · merge order") {
            ForEach(Array(inputs.enumerated()), id: \.element.id) { index, input in
                HStack {
                    Button {
                        selectedInputID = input.id; selectedOutputID = nil; pageSelection = ""; unlockPassword = ""
                    } label: {
                        HStack {
                            Image(systemName: selectedInputID == input.id ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(input.name).lineLimit(2)
                                Text(input.document.isLocked ? "Locked PDF" : "\(input.document.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: Int64(input.byteCount), countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { inputs.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).accessibilityLabel("Move \(input.name) up")
                    Button(role: .destructive) {
                        inputs.removeAll { $0.id == input.id }
                        if selectedInputID == input.id { selectedInputID = inputs.first?.id; pageSelection = "" }
                    } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Remove \(input.name) from workbench")
                }.buttonStyle(.borderless)
            }
            Button("Merge all inputs in this order", systemImage: "doc.on.doc") { perform { try merge() } }
                .disabled(inputs.count < 2)
        }.disabled(ocrBusy)
    }

    private func operationSection(_ input: PDFToolInput) -> some View {
        Section("Operate on \(input.name)") {
            TextField("Pages: all, or e.g. 1-3,5", text: $pageSelection)
                .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
            Text("Leave the field empty for all pages. Extraction preserves your listed order; use 3,1,2 to reorder pages.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Extract / reorder selected pages", systemImage: "doc.badge.arrow.up") { perform { try extractPages(split: false) } }
            Button("Split selected pages into separate PDFs", systemImage: "square.split.2x2") { perform { try extractPages(split: true) } }
            Button("Rotate selected pages 90° clockwise", systemImage: "rotate.right") { perform { try rotate() } }
            Button("Extract embedded text", systemImage: "text.alignleft") { perform { try extractText() } }
            Button("Recognize text in selected pages (OCR)", systemImage: "text.viewfinder") { startOCR() }
            TextField("Optional OCR language tags, e.g. en-US,fr-FR", text: $ocrLanguageTags).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Create searchable PDF with OCR", systemImage: "doc.text.magnifyingglass") {
                perform {
                    guard input.document.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
                    let data = try snapshot(copying: true), pages = try selection(input.document), languages = recognitionLanguages
                    runAdvanced("Creating searchable PDF") { progress in
                        let result = try PDFWorkshopEngine.searchablePDF(data, pages: pages, languages: languages, progress: progress)
                        return .pdf(result.data, "searchable.pdf", "Added \(result.lines) invisible text lines. Skipped \(result.skippedPages) selected pages that already had text. Review recognition and selection alignment before relying on it.")
                    }
                }
            }
            Text("Searchable OCR keeps every visible page and adds selectable text to selected scans. Existing text pages are skipped. Auto language detection is used when tags are empty. Skew, vertical text, right-to-left scripts and some non-Latin reading orders need manual review; OCR is not a certified transcription.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Select permanent redactions", systemImage: "rectangle.fill") { openMarkup(redaction: true) }
            Button("Add visible signature / annotations", systemImage: "signature") { openMarkup(redaction: false) }
            Button("Export selected pages as PNG images", systemImage: "photo.stack") {
                perform {
                    let data = try snapshot(copying: true), pages = try selection(input.document)
                    runAdvanced("Rendering page images") { .images(try PDFWorkshopEngine.pageImages(data, pages: pages, progress: $0)) }
                }
            }
            DisclosureGroup("Watermark, page numbers and flattening") {
                TextField("Visible watermark text", text: $watermarkText)
                Button("Watermark selected pages") {
                    perform {
                        guard input.document.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
                        let data = try snapshot(copying: false), pages = try selection(input.document), text = watermarkText
                        runAdvanced("Adding watermark") { .pdf(try PDFWorkshopEngine.decoratedPDF(data, pages: pages, watermark: text, progress: $0), "watermarked.pdf", "Created a copy with a visible watermark on selected pages. It is not a security or redaction feature.") }
                    }
                }.disabled(watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                TextField("First page number", text: $firstPageNumber).keyboardType(.numberPad)
                Button("Number selected pages") {
                    perform {
                        guard input.document.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
                        guard let first = Int(firstPageNumber) else { throw PDFWorkshopError.message("Enter a whole-number starting page number.") }
                        let data = try snapshot(copying: false), pages = try selection(input.document)
                        runAdvanced("Adding page numbers") { .pdf(try PDFWorkshopEngine.decoratedPDF(data, pages: pages, firstPageNumber: first, progress: $0), "numbered.pdf", "Added bottom-center numbers in your selected page order. Check that they do not overlap existing page content.") }
                    }
                }
                Button("Flatten visible forms and annotations") {
                    perform {
                        guard input.document.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
                        let data = try snapshot(copying: false)
                        runAdvanced("Flattening visible pages") { .pdf(try PDFWorkshopEngine.flattenedPDF(data, progress: $0), "flattened.pdf", "Created non-interactive visible pages. Existing digital signatures are not preserved. Flattening is not redaction; use Permanent redaction to remove sensitive content.") }
                    }
                }
            }
            Button("Optimize images in whole document", systemImage: "arrow.down.right.and.arrow.up.left") { perform { try optimize() } }
            Text("Image optimization can reduce image quality and is not guaranteed to produce a smaller file.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Password for a protected output copy", text: $outputPassword)
            Button("Create password-protected copy", systemImage: "lock.doc") { perform { try protect() } }
                .disabled(outputPassword.isEmpty)
        }.disabled(ocrBusy)
    }

    private var outputSection: some View {
        Section("Generated output · export to keep") {
            Picker("Preview", selection: $selectedOutputID) {
                Text("Input document").tag(UUID?.none)
                ForEach(outputs) { Text($0.name).tag(Optional($0.id)) }
            }
            if let output = selectedOutput {
                Text("\(output.document.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: Int64(output.data.count), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export selected PDF", systemImage: "square.and.arrow.up") { exporting = true }
                Button("Use this output as a new input", systemImage: "arrow.turn.up.left") {
                    perform {
                        guard totalBytes + output.data.count <= 300 * 1_024 * 1_024 else { throw PDFWorkshopError.message("Remove an input before adding another workbench copy.") }
                        guard let document = PDFDocument(data: output.data) else { throw PDFWorkshopError.message("Could not reopen output.") }
                        let input = PDFToolInput(name: output.name, document: document, byteCount: output.data.count)
                        inputs.append(input); selectedInputID = input.id; selectedOutputID = nil; pageSelection = ""
                    }
                }
            }
            if outputs.count > 1 {
                Button("Export all \(outputs.count) PDFs", systemImage: "square.and.arrow.up.on.square") { exportingAll = true }
            }
            Text("Running another PDF operation replaces these temporary outputs.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(ocrBusy)
    }

    private func importFiles(_ urls: [URL]) throws {
        var additions: [PDFToolInput] = []
        var size = totalBytes
        guard urls.count <= 50, inputs.count + urls.count <= 50 else { throw PDFWorkshopError.message("Keep at most 50 input PDFs in the workbench.") }
        for url in urls {
            let data = try PDFWorkshopEngine.readSelectedFile(url)
            guard data.count <= 150 * 1_024 * 1_024, size + data.count <= 300 * 1_024 * 1_024,
                  let document = PDFDocument(data: data) else {
                throw ToolFailure.message("\(url.lastPathComponent) is not a supported PDF or exceeds the workbench size limit.")
            }
            guard document.isLocked || (document.pageCount > 0 && document.pageCount <= 500) else { throw PDFWorkshopError.message("Use PDFs with 1–500 pages each.") }
            additions.append(PDFToolInput(name: url.lastPathComponent, document: document, byteCount: data.count))
            size += data.count
        }
        inputs.append(contentsOf: additions)
        if selectedInputID == nil { selectedInputID = inputs.first?.id }
        selectedOutputID = nil
        notice = "Imported \(additions.count) PDF(s). Select an input to operate on it."
    }

    private func requireInput(copying: Bool = false) throws -> PDFToolInput {
        guard let input = selectedInput else { throw ToolFailure.message("Import and select a PDF first.") }
        guard !input.document.isLocked else { throw ToolFailure.message("Unlock the selected PDF first.") }
        guard input.document.pageCount > 0, input.document.pageCount <= 500 else { throw PDFWorkshopError.message("Use PDFs with 1–500 pages.") }
        if copying && !input.document.allowsCopying { throw ToolFailure.message("This PDF does not permit content extraction.") }
        return input
    }

    private func requireAssembly(_ document: PDFDocument) throws {
        guard !document.isLocked else { throw ToolFailure.message("Unlock all PDFs before merging.") }
        guard document.allowsDocumentAssembly else { throw ToolFailure.message("This PDF's permissions do not allow page changes.") }
    }

    private func selection(_ document: PDFDocument) throws -> [Int] {
        try PDFPageSelection.parse(pageSelection, pageCount: document.pageCount)
    }

    private func copyPages(_ indices: [Int], from source: PDFDocument) throws -> PDFDocument {
        let result = PDFDocument()
        for index in indices {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { throw ToolFailure.message("Could not copy page \(index + 1).") }
            result.insert(page, at: result.pageCount)
        }
        return result
    }

    private func output(_ document: PDFDocument, name: String, options: [AnyHashable: Any]? = nil) throws -> PDFToolOutput {
        let data: Data?
        if let options { data = document.dataRepresentation(options: options) }
        else { data = document.dataRepresentation() }
        guard let data, data.count <= PDFWorkshopEngine.maximumBytes, let preview = PDFDocument(data: data) else { throw ToolFailure.message("PDFKit could not create an output within the 150 MB limit.") }
        if let password = options?[PDFDocumentWriteOption.userPasswordOption] as? String {
            guard preview.isEncrypted, preview.unlock(withPassword: password) else {
                throw ToolFailure.message("PDFKit could not verify encryption of the output. No output was saved.")
            }
        }
        return PDFToolOutput(name: name, document: preview, data: data)
    }

    private func setOutputs(_ results: [PDFToolOutput]) {
        outputs = results; selectedOutputID = results.first?.id
        notice = "Created \(results.count) output PDF(s). Export to save them."
    }

    private func merge() throws {
        guard inputs.reduce(0, { $0 + $1.document.pageCount }) <= 500 else { throw PDFWorkshopError.message("Merge at most 500 pages per batch.") }
        let result = PDFDocument()
        for input in inputs {
            try requireAssembly(input.document)
            for index in 0..<input.document.pageCount {
                guard let page = input.document.page(at: index)?.copy() as? PDFPage else { throw ToolFailure.message("Could not copy a page from \(input.name).") }
                result.insert(page, at: result.pageCount)
            }
        }
        guard result.pageCount > 0 else { throw ToolFailure.message("There are no pages to merge.") }
        setOutputs([try output(result, name: "merged.pdf")])
    }

    private func extractPages(split: Bool) throws {
        let input = try requireInput()
        try requireAssembly(input.document)
        let indices = try selection(input.document)
        let base = (input.name as NSString).deletingPathExtension
        if split {
            guard indices.count <= 200 else { throw ToolFailure.message("Split at most 200 pages at a time, using the page selection field.") }
            var results: [PDFToolOutput] = [], bytes = 0
            for index in indices {
                let result = try output(copyPages([index], from: input.document), name: "\(base)-page-\(index + 1).pdf")
                bytes += result.data.count
                guard bytes <= PDFWorkshopEngine.maximumBytes else { throw PDFWorkshopError.message("The split output batch exceeds 150 MB. Select fewer pages.") }
                results.append(result)
            }
            setOutputs(results)
        } else {
            setOutputs([try output(copyPages(indices, from: input.document), name: "\(base)-selected-pages.pdf")])
        }
    }

    private func rotate() throws {
        let input = try requireInput()
        try requireAssembly(input.document)
        let indices = try selection(input.document)
        let result = try copyPages(Array(0..<input.document.pageCount), from: input.document)
        for index in indices {
            guard let page = result.page(at: index) else { throw ToolFailure.message("Could not rotate page \(index + 1).") }
            page.rotation = (page.rotation + 90) % 360
        }
        setOutputs([try output(result, name: "rotated.pdf")])
    }

    private func extractText() throws {
        let input = try requireInput(copying: true)
        let pages = try selection(input.document)
        var chunks: [String] = []
        var hasText = false
        var bytes = 0
        for index in pages {
            let text = input.document.page(at: index)?.string ?? ""
            bytes += text.utf8.count
            guard bytes <= 8 * 1_024 * 1_024 else { throw PDFWorkshopError.message("Extracted text exceeds 8 MB. Select fewer pages.") }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
            chunks.append("— Page \(index + 1) —\n\(text)")
        }
        guard hasText else { textOutput = ""; throw ToolFailure.message("No embedded text was found. Try OCR for scanned pages.") }
        textOutput = chunks.joined(separator: "\n\n")
        notice = "Extracted embedded text from \(pages.count) pages."
    }

    private func optimize() throws {
        let input = try requireInput()
        guard input.document.allowsDocumentChanges else { throw ToolFailure.message("This PDF does not permit document changes.") }
        let result = try copyPages(Array(0..<input.document.pageCount), from: input.document)
        setOutputs([try output(result, name: "optimized.pdf", options: [
            PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
            PDFDocumentWriteOption.optimizeImagesForScreenOption: true
        ])])
    }

    private func protect() throws {
        let input = try requireInput()
        try requireAssembly(input.document)
        guard !outputPassword.isEmpty else { throw ToolFailure.message("Enter an output password first.") }
        let result = try copyPages(Array(0..<input.document.pageCount), from: input.document)
        setOutputs([try output(result, name: "protected.pdf", options: [
            PDFDocumentWriteOption.ownerPasswordOption: outputPassword,
            PDFDocumentWriteOption.userPasswordOption: outputPassword
        ])])
        outputPassword = ""
        notice = "Created a password-protected output. Keep its password safe; the app does not save it. Export to keep the PDF."
    }

    private var recognitionLanguages: [String] {
        ocrLanguageTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func snapshot(copying: Bool) throws -> Data {
        let input = try requireInput(copying: copying)
        guard input.document.pageCount <= PDFWorkshopEngine.maximumPages else { throw PDFWorkshopError.message("Process at most 500 pages per document.") }
        // A private document snapshot avoids concurrently using the displayed PDFKit object.
        let copy = try copyPages(Array(0..<input.document.pageCount), from: input.document)
        guard let data = copy.dataRepresentation(), data.count <= PDFWorkshopEngine.maximumBytes else { throw PDFWorkshopError.message("The working copy exceeds 150 MB.") }
        return data
    }

    private func openMarkup(redaction: Bool) {
        perform {
            let input = try requireInput(copying: redaction)
            guard input.document.allowsDocumentChanges else { throw PDFWorkshopError.message("This PDF does not permit document changes.") }
            if redaction && input.document.pageCount > PDFWorkshopEngine.maximumRasterPages { throw PDFWorkshopError.message("Extract a batch of at most 100 pages before permanent redaction.") }
            markupRequest = PDFMarkupRequest(data: try snapshot(copying: redaction), name: input.name, redaction: redaction)
        }
    }

    private func acceptAdvancedPDF(_ data: Data, name: String) throws {
        let document = try PDFWorkshopEngine.document(data)
        setOutputs([PDFToolOutput(name: name, document: document, data: data)])
    }

    private func runAdvanced(_ title: String, operation: @escaping (@escaping (Double) -> Void) throws -> PDFAdvancedResult) {
        guard !ocrBusy else { return }
        ocrBusy = true; ocrProgress = 0; workTitle = title; notice = ""; error = nil
        let token = UUID(); workGeneration = token
        ocrTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                try operation { value in Task { @MainActor in if workGeneration == token { ocrProgress = value } } }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard workGeneration == token else { return }
                switch result {
                case .pdf(let data, let name, let message): try acceptAdvancedPDF(data, name: name); notice = message
                case .images(let images): imageOutputs = images; notice = "Rendered page images. Export them to keep the files."
                case .text(let text, let message): textOutput = text; notice = message
                }
            } catch is CancellationError {
                if workGeneration == token { notice = "Operation cancelled. No partial output was accepted." }
            } catch { if workGeneration == token { self.error = error.localizedDescription } }
            if workGeneration == token { ocrBusy = false; ocrTask = nil }
        }
    }

    private func startOCR() {
        perform {
            let input = try requireInput(copying: true)
            let pages = try selection(input.document), data = try snapshot(copying: true), languages = recognitionLanguages
            guard pages.count <= PDFWorkshopEngine.maximumRasterPages else { throw PDFWorkshopError.message("Recognize at most 100 selected pages per batch.") }
            runAdvanced("Recognizing page text") { progress in
                let document = try PDFWorkshopEngine.document(data)
                var chunks: [String] = [], bytes = 0
                for (offset, index) in pages.enumerated() {
                    try Task.checkCancellation()
                    let text: String = try autoreleasepool {
                        guard let page = document.page(at: index) else { throw PDFWorkshopError.message("A source page is missing.") }
                        return try PDFWorkshopEngine.recognize(PDFWorkshopEngine.render(page), languages: languages).map(\.text).joined(separator: "\n")
                    }
                    bytes += text.utf8.count
                    guard bytes <= 8 * 1_024 * 1_024 else { throw PDFWorkshopError.message("Recognized text exceeds 8 MB. Select fewer pages.") }
                    chunks.append("— Page \(index + 1) —\n\(text)")
                    progress(Double(offset + 1) / Double(pages.count))
                }
                return .text(chunks.joined(separator: "\n\n"), "OCR finished locally. Review the recognized text, then export it.")
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    private func handleExport(_ result: Result<Void, Error>) {
        switch result {
        case .success: notice = "Export complete."
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}
