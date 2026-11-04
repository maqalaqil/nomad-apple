import XCTest
import Darwin
@testable import NomadCore

final class InternalDownloadLinkTests: XCTestCase {
    private func workspace() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NomadLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testRealProbeLeavesFolderEmpty() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(try InternalDownloadLink.probe(in: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testLinkSharesInodeAndSurvivesSourceRemoval() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready.zim"), destination = root.appendingPathComponent("library.zim")
        let bytes = Data("TEST ONLY archive bytes".utf8)
        try bytes.write(to: source)
        XCTAssertTrue(try InternalDownloadLink.stage(source: source, sourceRoot: root, destination: destination, expectedBytes: UInt64(bytes.count)))
        var first = stat(), second = stat()
        XCTAssertEqual(lstat(source.path, &first), 0)
        XCTAssertEqual(lstat(destination.path, &second), 0)
        XCTAssertEqual(first.st_ino, second.st_ino)
        XCTAssertEqual(first.st_dev, second.st_dev)
        XCTAssertEqual(first.st_nlink, 2)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testExistingDestinationIsNeverRemovedOrOverwritten() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready"), destination = root.appendingPathComponent("existing")
        try Data([1]).write(to: source)
        try Data([9]).write(to: destination)
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: source, sourceRoot: root, destination: destination, expectedBytes: 1))
        XCTAssertEqual(try Data(contentsOf: destination), Data([9]))
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }

    func testUnsafeSourcesAndIncorrectLengthsAreRejectedWithoutCreatingDestination() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ready"), destination = root.appendingPathComponent("target")
        try Data([1]).write(to: source)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: link, sourceRoot: root, destination: destination, expectedBytes: 1))
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: source, sourceRoot: root, destination: destination, expectedBytes: 2))
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: root, sourceRoot: root.deletingLastPathComponent(), destination: destination, expectedBytes: 0))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: fifo, sourceRoot: root, destination: destination, expectedBytes: 0))
        let outside = root.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: source, sourceRoot: outside, destination: destination, expectedBytes: 1))
        let rootAlias = root.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: outside)
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: rootAlias.appendingPathComponent("file"), sourceRoot: rootAlias, destination: destination, expectedBytes: 1))
        XCTAssertThrowsError(try InternalDownloadLink.stage(source: source, sourceRoot: root, destination: rootAlias.appendingPathComponent("file"), expectedBytes: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1]))
    }
}
