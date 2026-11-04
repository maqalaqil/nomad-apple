import Foundation

private func expectFailure(_ label: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted \(label)") } catch { }
}

@main struct ReadingMarksRegression {
    @MainActor static func main() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("nomad-reading-marks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingMarkStore(rootURL: root)
        let mark = ReadingMark(id: UUID(), bookKey: "fixture-book.epub", bookTitle: "Original fixture book", chapterPath: "Text/chapter.xhtml",
            fragment: "section-two", fraction: 0.42, title: "A useful passage", quote: "Original quoted text العربية", note: "My original note", createdAt: Date(), updatedAt: Date())
        try store.save(mark)
        let restored = ReadingMarkStore(rootURL: root)
        precondition(restored.canWrite && restored.forBook(mark.bookKey) == [mark] && restored.forBook("another-book.epub").isEmpty)
        var edited = mark; edited.note = "Updated note"; edited.updatedAt = Date()
        try restored.save(edited, expectedUpdatedAt: mark.updatedAt)
        precondition(restored.marks.count == 1 && restored.marks[0].note == "Updated note")
        let alteredLocation = ReadingMark(id: mark.id, bookKey: "another-book.epub", bookTitle: mark.bookTitle, chapterPath: mark.chapterPath,
            fragment: mark.fragment, fraction: mark.fraction, title: mark.title, quote: mark.quote, note: mark.note, createdAt: mark.createdAt, updatedAt: Date())
        expectFailure("changing an existing mark's book identity") { try restored.save(alteredLocation, expectedUpdatedAt: edited.updatedAt) }
        expectFailure("stale editor overwrites a newer note") { try restored.save(mark, expectedUpdatedAt: mark.updatedAt) }
        expectFailure("stale store overwrites the file") { try store.save(edited, expectedUpdatedAt: mark.updatedAt) }
        var oversize = mark; oversize.note = String(repeating: "a", count: 8001)
        expectFailure("oversize annotation") { try restored.save(oversize) }
        let invalidPath = ReadingMark(id: UUID(), bookKey: mark.bookKey, bookTitle: mark.bookTitle, chapterPath: "../outside.xhtml", fragment: nil,
            fraction: 0, title: "Invalid", quote: "", note: "", createdAt: Date(), updatedAt: Date())
        expectFailure("path traversal") { try restored.save(invalidPath) }
        let invalidFraction = ReadingMark(id: UUID(), bookKey: mark.bookKey, bookTitle: mark.bookTitle, chapterPath: mark.chapterPath, fragment: nil,
            fraction: .infinity, title: "Invalid", quote: "", note: "", createdAt: Date(), updatedAt: Date())
        expectFailure("nonfinite position") { try restored.save(invalidFraction) }
        let exported = try restored.export(bookKey: mark.bookKey)
        let json = try JSONSerialization.jsonObject(with: exported) as! [[String: Any]]
        precondition(json.count == 1 && json[0]["note"] as? String == "Updated note" && json[0]["createdAt"] is String)
        let manifest = root.appendingPathComponent("marks.json")
        let healthy = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        expectFailure("failed write changes memory") { try restored.delete(mark.id, expectedUpdatedAt: edited.updatedAt) }
        precondition(restored.marks == [edited])
        try FileManager.default.removeItem(at: manifest)
        let corrupt = Data("preserve broken notes".utf8)
        try corrupt.write(to: manifest)
        let broken = ReadingMarkStore(rootURL: root)
        precondition(!broken.canWrite && broken.error != nil)
        expectFailure("corrupt overwrite") { try broken.save(mark) }
        let preserved = try Data(contentsOf: manifest)
        precondition(preserved == corrupt)
        try healthy.write(to: manifest)
        broken.reload()
        precondition(broken.canWrite && broken.marks == [edited])
        try broken.delete(mark.id, expectedUpdatedAt: edited.updatedAt)
        precondition(ReadingMarkStore(rootURL: root).marks.isEmpty)
        try FileManager.default.removeItem(at: manifest)
        let absentTarget = root.appendingPathComponent("must-not-be-created.json")
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: absentTarget)
        let dangling = ReadingMarkStore(rootURL: root)
        precondition(!dangling.canWrite && dangling.error != nil)
        expectFailure("dangling manifest overwrite") { try dangling.save(mark) }
        precondition(!FileManager.default.fileExists(atPath: absentTarget.path))
        print("PASS: reading marks preserve location/quotation/notes across relaunch, filter book identities, reject invalid/changed locations and text bounds, export dates, roll back failed writes, preserve corrupt data, reload and delete")
    }
}
