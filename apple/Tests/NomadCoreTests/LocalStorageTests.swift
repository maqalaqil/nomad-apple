import XCTest
@testable import NomadCore

@MainActor final class LocalStorageTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testBothHistoricalRootCreationOrdersPreserveDataAndSpelling() throws {
        let temporary = try fixture(); defer { try? FileManager.default.removeItem(at: temporary) }
        for first in ["Nomad", "NOMAD"] {
            let support = temporary.appendingPathComponent(first == "Nomad" ? "lower-first" : "upper-first")
            let original = support.appendingPathComponent(first)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            let marker = original.appendingPathComponent("original.txt"), bytes = Data("TEST ONLY existing root".utf8)
            try bytes.write(to: marker)
            let root = LocalStorage.defaultRoot(component: "Notes", supportDirectoryURL: support)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "default lookup must not create the module")
            if try support.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
                XCTAssertEqual(root.deletingLastPathComponent().path, original.path)
            } else { XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Nomad") }
            try LocalStorage.prepare(root, supportDirectoryURL: support)
            let notes = NotesStore(rootURL: root)
            let saved = try notes.save(LocalNote(title: "TEST ONLY", body: "Stored after root resolution"))
            XCTAssertEqual(NotesStore(rootURL: root).notes, [saved])
            let libraryRoot = LocalStorage.defaultRoot(component: "Library", supportDirectoryURL: support)
            try LocalStorage.prepare(libraryRoot, supportDirectoryURL: support)
            XCTAssertNil(LibraryStore(rootURL: libraryRoot).lastError)
            XCTAssertEqual(try Data(contentsOf: marker), bytes)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: support.path).contains(first), "the original root is never renamed")
        }
    }

    func testSymlinkAndFileRootsFailClosedWithoutTouchingTargets() throws {
        let temporary = try fixture(); defer { try? FileManager.default.removeItem(at: temporary) }
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("Notes/keep.txt"), bytes = Data("TEST ONLY preserve".utf8)
        try bytes.write(to: marker)
        for name in ["Nomad", "NOMAD"] {
            let support = temporary.appendingPathComponent(name == "Nomad" ? "exact-link" : "alternate-link")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: support.appendingPathComponent(name), withDestinationURL: outside)
            let caseInsensitive = try support.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
            if name == "Nomad" || caseInsensitive {
                XCTAssertThrowsError(try LocalStorage.directory(in: support, components: ["Nomad", "Notes"], create: false))
                let unresolved = LocalStorage.defaultRoot(component: "Notes", supportDirectoryURL: support)
                XCTAssertThrowsError(try LocalStorage.prepare(unresolved, supportDirectoryURL: support))
            }
            XCTAssertEqual(try Data(contentsOf: marker), bytes)
        }
        let support = temporary.appendingPathComponent("file-root")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try bytes.write(to: support.appendingPathComponent("Nomad"))
        XCTAssertThrowsError(try LocalStorage.directory(in: support, components: ["Nomad", "Library"], create: true))
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("Nomad")), bytes)
        let moduleSupport = temporary.appendingPathComponent("module-link")
        try FileManager.default.createDirectory(at: moduleSupport.appendingPathComponent("Nomad"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: moduleSupport.appendingPathComponent("Nomad/Library"), withDestinationURL: outside)
        XCTAssertThrowsError(try LocalStorage.directory(in: moduleSupport, components: ["Nomad", "Library"], create: true))
    }

    func testReadOnlyMissingRootAndExplicitRootIdentity() throws {
        let temporary = try fixture(); defer { try? FileManager.default.removeItem(at: temporary) }
        let missing = temporary.appendingPathComponent("missing-support")
        let root = LocalStorage.defaultRoot(component: "Library", supportDirectoryURL: missing)
        XCTAssertEqual(root.path, missing.appendingPathComponent("Nomad/Library").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try LocalStorage.prepare(root, supportDirectoryURL: missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNoThrow(try LocalStorage.prepare(URL(fileURLWithPath: root.path, isDirectory: false), supportDirectoryURL: missing))
        let custom = temporary.appendingPathComponent("MyUnchangedStore")
        let library = LibraryStore(rootURL: custom)
        XCTAssertEqual(library.storageURL.path, custom.path)
        XCTAssertNil(library.lastError)
        let link = temporary.appendingPathComponent("explicit-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: custom)
        XCTAssertNotNil(LibraryStore(rootURL: link).lastError)
        XCTAssertFalse(NotesStore(rootURL: link).canWrite)
        XCTAssertThrowsError(try LocalStorage.directory(in: missing, components: [".."], create: false))
    }
}
