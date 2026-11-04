import XCTest
@testable import NomadCore

@MainActor
final class NotesStoreTests: XCTestCase {
    func testCreateUpdateReloadAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadNotesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        var note = try store.save(LocalNote(body: "Travel checklist\nWater, compass, flashlight"))
        XCTAssertEqual(note.title, "Travel checklist")
        XCTAssertEqual(store.notes.count, 1)
        note.body += "\nCharge batteries"
        let saved = try store.save(note)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(NotesStore(rootURL: root).notes, [saved])
        try store.delete(saved)
        XCTAssertTrue(NotesStore(rootURL: root).notes.isEmpty)
    }

    func testBlankNotesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadNotesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        XCTAssertThrowsError(try store.save(LocalNote(title: "  ", body: "\n")))
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testFailedSaveKeepsPreviousNoteAndCorruptDataIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadNotesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        let original = try store.save(LocalNote(title: "Original", body: "Keep this"))
        let manifest = root.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var edited = original
        edited.body = "New text"
        XCTAssertThrowsError(try store.save(edited))
        XCTAssertEqual(store.notes, [original])
        try FileManager.default.removeItem(at: manifest)
        let damaged = Data("not JSON".utf8)
        try damaged.write(to: manifest)
        let reopened = NotesStore(rootURL: root)
        XCTAssertNotNil(reopened.lastError)
        XCTAssertThrowsError(try reopened.save(LocalNote(title: "Attempt to overwrite")))
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
    }
}

