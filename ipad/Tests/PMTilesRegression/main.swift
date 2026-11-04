import Foundation
import Darwin

@main struct PMTilesStoreRegression {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NomadPMTilesRegression-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected rejection: \(label)") }
            catch { checks += 1 }
        }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Empty PMTiles v3 root (zero directory entries), local {} metadata,
        // and optional unreferenced padding. This is a storage fixture, not a map.
        func fixture(_ name: String, bytes: UInt64 = 130) throws -> URL {
            let url = root.appendingPathComponent(name + ".pmtiles")
            var data = Data(repeating: 0, count: 130)
            data.replaceSubrange(0..<8, with: Array("PMTiles".utf8) + [3])
            func u64(_ offset: Int, _ value: UInt64) {
                for i in 0..<8 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
            }
            u64(8,127); u64(16,1); u64(24,128); u64(32,2)
            u64(40,130); u64(48,0); u64(56,130); u64(64,bytes-130)
            data[97] = 1; data[98] = 1; data[99] = 1
            data[128] = 123; data[129] = 125
            try data.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: bytes) // Sparse: never allocate/read a world archive.
            try handle.close()
            return url
        }
        func workspace(_ directory: URL) -> URL { directory.appendingPathComponent("workspace.json") }
        func stageName(_ archive: PMTilesArchive) -> String { ".delete-\(archive.id.uuidString.lowercased()).pmtiles" }
        func files(_ directory: URL) throws -> [String] { try manager.contentsOfDirectory(atPath: directory.path).sorted() }
        func identity(_ url: URL) throws -> (device: Int32, inode: UInt64, links: UInt16) {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
            return (Int32(value.st_dev), UInt64(value.st_ino), UInt16(value.st_nlink))
        }
        func breakManifest(_ directory: URL) throws {
            try manager.removeItem(at: workspace(directory))
            try manager.createDirectory(at: workspace(directory), withIntermediateDirectories: false)
        }
        func imported(_ name: String, source: URL) async throws -> PMTilesStore {
            let store = PMTilesStore(directoryURL: try folder(name), availableBytesProvider: { Int64.max })
            await store.importFiles([source])
            expect(store.archives.count == 1 && store.canWrite && !store.importing, "Fixture imports safely")
            return store
        }

        let source = try fixture("source", bytes: 9 * 1_024 * 1_024 + 29)
        let inspected = try PMTilesHeader.read(from: source)
        expect(inspected.bytes == 9 * 1_024 * 1_024 + 29, "Exact 64-bit file length")
        rejects("Directory header") { _ = try PMTilesHeader.read(from: root) }
        let link = root.appendingPathComponent("linked.pmtiles")
        try manager.createSymbolicLink(at: link, withDestinationURL: source)
        rejects("Symlink header") { _ = try PMTilesHeader.read(from: link) }
        rejects("Remote URL") { _ = try PMTilesHeader.read(from: URL(string: "https://example.org/world.pmtiles")!) }

        let store = try await imported("basic", source: source)
        let archive = store.archives[0]
        expect(try Data(contentsOf: source) == Data(contentsOf: store.fileURL(for: archive)), "Multi-chunk copy preserves every byte")
        store.addPlace(name: "Home", notes: "Offline", latitude: 24.7, longitude: 46.7)
        store.setEnabled(archive.id, enabled: false)
        let reloaded = PMTilesStore(directoryURL: store.directory)
        expect(reloaded.canWrite && reloaded.places.count == 1 && reloaded.archives.first?.enabled == false, "Manifest roundtrip and repeated writes")
        let beforeInvalid = try Data(contentsOf: workspace(store.directory))
        store.addPlace(name: "Invalid", notes: "", latitude: .nan, longitude: 0)
        store.addPlace(name: "Invalid", notes: String(repeating: "x", count: 65 * 1_024), latitude: 0, longitude: 0)
        expect(store.canWrite && store.places.count == 1, "Invalid input does not change state or close healthy storage")
        expect(try Data(contentsOf: workspace(store.directory)) == beforeInvalid, "Invalid input preserves disk manifest")

        let corruptDirectory = try folder("corrupt")
        let corruptBytes = Data("{broken".utf8)
        try corruptBytes.write(to: workspace(corruptDirectory))
        let corrupt = PMTilesStore(directoryURL: corruptDirectory, availableBytesProvider: { Int64.max })
        expect(!corrupt.canWrite, "Corrupt manifest closes writes")
        corrupt.addPlace(name: "Lost", notes: "", latitude: 0, longitude: 0)
        corrupt.removePlace(UUID()); corrupt.remove(archive)
        await corrupt.importFiles([source])
        expect(try Data(contentsOf: workspace(corruptDirectory)) == corruptBytes, "All mutations preserve corrupt metadata")
        expect(try files(corruptDirectory) == ["workspace.json"], "No copy starts with corrupt metadata")

        let duplicate = try await imported("duplicate", source: source)
        let duplicateBytes = try Data(contentsOf: workspace(duplicate.directory))
        var duplicateJSON = try JSONSerialization.jsonObject(with: duplicateBytes) as! [String: Any]
        let rows = duplicateJSON["archives"] as! [[String: Any]]
        duplicateJSON["archives"] = rows + rows
        let invalidDuplicate = try JSONSerialization.data(withJSONObject: duplicateJSON)
        try invalidDuplicate.write(to: workspace(duplicate.directory))
        expect(!PMTilesStore(directoryURL: duplicate.directory).canWrite, "Duplicate archive IDs rejected")
        expect(try Data(contentsOf: workspace(duplicate.directory)) == invalidDuplicate, "Duplicate metadata retained")

        let toggleFailure = try await imported("toggle-failure", source: source)
        try breakManifest(toggleFailure.directory)
        toggleFailure.setEnabled(toggleFailure.archives[0].id, enabled: false)
        expect(!toggleFailure.canWrite && toggleFailure.archives[0].enabled, "Toggle rolls back when manifest cannot save")

        let deleteFailure = try await imported("delete-failure", source: source)
        let kept = deleteFailure.archives[0]
        try breakManifest(deleteFailure.directory)
        deleteFailure.remove(kept)
        expect(!deleteFailure.canWrite && deleteFailure.archives.count == 1, "Failed deletion preserves in-memory entry")
        expect(manager.fileExists(atPath: deleteFailure.fileURL(for: kept).path), "Failed deletion restores original file path")
        expect(!manager.fileExists(atPath: deleteFailure.directory.appendingPathComponent(stageName(kept)).path), "Rollback removes staged-deletion path")
        expect(try Data(contentsOf: deleteFailure.fileURL(for: kept)) == Data(contentsOf: source), "Failed deletion preserves all bytes")

        let importFailure = try await imported("import-failure", source: source)
        let originalFile = importFailure.fileURL(for: importFailure.archives[0])
        try breakManifest(importFailure.directory)
        await importFailure.importFiles([source])
        expect(!importFailure.canWrite && importFailure.archives.count == 1, "Failed import leaves original entries")
        expect(try files(importFailure.directory) == [originalFile.lastPathComponent, "workspace.json"].sorted(), "Failed import removes unpublished destination/staging")
        expect(try Data(contentsOf: source) == Data(contentsOf: originalFile), "Source and earlier archive remain intact")

        let worldSize: UInt64 = 134_812_420_554
        let world = try fixture("synthetic-world-size", bytes: worldSize)
        expect(try PMTilesHeader.read(from: world).bytes == worldSize, "World-sized sparse header uses 64-bit lengths")
        let tail = try PMTilesByteRange.parse("bytes=134812420400-134812420553", fileSize: worldSize)
        expect(tail.start == 134_812_420_400 && tail.count == 154, "World byte ranges avoid 32-bit truncation")
        rejects("Oversized byte range") { _ = try PMTilesByteRange.parse("bytes=0-33554432", fileSize: worldSize) }
        rejects("Range beyond file") { _ = try PMTilesByteRange.parse("bytes=134812420554-", fileSize: worldSize) }
        let noSpace = PMTilesStore(directoryURL: try folder("capacity"), availableBytesProvider: { Int64(worldSize - 1) })
        await noSpace.importFiles([world])
        expect(noSpace.archives.isEmpty && noSpace.canWrite && !noSpace.importing, "World import rejects insufficient capacity without closing healthy store")
        expect(noSpace.error?.contains("512 MB") == true, "Capacity error explains extra copy and reserve")
        expect(try files(noSpace.directory).isEmpty, "Capacity rejection creates no partial world copy")

        // A real hardlink, not a size/probe assumption. A copy cannot pass with
        // this capacity budget; the world fixture remains sparse throughout.
        expect(try InternalDownloadLink.probe(in: root), "Actual filesystem hardlink probe succeeds")
        let linkedWorld = PMTilesStore(directoryURL: try folder("linked-world"), availableBytesProvider: { Int64(PMTilesFileIO.storageReserve + 1_024 * 1_024) })
        expect(await linkedWorld.importDownloadedFile(world, sourceRoot: root, expectedBytes: worldSize, name: "World"), "Internal world import needs no second archive allocation")
        let worldMap = linkedWorld.fileURL(for: linkedWorld.archives[0])
        let worldBefore = try identity(world), worldAfter = try identity(worldMap)
        expect(worldBefore.device == worldAfter.device && worldBefore.inode == worldAfter.inode && worldAfter.links == 2, "Internal world archive shares the verified source inode")
        try manager.removeItem(at: world)
        expect(try PMTilesHeader.read(from: worldMap).bytes == worldSize, "Imported map survives download removal")
        linkedWorld.remove(linkedWorld.archives[0])
        expect(linkedWorld.archives.isEmpty && !manager.fileExists(atPath: worldMap.path), "Last hardlink can be safely deleted")

        let linkedSmall = PMTilesStore(directoryURL: try folder("linked-small"), availableBytesProvider: { Int64(PMTilesFileIO.storageReserve + 1_024 * 1_024) })
        expect(await linkedSmall.importDownloadedFile(source, sourceRoot: root, expectedBytes: inspected.bytes), "Internal smaller archive uses explicit download API")
        linkedSmall.remove(linkedSmall.archives[0])
        expect(try PMTilesHeader.read(from: source).bytes == inspected.bytes, "Download survives imported-map removal")
        expect(try identity(source).links == 1, "Imported-map removal releases only its own link")

        let linkedFailure = PMTilesStore(directoryURL: try folder("linked-rollback"), availableBytesProvider: { Int64.max })
        try manager.createDirectory(at: workspace(linkedFailure.directory), withIntermediateDirectories: false)
        expect(!(await linkedFailure.importDownloadedFile(source, sourceRoot: root, expectedBytes: inspected.bytes)), "Manifest failure rejects linked import")
        expect(!linkedFailure.canWrite && linkedFailure.archives.isEmpty, "Linked import does not publish failed metadata")
        expect(try files(linkedFailure.directory) == ["workspace.json"], "Linked import rollback removes only its staged/destination links")
        expect(try identity(source).links == 1 && PMTilesHeader.read(from: source).bytes == inspected.bytes, "Rollback retains source inode and bytes")

        let guarded = PMTilesStore(directoryURL: try folder("guarded-link"), availableBytesProvider: { Int64.max })
        expect(!(await guarded.importDownloadedFile(source, sourceRoot: corruptDirectory, expectedBytes: inspected.bytes)), "Internal API rejects source outside trusted download root")
        expect(!(await guarded.importDownloadedFile(source, sourceRoot: root, expectedBytes: inspected.bytes + 1)), "Internal API rejects mismatched verified size")
        expect(!(await guarded.importDownloadedFile(link, sourceRoot: root, expectedBytes: inspected.bytes)), "Internal API rejects source symlink")
        expect(try files(guarded.directory).isEmpty, "Rejected internal inputs leave no staged files")
        let brokenMap = root.appendingPathComponent("broken.pmtiles")
        try Data(repeating: 0, count: 130).write(to: brokenMap)
        expect(!(await guarded.importDownloadedFile(brokenMap, sourceRoot: root, expectedBytes: 130)), "Linked import validates actual PMTiles header")
        expect(try identity(brokenMap).links == 1 && files(guarded.directory).isEmpty, "Invalid linked archive cleanup preserves its source")

        let collision = try folder("link-collision").appendingPathComponent("existing")
        let collisionBytes = Data("Unrelated existing file".utf8)
        try collisionBytes.write(to: collision)
        rejects("Hardlink destination collision") { _ = try InternalDownloadLink.stage(source: source, sourceRoot: root, destination: collision, expectedBytes: inspected.bytes) }
        expect(try Data(contentsOf: collision) == collisionBytes, "Failed hardlink never removes a preexisting destination")

        let linkStore = PMTilesStore(directoryURL: try folder("symlink"), availableBytesProvider: { Int64.max })
        await linkStore.importFiles([link])
        expect(linkStore.archives.isEmpty && linkStore.error != nil, "Coordinated import rejects symlink")
        expect(try files(linkStore.directory).isEmpty, "Symlink creates no imported file")

        let recovery = try await imported("recover-before-commit", source: source)
        let recovering = recovery.archives[0]
        let staged = recovery.directory.appendingPathComponent(stageName(recovering))
        try manager.moveItem(at: recovery.fileURL(for: recovering), to: staged)
        let restored = PMTilesStore(directoryURL: recovery.directory)
        expect(restored.canWrite && restored.archives.count == 1, "Interrupted precommit deletion recovers metadata")
        expect(manager.fileExists(atPath: restored.fileURL(for: recovering).path) && !manager.fileExists(atPath: staged.path), "Interrupted deletion restores bytes")
        restored.remove(restored.archives[0])
        expect(restored.canWrite && restored.archives.isEmpty && !manager.fileExists(atPath: restored.fileURL(for: recovering).path), "Successful deletion commits then removes bytes")
        expect(PMTilesStore(directoryURL: recovery.directory).canWrite, "Deleted workspace reopens cleanly")

        let cleanup = try await imported("recover-after-commit", source: source)
        let cleanupArchive = cleanup.archives[0]
        let cleanupStage = cleanup.directory.appendingPathComponent(stageName(cleanupArchive))
        try manager.moveItem(at: cleanup.fileURL(for: cleanupArchive), to: cleanupStage)
        var cleanedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace(cleanup.directory))) as! [String: Any]
        cleanedJSON["archives"] = []
        try JSONSerialization.data(withJSONObject: cleanedJSON).write(to: workspace(cleanup.directory))
        let afterCleanup = PMTilesStore(directoryURL: cleanup.directory)
        expect(afterCleanup.canWrite && afterCleanup.archives.isEmpty && !manager.fileExists(atPath: cleanupStage.path), "Committed deletion finishes cleanup on reopen")

        let lostManifest = try await imported("missing-manifest", source: source)
        let retained = lostManifest.fileURL(for: lostManifest.archives[0])
        try manager.removeItem(at: workspace(lostManifest.directory))
        let protected = PMTilesStore(directoryURL: lostManifest.directory)
        protected.addPlace(name: "No overwrite", notes: "", latitude: 0, longitude: 0)
        expect(!protected.canWrite && manager.fileExists(atPath: retained.path), "Missing manifest preserves existing archive")
        expect(!manager.fileExists(atPath: workspace(lostManifest.directory).path), "Missing manifest is not silently replaced")

        let partialDirectory = try folder("interrupted-import")
        let partial = partialDirectory.appendingPathComponent(".import-\(UUID().uuidString.lowercased())")
        try Data([1,2,3]).write(to: partial)
        let partialRecovery = PMTilesStore(directoryURL: partialDirectory)
        expect(partialRecovery.canWrite && !manager.fileExists(atPath: partial.path), "Unpublished interrupted import releases partial storage")

        let conflictDirectory = try folder("conflict")
        let first = PMTilesStore(directoryURL: conflictDirectory)
        let second = PMTilesStore(directoryURL: conflictDirectory)
        first.addPlace(name: "First", notes: "", latitude: 0, longitude: 0)
        second.addPlace(name: "Stale", notes: "", latitude: 1, longitude: 1)
        expect(!second.canWrite && second.places.isEmpty, "Stale screen cannot replace a newer workspace")
        expect(PMTilesStore(directoryURL: conflictDirectory).places.map(\.name) == ["First"], "Concurrent screen data is retained")

        let cancelSource = try fixture("cancel-source", bytes: 128 * 1_024 * 1_024)
        let cancelStore = PMTilesStore(directoryURL: try folder("cancel"), availableBytesProvider: { Int64.max })
        let importing = Task { await cancelStore.importFiles([cancelSource]) }
        for _ in 0..<500 {
            if let copying = (try files(cancelStore.directory)).first(where: { $0.hasPrefix(".import-") }) {
                let anotherScreen = PMTilesStore(directoryURL: cancelStore.directory)
                expect(anotherScreen.canWrite && manager.fileExists(atPath: cancelStore.directory.appendingPathComponent(copying).path), "Opening another screen preserves an active import")
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        importing.cancel(); await importing.value
        expect(cancelStore.archives.isEmpty && !cancelStore.importing, "Cancellation never publishes partial archive")
        expect(try files(cancelStore.directory).isEmpty, "Cancellation releases partial copy")
        expect(try PMTilesHeader.read(from: cancelSource).bytes == 128 * 1_024 * 1_024, "Cancellation preserves source")
        print("PASS: \(checks) PMTiles storage checks; bounded copies, protected manifests, real internal hardlinks, world-size capacity/ranges, symlinks, cancellation, transactional deletion and recovery")
    }
}
