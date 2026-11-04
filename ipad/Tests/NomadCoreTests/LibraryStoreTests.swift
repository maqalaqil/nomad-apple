import XCTest
import Darwin
@testable import NomadCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDisplayRenamePreservesFileIdentityAndRejectsStaleEditor() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("navigation.txt")
        try "A compass points toward magnetic north.".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        let original = try XCTUnwrap(store.documents.first), file = store.fileURL(for: store.documents[0])
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let originalData = try Data(contentsOf: file)
        try store.rename(original, title: "دليل الملاحة · Navigation guide")
        let renamed = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(renamed.filename, original.filename)
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(store.search("compass").first?.documentTitle, renamed.title)
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertThrowsError(try store.rename(original, title: "Stale overwrite"))
        XCTAssertThrowsError(try store.rename(renamed, title: "\n\t"))
        XCTAssertEqual(LibraryStore(rootURL: store.storageURL).documents.first?.title, renamed.title)
    }

    func testRefreshReplacesTextAndSizeButPreservesRenamedTitle() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("field-guide.txt")
        try "A compass points north.".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        let original = try XCTUnwrap(store.documents.first), file = store.fileURL(for: store.documents[0])
        let replacement = "A sextant measures the angle between a star and the horizon."
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        try store.rename(original, title: "Updated display title")
        try await store.refreshIndex(original)
        XCTAssertTrue(store.search("compass").isEmpty)
        XCTAssertEqual(store.search("sextant").first?.documentTitle, "Updated display title")
        XCTAssertEqual(store.documents.first?.byteCount, Int64(replacement.utf8.count))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), replacement)
        XCTAssertEqual(LibraryStore(rootURL: store.storageURL).search("sextant").count, 1)
    }

    func testRefreshFailurePreservesPriorRecordAndIndex() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.txt")
        try "A compass points north.".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        let original = try XCTUnwrap(store.documents.first), file = store.fileURL(for: store.documents[0])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        do { try await store.refreshIndex(original); XCTFail("Accepted a symbolic-link file") } catch {}
        XCTAssertEqual(store.documents, [original]); XCTAssertEqual(store.search("compass").count, 1)
        try FileManager.default.removeItem(at: file)
        try "A sextant measures altitude.".write(to: file, atomically: true, encoding: .utf8)
        let manifest = store.storageURL.appendingPathComponent("library.json")
        let saved = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try await store.refreshIndex(original); XCTFail("Committed failed metadata write") } catch {}
        XCTAssertEqual(store.documents, [original]); XCTAssertEqual(store.search("compass").count, 1)
        XCTAssertTrue(store.search("sextant").isEmpty)
        XCTAssertThrowsError(try store.rename(original, title: "Uncommitted title"))
        XCTAssertEqual(store.documents, [original])
        try FileManager.default.removeItem(at: manifest); try saved.write(to: manifest)
        try FileManager.default.removeItem(at: file)
        do { try await store.refreshIndex(original); XCTFail("Accepted a missing file") } catch {}
        XCTAssertEqual(LibraryStore(rootURL: store.storageURL).search("compass").count, 1)
    }

    #if canImport(PDFKit)
    func testFailedPDFExtractionCannotEraseGoodPriorIndex() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.pdf")
        let stream = "BT /F1 12 Tf 30 200 Td (Compasses point north) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        var pdf = "%PDF-1.4\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let xref = pdf.utf8.count
        pdf += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        let original = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(store.search("Compasses").count, 1)
        try Data("broken PDF bytes".utf8).write(to: store.fileURL(for: original))
        do { try await store.refreshIndex(original); XCTFail("Erased index after PDF extraction failed") } catch {}
        XCTAssertEqual(store.documents, [original]); XCTAssertEqual(store.search("Compasses").count, 1)
    }
    #endif

    func testImportsAreIndependentLocalCopiesAndSurviveReload() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("field-guide.md")
        let text = "A compass needle points toward magnetic north. Keep it away from metal."
        try text.write(to: source, atomically: true, encoding: .utf8)
        let storage = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: storage)
        try await store.importFile(source)
        let imported = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(imported.kind, .markdown)
        XCTAssertEqual(imported.byteCount, Int64(text.utf8.count))
        XCTAssertNotEqual(store.fileURL(for: imported), source)
        try FileManager.default.removeItem(at: source)

        let reopened = LibraryStore(rootURL: storage)
        XCTAssertNil(reopened.lastError)
        XCTAssertEqual(reopened.documents, [imported])
        XCTAssertEqual(try String(contentsOf: reopened.fileURL(for: imported), encoding: .utf8), text)
        let hit = try XCTUnwrap(reopened.search("magnetic north").first)
        XCTAssertEqual(hit.documentID, imported.id)
        XCTAssertTrue(hit.excerpt.contains("magnetic north"))
    }

    func testSameNamedImportsDoNotOverwriteEarlierFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.txt")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try "First original".write(to: source, atomically: true, encoding: .utf8)
        try await store.importFile(source)
        let first = try XCTUnwrap(store.documents.first)
        try "Second revision".write(to: source, atomically: true, encoding: .utf8)
        try await store.importFile(source)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(Set(store.documents.map(\.filename)).count, 2)
        XCTAssertEqual(try String(contentsOf: store.fileURL(for: first), encoding: .utf8), "First original")
        XCTAssertEqual(store.search("revision").count, 1)
    }

    func testRetrievalRejectsUnrelatedQueriesAndHandlesUnicode() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("travel.txt")
        try "The café beside the harbor sells coffee. Navigation charts show shallow water.".write(to: source, atomically: true, encoding: .utf8)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        XCTAssertFalse(store.search("CAFE").isEmpty)
        XCTAssertFalse(store.search("navigation charts").isEmpty)
        XCTAssertTrue(store.search("semiconductor fabrication").isEmpty)
        XCTAssertTrue(store.search("what is the").isEmpty)
        XCTAssertTrue(store.search("").isEmpty)
        XCTAssertTrue(store.search("   ").isEmpty)
    }

    func testCollectionSearchFiltersBeforeRankingAndGlobalResultLimit() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let selectedSource = root.appendingPathComponent("field-guide.txt")
        try "A compass points toward magnetic north.".write(to: selectedSource, atomically: true, encoding: .utf8)
        try await store.importFile(selectedSource)
        let selected = try XCTUnwrap(store.documents.first)
        // Ten title-matching documents contribute three stronger passages each, filling the global top 30.
        for index in 0..<10 {
            let source = root.appendingPathComponent("compass-\(index).txt")
            try Array(repeating: "compass", count: 250).joined(separator: " ").write(to: source, atomically: true, encoding: .utf8)
            try await store.importFile(source)
        }
        let global = store.search("compass")
        XCTAssertEqual(global.count, 30)
        XCTAssertFalse(global.contains { $0.documentID == selected.id })
        let filtered = store.search("compass", documentIDs: [selected.id])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.documentID, selected.id)
        XCTAssertTrue(store.search("compass", documentIDs: []).isEmpty)
    }

    func testArchivesAreStoredWithoutPretendingTheirArticlesAreInTheDocumentIndex() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("encyclopedia.zim")
        try Data("secret article content".utf8).write(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importFile(source)
        let document = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(document.kind, .zim)
        XCTAssertTrue(document.indexingStatus.contains("native index"))
        XCTAssertTrue(store.search("secret article").isEmpty)
        XCTAssertEqual(store.search("encyclopedia").first?.documentID, document.id)
        XCTAssertEqual(store.search("encyclopedia").first?.hasSourceText, false)
        XCTAssertTrue(store.retrievalPassages().isEmpty)
    }

    func testPassageExportFiltersBeforeLimitAndUsesStableSourceIdentifiers() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let source = root.appendingPathComponent("guide.txt")
        try "Compass magnetic north navigation".write(to: source, atomically: true, encoding: .utf8)
        try await store.importFile(source)
        let selected = try XCTUnwrap(store.documents.first)
        try "Unrelated recently imported topic".write(to: source, atomically: true, encoding: .utf8)
        try await store.importFile(source)
        let passages = store.retrievalPassages(documentIDs: [selected.id], limit: 1)
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages.first?.documentID, selected.id)
        XCTAssertEqual(passages.first?.id, store.search("compass").first?.id)
        XCTAssertTrue(passages.allSatisfy(\.hasSourceText))
        XCTAssertTrue(store.retrievalPassages(documentIDs: [], limit: 100).isEmpty)
        XCTAssertTrue(store.retrievalPassages(limit: 0).isEmpty)
    }

    func testFailedMetadataWriteRollsBackImportAndDeletion() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.txt")
        try "Persistent local knowledge".write(to: source, atomically: true, encoding: .utf8)
        let storage = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: storage)
        try await store.importFile(source)
        let document = try XCTUnwrap(store.documents.first)
        let manifest = storage.appendingPathComponent("library.json")
        let metadata = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        // A directory at the manifest path deterministically causes the atomic write to fail.
        XCTAssertThrowsError(try store.delete(document))
        XCTAssertEqual(store.documents, [document])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: document).path))
        do {
            try await store.importFile(source)
            XCTFail("Import should fail when its metadata cannot be committed")
        } catch {}
        XCTAssertEqual(store.documents, [document])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("Files").path)
        XCTAssertEqual(remaining, [document.filename])
        try FileManager.default.removeItem(at: manifest)
        try metadata.write(to: manifest)
        XCTAssertEqual(LibraryStore(rootURL: storage).documents, [document])
    }

    func testDeletionPersistsAndNeverDeletesTheOriginal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.txt")
        try "A local document".write(to: source, atomically: true, encoding: .utf8)
        let storage = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: storage)
        try await store.importFile(source)
        let document = try XCTUnwrap(store.documents.first)
        let copy = store.fileURL(for: document)
        try store.delete(document)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(LibraryStore(rootURL: storage).documents.isEmpty)
        XCTAssertThrowsError(try store.delete(document))
    }

    func testInterruptedDeletionRestoresTheReferencedFileOnLaunch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.txt")
        try "Knowledge that must survive interruption".write(to: source, atomically: true, encoding: .utf8)
        let storage = root.appendingPathComponent("Library")
        let store = LibraryStore(rootURL: storage)
        try await store.importFile(source)
        let document = try XCTUnwrap(store.documents.first)
        let originalURL = store.fileURL(for: document)
        let pendingURL = storage.appendingPathComponent("Files/.delete-\(document.id.uuidString)")
        // Simulate termination after staging a deletion and before replacing the manifest.
        try FileManager.default.moveItem(at: originalURL, to: pendingURL)
        let restored = LibraryStore(rootURL: storage)
        XCTAssertNil(restored.lastError)
        XCTAssertEqual(restored.documents, [document])
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.fileURL(for: document).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
    }

    func testUnsafeManifestCannotEscapeStorageOrBeOverwritten() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let id = UUID()
        let document = LibraryDocument(id: id, title: "unsafe", filename: "\(id.uuidString)/../../outside.txt",
            kind: .text, byteCount: 10, importedAt: Date())
        struct UnsafeManifest: Encodable { let formatVersion = 1; let records: [LibraryRecord] }
        let bytes = try JSONEncoder().encode(UnsafeManifest(records: [LibraryRecord(document: document, searchableText: "unsafe")]))
        let manifestURL = storage.appendingPathComponent("library.json")
        try bytes.write(to: manifestURL)
        let source = root.appendingPathComponent("source.txt")
        try "new content".write(to: source, atomically: true, encoding: .utf8)

        let store = LibraryStore(rootURL: storage)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.fileURL(for: document).path.hasPrefix(storage.appendingPathComponent("Files").path + "/"))
        do {
            try await store.importFile(source)
            XCTFail("A corrupt manifest must not be silently replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: manifestURL), bytes)
    }

    func testDirectoryImportFailsWithoutAddingADocument() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        do {
            try await store.importFile(root)
            XCTFail("Folders must be rejected")
        } catch {}
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    func testVerifiedLargeDownloadSharesStorageAndSurvivesDownloadRemoval() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("test-only-sparse.zim")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data()))
        let writer = try FileHandle(forWritingTo: source)
        let length: UInt64 = 127_418_087_648
        try writer.truncate(atOffset: length)
        try writer.close()
        let storage = root.appendingPathComponent("Library"), store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importDownloadedFile(source, sourceRoot: root, expectedBytes: length, name: "TEST ONLY sparse archive")
        let document = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(document.title, "TEST ONLY sparse archive")
        XCTAssertEqual(document.kind, .zim)
        XCTAssertEqual(document.byteCount, Int64(length))
        var original = stat(), saved = stat()
        XCTAssertEqual(lstat(source.path, &original), 0)
        XCTAssertEqual(lstat(store.fileURL(for: document).path, &saved), 0)
        XCTAssertEqual(original.st_ino, saved.st_ino)
        XCTAssertEqual(original.st_dev, saved.st_dev)
        XCTAssertLessThan(original.st_blocks, 100)
        try FileManager.default.removeItem(at: source)
        let reopened = LibraryStore(rootURL: storage)
        XCTAssertEqual(reopened.documents, [document])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reopened.fileURL(for: document).path)[.size] as? NSNumber, NSNumber(value: length))
        try reopened.delete(document)
        XCTAssertTrue(reopened.documents.isEmpty)
    }

    func testVerifiedDownloadRollbackAndCorruptManifestPreserveSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready.txt"), storage = root.appendingPathComponent("Library")
        let bytes = Data("TEST ONLY searchable compass".utf8)
        try bytes.write(to: source)
        let store = LibraryStore(rootURL: storage)
        let manifest = storage.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do {
            try await store.importDownloadedFile(source, sourceRoot: root, expectedBytes: UInt64(bytes.count))
            XCTFail("Metadata failure must roll back the new library link")
        } catch {}
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("Files").path).isEmpty)
        try FileManager.default.removeItem(at: manifest)
        let corrupt = Data("invalid manifest".utf8)
        try corrupt.write(to: manifest)
        let reopened = LibraryStore(rootURL: storage)
        do {
            try await reopened.importDownloadedFile(source, sourceRoot: root, expectedBytes: UInt64(bytes.count))
            XCTFail("Corrupt metadata must not be replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: manifest), corrupt)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testVerifiedDownloadIndexesTextAndDeletionPreservesDownload() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready.txt")
        let bytes = Data("TEST ONLY compass points to magnetic north".utf8)
        try bytes.write(to: source)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try await store.importDownloadedFile(source, sourceRoot: root, expectedBytes: UInt64(bytes.count), name: "Field guide.txt")
        XCTAssertEqual(store.search("magnetic").first?.documentTitle, "Field guide.txt")
        try store.delete(XCTUnwrap(store.documents.first))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