extension NotesStoreTests {
    private func fixture() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("NomadNotesTests-\(UUID().uuidString)") }

    func testLegacySchemaAndTrashRoundTrip() throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = LocalNote(title: "Legacy", body: "Old notebook #سفر")
        struct Legacy: Encodable { let formatVersion = 1; let notes: [LocalNote] }
        let data = try JSONEncoder().encode(Legacy(notes: [original]))
        try data.write(to: root.appendingPathComponent("notes.json"))
        let store = NotesStore(rootURL: root)
        XCTAssertEqual(store.notes, [original]); XCTAssertTrue(store.trash.isEmpty)
        try store.delete(original)
        let reopened = NotesStore(rootURL: root)
        XCTAssertTrue(reopened.notes.isEmpty); XCTAssertEqual(reopened.trash, [original])
        XCTAssertEqual(try NotesArchive.decode(reopened.exportArchive()).trash, [original])
        try reopened.restore(original)
        XCTAssertEqual(reopened.notes, [original]); XCTAssertTrue(reopened.trash.isEmpty)
        try reopened.delete(original); try reopened.permanentlyDelete(original)
        XCTAssertTrue(NotesStore(rootURL: root).trash.isEmpty)
    }

    func testStaleEditorDeletionAndOtherStoreCannotOverwrite() throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        let original = try store.save(LocalNote(title: "Preserve", body: "Original"))
        let secondStore = NotesStore(rootURL: root)
        var draft = original; draft.body = "Newer text"
        let newer = try store.save(draft, replacing: original)
        var stale = original; stale.body = "Stale text"
        XCTAssertThrowsError(try store.save(stale, replacing: original))
        XCTAssertThrowsError(try store.delete(original))
        XCTAssertThrowsError(try secondStore.save(stale, replacing: original))
        XCTAssertEqual(NotesStore(rootURL: root).notes, [newer])
        secondStore.reload(); XCTAssertEqual(secondStore.notes, [newer])
        try store.delete(newer); try store.permanentlyDelete(newer)
        XCTAssertThrowsError(try store.save(newer, replacing: newer))
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testImportsAreAtomicAdditiveAndPortable() throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        let first = try store.save(LocalNote(title: "A", body: "Keep"))
        let differing = LocalNote(id: first.id, title: "A", body: "Imported revision", createdAt: first.createdAt, updatedAt: first.updatedAt)
        let markdown = try NotesStore.markdownNote(data: Data("\u{FEFF}# رحلة\n#سفر".utf8), filename: "رحلة.md")
        XCTAssertEqual(markdown.title, "رحلة"); XCTAssertEqual(markdown.body, "# رحلة\n#سفر")
        let result = try store.importArchive(NotesArchive(notes: [differing, markdown]))
        XCTAssertEqual(result.added, 2); XCTAssertEqual(result.skipped, 0); XCTAssertEqual(store.notes.count, 3)
        XCTAssertEqual(store.notes.first { $0.id == first.id }, first)
        XCTAssertNotEqual(store.notes.first { $0.body == differing.body }?.id, first.id)
        let duplicate = try store.importArchive(NotesArchive(notes: [differing, markdown]))
        XCTAssertEqual(duplicate.added, 0); XCTAssertEqual(duplicate.skipped, 2)
        let snapshot = try store.exportArchive()
        let decoded = try NotesArchive.decode(snapshot)
        XCTAssertEqual(decoded.notes, store.notes)
        XCTAssertThrowsError(try store.importArchive(NotesArchive(notes: [first], trash: [first])))
        XCTAssertEqual(try store.exportArchive(), snapshot)
        XCTAssertThrowsError(try NotesStore.markdownNote(data: Data([0xff, 0xfe]), filename: "binary.md"))
        XCTAssertThrowsError(try NotesStore.markdownNote(data: Data("Text".utf8), filename: "not-a-note.pdf"))
    }

    func testTagsAndSearchSupportArabicMixedScriptAndCodeExclusion() throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        let tagged = try store.save(LocalNote(title: "Water رحلة", body: "Portable water filter. #Travel #سفر #travelرحلة #مَاء #first-aid\n`#inline`\n```md\n#code\n```\n    #indent\n# Heading"))
        let medical = try store.save(LocalNote(title: "Medical kit", body: "Clean dressings #medical"))
        let untagged = try store.save(LocalNote(title: "Other", body: "Battery checklist"))
        XCTAssertEqual(Set(tagged.tags), Set(["travel", "سفر", "travelرحلة", "مَاء", "first-aid"]))
        XCTAssertEqual(try store.search("#سفر").map(\.id), [tagged.id])
        XCTAssertEqual(try store.search("#travelرحلة").map(\.id), [tagged.id])
        XCTAssertEqual(try store.search("#TRAVEL").map(\.id), [tagged.id])
        XCTAssertEqual(try store.search("tags:trav* AND content:\"water filter\"").map(\.id), [tagged.id])
        XCTAssertEqual(Set(try store.search("water filter OR #medical").map(\.id)), Set([tagged.id, medical.id]))
        XCTAssertEqual(try store.search("NOT tags:*").map(\.id), [untagged.id])
        XCTAssertEqual(try store.search("title:M?dical").map(\.id), [medical.id])
        XCTAssertTrue(try store.search("#trav").isEmpty)
        XCTAssertTrue(try store.search("#inline OR #code OR #indent").isEmpty)
        XCTAssertEqual(store.linkedNotes(title: "water رحلة").map(\.id), [tagged.id])
        for bad in ["water OR", "AND water", "NOT", "\"unclosed", "last_modified:today", "(water OR other)"] { XCTAssertThrowsError(try store.search(bad), bad) }
    }

    func testBoundsCorruptTrashAndSymlinksFailClosed() throws {
        let root = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(rootURL: root)
        let first = try store.save(LocalNote(title: "Keep", body: "Original"))
        let original = try store.exportArchive()
        XCTAssertThrowsError(try store.save(LocalNote(title: "Too large", body: String(repeating: "x", count: NotesArchive.maximumNoteBytes + 1))))
        XCTAssertEqual(try store.exportArchive(), original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["trash"] = [["broken": true]]
        let malformed = try JSONSerialization.data(withJSONObject: object)
        try malformed.write(to: root.appendingPathComponent("notes.json"))
        store.reload(); XCTAssertFalse(store.canWrite); XCTAssertEqual(store.notes, [first])
        XCTAssertThrowsError(try store.save(LocalNote(title: "No overwrite")))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes.json")), malformed)
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notes.json"), withDestinationURL: root.appendingPathComponent("missing-target"))
        let linked = NotesStore(rootURL: root)
        XCTAssertFalse(linked.canWrite); XCTAssertThrowsError(try linked.save(LocalNote(title: "Do not follow link")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-target").path))
        let alias = root.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertFalse(NotesStore(rootURL: alias).canWrite)
    }

    func testMarkdownBlocksPreserveCodeAndRecognizeCommonStructure() throws {
        let blocks = NoteMarkdownBlock.parse("# Title\n\nParagraph **bold**\n\n> Quote\n- [ ] Task\n- [x] Done\n2. Second\n---\n```swift\n#not a heading\n[[not a link]]\n```\nEnd")
        XCTAssertEqual(blocks, [.heading(1, "Title"), .paragraph("Paragraph **bold**"), .quote("Quote"), .list("☐", "Task"), .list("☑", "Done"), .list("2.", "Second"), .rule, .code("#not a heading\n[[not a link]]"), .paragraph("End")])
        XCTAssertEqual(NoteMarkdownBlock.parse("~~~\nunclosed"), [.code("unclosed")])
    }
}
