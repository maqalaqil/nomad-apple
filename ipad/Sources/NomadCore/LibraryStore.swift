import Foundation
import Observation
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var documents: [LibraryDocument] = []
    public private(set) var lastError: String?
    public let storageURL: URL
    @ObservationIgnored private var records: [LibraryRecord] = []
    @ObservationIgnored private var loadFailure: Error?

    private struct Manifest: Codable {
        let formatVersion: Int
        let records: [LibraryRecord]
    }

    private var manifestURL: URL { storageURL.appendingPathComponent("library.json") }
    private var filesURL: URL { storageURL.appendingPathComponent("Files", isDirectory: true) }

    public init(rootURL: URL? = nil) {
        storageURL = (rootURL ?? LocalStorage.defaultRoot(component: "Library")).standardizedFileURL
        do {
            try LocalStorage.prepare(storageURL)
            try LocalStorage.prepare(filesURL)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = try LocalStorage.read(Manifest.self, from: manifestURL)
                guard manifest.formatVersion == 1 else {
                    throw LocalStorageError.invalidManifest("Unknown format version.")
                }
                let identifiers = manifest.records.map(\.document.id)
                let filenames = manifest.records.map(\.document.filename)
                guard Set(identifiers).count == identifiers.count, Set(filenames).count == filenames.count,
                    manifest.records.allSatisfy({
                        LocalStorage.isSafeBasename($0.document.filename) &&
                        $0.document.filename.hasPrefix($0.document.id.uuidString) &&
                        $0.document.byteCount >= 0
                    }) else {
                    throw LocalStorageError.invalidManifest("Invalid or duplicate file references.")
                }
                records = manifest.records
                try recoverInterruptedDeletions()
                documents = records.map(\.document).sorted { $0.importedAt > $1.importedAt }
            }
        } catch {
            loadFailure = error
            lastError = error.localizedDescription
        }
    }

    /// Only documents in the validated manifest can resolve to stored files.
    public func fileURL(for document: LibraryDocument) -> URL {
        guard LocalStorage.isSafeBasename(document.filename),
              records.contains(where: { $0.document.id == document.id && $0.document.filename == document.filename }) else {
            // A non-existent child keeps even a fabricated document inside the app's storage.
            return filesURL.appendingPathComponent("invalid-document")
        }
        return filesURL.appendingPathComponent(document.filename)
    }

    public func search(_ query: String, documentIDs: Set<UUID>? = nil) -> [SearchHit] {
        let eligible = documentIDs.map { ids in records.filter { ids.contains($0.document.id) } } ?? records
        return DocumentSearch.search(query, records: eligible)
    }

    /// Bounded, stable source passages for an optional local semantic index. No filename-only placeholders.
    public func retrievalPassages(documentIDs: Set<UUID>? = nil, limit: Int = 10_000) -> [SearchHit] {
        let maximum = min(max(0, limit), 10_000)
        guard maximum > 0 else { return [] }
        var result: [SearchHit] = []
        for record in records where documentIDs == nil || documentIDs!.contains(record.document.id) {
            for (index, passage) in DocumentSearch.passages(from: record.searchableText).enumerated() {
                result.append(SearchHit(id: "\(record.document.id)-\(index)", documentID: record.document.id,
                    documentTitle: record.document.title, excerpt: passage, score: 0, hasSourceText: true))
                if result.count == maximum { return result }
            }
        }
        return result
    }

    /// Changes the display title only. The stored filename and shared content inode stay unchanged.
    public func rename(_ document: LibraryDocument, title: String) throws {
        try requireHealthyStore()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 512, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalStorageError.unavailable("Use a display title of 1–512 characters without control characters.")
        }
        guard let index = records.firstIndex(where: { $0.document.id == document.id && $0.document.filename == document.filename }) else { throw LocalStorageError.missingDocument }
        let old = records[index]
        guard old.document.title == document.title else { throw LocalStorageError.unavailable("This title changed after it was opened. Reopen the file details before renaming it.") }
        let updatedDocument = LibraryDocument(id: old.document.id, title: title, filename: old.document.filename, kind: old.document.kind,
            byteCount: old.document.byteCount, importedAt: old.document.importedAt, indexingStatus: old.document.indexingStatus)
        var updated = records
        updated[index] = LibraryRecord(document: updatedDocument, searchableText: old.searchableText)
        do {
            try LocalStorage.write(Manifest(formatVersion: 1, records: updated), to: manifestURL)
            records = updated; documents = updated.map(\.document).sorted { $0.importedAt > $1.importedAt }; lastError = nil
        } catch { lastError = error.localizedDescription; throw error }
    }

    /// Rechecks a registered local file and rebuilds bounded PDF/text extraction.
    /// Archives retain their native indexes; no content file is rewritten or recopied.
    public func refreshIndex(_ document: LibraryDocument) async throws {
        try requireHealthyStore()
        guard let original = records.first(where: { $0.document.id == document.id && $0.document.filename == document.filename }) else { throw LocalStorageError.missingDocument }
        let source = fileURL(for: original.document)
        let operation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let before = try Self.fileState(source)
            let extraction = Self.extractText(from: source, kind: original.document.kind)
            try Task.checkCancellation()
            guard extraction.succeeded else { throw LocalStorageError.unavailable("Re-indexing did not produce a valid replacement. The previous metadata and search text were preserved. \(extraction.status)") }
            guard before == (try Self.fileState(source)) else { throw LocalStorageError.unavailable("This file changed during re-indexing. The previous index was preserved; try again.") }
            return (before, extraction.text, extraction.status)
        }
        do {
            let (state, text, status) = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            try requireHealthyStore()
            guard let index = records.firstIndex(where: { $0.document.id == document.id && $0.document.filename == document.filename }) else { throw LocalStorageError.missingDocument }
            guard state == (try Self.fileState(source)) else { throw LocalStorageError.unavailable("This file changed before the new index could be saved. The previous index was preserved.") }
            let current = records[index].document
            let updatedDocument = LibraryDocument(id: current.id, title: current.title, filename: current.filename, kind: current.kind,
                byteCount: state.size, importedAt: current.importedAt, indexingStatus: status)
            var updated = records
            updated[index] = LibraryRecord(document: updatedDocument, searchableText: text)
            try LocalStorage.write(Manifest(formatVersion: 1, records: updated), to: manifestURL)
            records = updated; documents = updated.map(\.document).sorted { $0.importedAt > $1.importedAt }; lastError = nil
        } catch { if !(error is CancellationError) { lastError = error.localizedDescription }; throw error }
    }

    private struct FileState: Equatable, Sendable {
        let size: Int64
        let modified: Date
        let inode: UInt64
        let device: UInt64
    }
    nonisolated private static func fileState(_ url: URL) throws -> FileState {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, size.int64Value >= 0,
              let modified = values[.modificationDate] as? Date,
              let inode = values[.systemFileNumber] as? NSNumber, let device = values[.systemNumber] as? NSNumber else {
            throw LocalStorageError.invalidFile
        }
        return FileState(size: size.int64Value, modified: modified, inode: inode.uint64Value, device: device.uint64Value)
    }

    public func importFile(_ url: URL) async throws {
        try requireHealthyStore()
        #if os(iOS) || os(macOS)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #endif
        let id = UUID()
        let filename = LocalStorage.internalFilename(id: id, source: url)
        let destination = filesURL.appendingPathComponent(filename)
        let kind = DocumentKind.detect(filename: url.lastPathComponent)
        let record: LibraryRecord
        do {
            record = try await Task.detached(priority: .userInitiated) {
                try Self.copyAndIndex(source: url, destination: destination, id: id, kind: kind)
            }.value
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        do {
            let updated = records + [record]
            try LocalStorage.write(Manifest(formatVersion: 1, records: updated), to: manifestURL)
            records = updated
            documents = updated.map(\.document).sorted { $0.importedAt > $1.importedAt }
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Only for a current, verified, immutable DownloadStore ready-file snapshot. External
    /// Files imports must continue through importFile so edits cannot change a stored library.
    public func importDownloadedFile(_ source: URL, sourceRoot: URL, expectedBytes: UInt64, name: String? = nil) async throws {
        try requireHealthyStore()
        guard expectedBytes <= UInt64(Int64.max) else { throw LocalStorageError.invalidFile }
        let id = UUID()
        let destination = filesURL.appendingPathComponent(LocalStorage.internalFilename(id: id, source: source))
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = title.flatMap { $0.isEmpty ? nil : String($0.prefix(1_024)) } ?? source.lastPathComponent
        let kind = DocumentKind.detect(filename: source.lastPathComponent)
        let operation = Task.detached(priority: .userInitiated) {
            try Self.linkAndIndex(source: source, sourceRoot: sourceRoot, destination: destination,
                                  id: id, kind: kind, expectedBytes: expectedBytes, displayName: displayName)
        }
        do {
            let record = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            try requireHealthyStore()
            let updated = records + [record]
            try LocalStorage.write(Manifest(formatVersion: 1, records: updated), to: manifestURL)
            records = updated
            documents = updated.map(\.document).sorted { $0.importedAt > $1.importedAt }
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = error.localizedDescription
            throw error
        }
    }

    public func delete(_ document: LibraryDocument) throws {
        try requireHealthyStore()
        guard let record = records.first(where: { $0.document.id == document.id }) else {
            throw LocalStorageError.missingDocument
        }
        let source = fileURL(for: record.document)
        let pendingDelete = filesURL.appendingPathComponent(".delete-\(document.id.uuidString)")
        let hasFile = FileManager.default.fileExists(atPath: source.path)
        do {
            if hasFile { try FileManager.default.moveItem(at: source, to: pendingDelete) }
            let updated = records.filter { $0.document.id != document.id }
            do {
                try LocalStorage.write(Manifest(formatVersion: 1, records: updated), to: manifestURL)
            } catch let writeError {
                if hasFile {
                    do { try FileManager.default.moveItem(at: pendingDelete, to: source) }
                    catch {
                        throw LocalStorageError.unavailable("The delete could not be committed or rolled back. The original file is preserved in the library's pending-delete area and will be recovered on the next launch. \(writeError.localizedDescription)")
                    }
                }
                throw writeError
            }
            records = updated
            documents = updated.map(\.document).sorted { $0.importedAt > $1.importedAt }
            if hasFile { try? FileManager.default.removeItem(at: pendingDelete) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func requireHealthyStore() throws {
        if let loadFailure { throw LocalStorageError.unavailable(loadFailure.localizedDescription) }
    }

    /// An app termination between moving a file and committing metadata must not lose its local copy.
    private func recoverInterruptedDeletions() throws {
        let manager = FileManager.default
        for record in records {
            let source = filesURL.appendingPathComponent(record.document.filename)
            let pending = filesURL.appendingPathComponent(".delete-\(record.document.id.uuidString)")
            if !manager.fileExists(atPath: source.path), manager.fileExists(atPath: pending.path) {
                try manager.moveItem(at: pending, to: source)
            }
        }
        let activeIDs = Set(records.map { $0.document.id.uuidString })
        for name in try manager.contentsOfDirectory(atPath: filesURL.path) where name.hasPrefix(".delete-") {
            let identifier = String(name.dropFirst(".delete-".count))
            if UUID(uuidString: identifier) != nil, !activeIDs.contains(identifier) {
                // Metadata already committed the removal before the previous process stopped.
                try? manager.removeItem(at: filesURL.appendingPathComponent(name))
            }
        }
    }

    nonisolated private static func linkAndIndex(source: URL, sourceRoot: URL, destination: URL, id: UUID,
                                               kind: DocumentKind, expectedBytes: UInt64, displayName: String) throws -> LibraryRecord {
        try Task.checkCancellation()
        try requireImportCapacity(at: destination.deletingLastPathComponent(), additionalBytes: 0)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-\(id.uuidString)")
        var ownsStaging = false
        var ownsDestination = false
        do {
            if try InternalDownloadLink.stage(source: source, sourceRoot: sourceRoot, destination: staging, expectedBytes: expectedBytes) {
                ownsStaging = true
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: staging, to: destination)
                ownsStaging = false
                ownsDestination = true
                let extracted = extractText(from: destination, kind: kind)
                try Task.checkCancellation()
                let document = LibraryDocument(id: id, title: displayName, filename: destination.lastPathComponent,
                    kind: kind, byteCount: Int64(expectedBytes), importedAt: Date(), indexingStatus: extracted.status)
                return LibraryRecord(document: document, searchableText: extracted.text)
            }
            // Cross-volume or unsupported filesystems need the full additional copy, even
            // though the normal same-container path shares storage without duplicating bytes.
            try requireImportCapacity(at: destination.deletingLastPathComponent(), additionalBytes: expectedBytes)
            try Task.checkCancellation()
            return try copyAndIndex(source: source, destination: destination, id: id, kind: kind,
                                    displayName: displayName, expectedBytes: Int64(expectedBytes))
        } catch {
            if ownsStaging { try? FileManager.default.removeItem(at: staging) }
            if ownsDestination { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    nonisolated private static func requireImportCapacity(at folder: URL, additionalBytes: UInt64) throws {
        let reserve: UInt64 = 512 * 1_024 * 1_024
        let (needed, overflow) = additionalBytes.addingReportingOverflow(reserve)
        guard !overflow else { throw LocalStorageError.unavailable("The import size exceeds the supported range.") }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        guard let available = attributes[.systemFreeSize] as? NSNumber, available.int64Value >= 0 else {
            throw LocalStorageError.unavailable("Available storage could not be checked before importing.")
        }
        guard available.uint64Value >= needed else {
            throw LocalStorageError.unavailable("This import requires \(needed) free bytes including a 512 MiB reserve. The completed download has been preserved.")
        }
    }

    nonisolated private static func copyAndIndex(source: URL, destination: URL, id: UUID, kind: DocumentKind,
                                               displayName: String? = nil, expectedBytes: Int64? = nil) throws -> LibraryRecord {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LocalStorageError.invalidFile }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-\(id.uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            let extracted = extractText(from: destination, kind: kind)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(values.fileSize ?? 0)
            if let expectedBytes, size != expectedBytes { throw LocalStorageError.unavailable("The copied download changed size. Nothing was imported.") }
            let document = LibraryDocument(id: id, title: displayName ?? source.lastPathComponent, filename: destination.lastPathComponent,
                kind: kind, byteCount: size, importedAt: Date(), indexingStatus: extracted.status)
            return LibraryRecord(document: document, searchableText: extracted.text)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    nonisolated private static func extractText(from url: URL, kind: DocumentKind) -> (text: String, status: String, succeeded: Bool) {
        let characterLimit = 400_000
        if kind == .text || kind == .markdown {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 2 * 1_024 * 1_024) ?? Data()
                // A truncated UTF-8 sequence is replaced locally instead of dropping the entire index.
                let decoded = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let text = String(decoded.prefix(characterLimit))
                let limited = decoded.count > characterLimit || data.count == 2 * 1_024 * 1_024
                return (text, limited ? "Text indexed up to the 400,000-character / 2 MB limit." : "Text indexed for offline search.", true)
            } catch {
                return ("", "File saved; text could not be indexed: \(error.localizedDescription)", false)
            }
        }
        #if canImport(PDFKit)
        if kind == .pdf {
            guard let pdf = PDFDocument(url: url) else { return ("", "File saved; PDF could not be opened.", false) }
            guard !pdf.isLocked else { return ("", "File saved; unlock this PDF before text can be indexed.", false) }
            var text = ""
            for page in 0..<min(pdf.pageCount, 200) {
                if Task.isCancelled { return ("", "PDF indexing stopped.", false) }
                if let pageText = pdf.page(at: page)?.string { text += "\n\n" + pageText }
                if text.count >= characterLimit { break }
            }
            let limited = pdf.pageCount > 200 || text.count > characterLimit
            text = String(text.prefix(characterLimit))
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("", "File saved; no text layer found. Automatic PDF OCR is not included in this index; use Text Recognition for supported images.", false)
            }
            return (text, limited ? "PDF text indexed up to 200 pages / 400,000 characters." : "PDF text indexed for offline search.", true)
        }
        #endif
        switch kind {
        case .zim: return ("", "Archive saved. Open it to read articles and search its native index.", true)
        case .epub: return ("", "Book saved. Open it to read local EPUB chapters. Library search matches its title.", true)
        case .model: return ("", "Model file saved in the library. Use GGUF models to import and load it for local inference.", true)
        case .pdf: return ("", "PDF text extraction is unavailable on this platform.", false)
        default: return ("", "File saved. Search matches its filename only.", true)
        }
    }
}
