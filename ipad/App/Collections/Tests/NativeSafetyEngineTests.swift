#if NOMAD_NATIVE_SAFETY_TESTS
// Synthetic, temporary non-user fixtures. This file is inactive in app builds.
private enum NativeSafetyTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "NativeSafetyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw NSError(domain: "NativeSafetyTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func sql(_ database: OpaquePointer?, _ text: String) throws {
        guard sqlite3_exec(database, text, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "NativeSafetyTests.SQL", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
    static func png(width: Int = 1) throws -> Data {
        let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return result as Data
    }
    static func database(_ url: URL, schema: String = "CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB);", image: Data?, extra: String = "") throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(database) }
        try sql(database, "CREATE TABLE metadata(name TEXT,value TEXT); INSERT INTO metadata VALUES('format','png'),('name','TEST-ONLY map'); \(schema)")
        if let image {
            let hex = image.map { String(format: "%02x", $0) }.joined()
            try sql(database, "INSERT INTO tiles VALUES(1,0,1,X'\(hex)');")
        }
        try sql(database, extra)
    }
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-safety-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = LocalManifestFile(url: manifestURL)
        try rejects("Writes before load must fail") { try manifest.save(["unloaded"]) }
        let empty = try manifest.load([String].self)
        try check(empty == nil && manifest.isReady, "Missing manifest should initialize an empty writable store")
        try manifest.save(["kept"])
        try check(try JSONDecoder().decode([String].self, from: Data(contentsOf: manifestURL)) == ["kept"], "Valid save must round trip")
        let malformed = Data("{ test-only corruption".utf8)
        try malformed.write(to: manifestURL)
        try rejects("Malformed JSON must block loading") { _ = try manifest.load([String].self) }
        try check(!manifest.isReady, "Failed reload must close the write gate")
        try rejects("Failed read must block overwrite") { try manifest.save([String]()) }
        try check(try Data(contentsOf: manifestURL) == malformed, "Failed save must preserve original corrupt bytes")
        try Data("[\"duplicate\",\"duplicate\"]".utf8).write(to: manifestURL)
        try rejects("Validation failure must block writes") {
            _ = try manifest.load([String].self) { values in
                guard Set(values).count == values.count else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try rejects("Schema validation failure must block save") { try manifest.save(["replacement"]) }
        try Data("[\"recovered\"]".utf8).write(to: manifestURL)
        try check(try manifest.load([String].self) == ["recovered"] && manifest.isReady, "Successful retry should restore writes")
        let saved = try Data(contentsOf: manifestURL)
        try rejects("Encoding failure should abort atomic save") { try manifest.save([Double.nan]) }
        try check(try Data(contentsOf: manifestURL) == saved, "Failed encoding should retain previous bytes")
        let linked = folder.appendingPathComponent("manifest-link.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: manifestURL)
        var linkedManifest = LocalManifestFile(url: linked)
        try rejects("Manifest symlinks must be rejected") { _ = try linkedManifest.load([String].self) }
        try rejects("A rejected symlink may not be written") { try linkedManifest.save(["bad"]) }
        let dangling = folder.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: folder.appendingPathComponent("does-not-exist"))
        var danglingManifest = LocalManifestFile(url: dangling)
        try rejects("Dangling manifest symlinks must not count as an empty store") { _ = try danglingManifest.load([String].self) }
        let directory = folder.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryManifest = LocalManifestFile(url: directory)
        try rejects("Manifest directories must be rejected") { _ = try directoryManifest.load([String].self) }

        var gate = VaultUnlockGate()
        let first = gate.begin()
        try check(gate.accepts(first), "A new authentication attempt must be accepted")
        gate.invalidate()
        try check(!gate.accepts(first), "Lock/background must invalidate the pending authentication")
        let second = gate.begin()
        try check(gate.accepts(second) && !gate.accepts(first), "An old authentication completion must not unlock a new session")
        let third = gate.begin()
        try check(gate.accepts(third) && !gate.accepts(second), "A superseded completion must be rejected")
        gate.invalidate()
        try check(!gate.accepts(third), "Navigation dismissal must leave no accepted attempt")

        let pixel = try png()
        let current = folder.appendingPathComponent("current.mbtiles")
        try database(current, image: pixel)
        let currentBytes = try Data(contentsOf: current)
        let valid = try RasterMBTilesDatabase(url: current)
        try check(valid.sampleZoom == 1 && valid.metadata["name"] == "TEST-ONLY map", "Valid map metadata and sample should load")
        try check(valid.tileData(x: 0, y: 0, zoom: 1) == pixel, "TMS rows must convert from top-down map coordinates")
        try check(valid.tileData(x: -2, y: 0, zoom: 1) == pixel, "Longitude wrapping should preserve valid tiles")
        try check(valid.tileData(x: 0, y: 2, zoom: 1) == nil && valid.tileData(x: 0, y: 0, zoom: 99) == nil, "Out-of-range coordinates should be rejected safely")
        let brokenCases: [(String, String, Data?, String)] = [
            ("metadata-only", "", nil, ""),
            ("missing-columns", "CREATE TABLE tiles(tile_data BLOB);", nil, ""),
            ("empty-tiles", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", nil, ""),
            ("bad-image", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", Data("TEST-ONLY bad image".utf8), ""),
            ("oversized-image", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", try png(width: 5000), ""),
            ("bad-coordinates", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", pixel, "UPDATE tiles SET tile_column=-1;"),
            ("vector", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", pixel, "UPDATE metadata SET value='pbf' WHERE name='format';"),
            ("xyz-scheme", "CREATE TABLE tiles(zoom_level,tile_column,tile_row,tile_data);", pixel, "INSERT INTO metadata VALUES('scheme','xyz');")
        ]
        for (name, schema, image, extra) in brokenCases {
            let url = folder.appendingPathComponent(name + ".mbtiles")
            try database(url, schema: schema, image: image, extra: extra)
            try rejects("Invalid map \(name) must be rejected") { _ = try RasterMBTilesDatabase(url: url) }
        }
        let mapLink = folder.appendingPathComponent("map-link.mbtiles")
        try FileManager.default.createSymbolicLink(at: mapLink, withDestinationURL: current)
        try rejects("Map symlinks must be rejected") { _ = try RasterMBTilesDatabase(url: mapLink) }
        let view = folder.appendingPathComponent("view.mbtiles")
        try database(view, image: pixel, extra: "ALTER TABLE tiles RENAME TO tile_storage; CREATE VIEW tiles AS SELECT * FROM tile_storage;")
        try check(try RasterMBTilesDatabase(url: view).tileData(x: 0, y: 0, zoom: 1) == pixel, "Valid MBTiles views should remain supported")
        let failedSnapshot = folder.appendingPathComponent("failed-snapshot.mbtiles")
        try rejects("A metadata-only import must not be staged") {
            try RasterMBTilesDatabase.snapshotSelected(folder.appendingPathComponent("metadata-only.mbtiles"), to: failedSnapshot)
        }
        try check(try Data(contentsOf: current) == currentBytes, "Failed import must leave the existing map byte-for-byte intact")

        let walURL = folder.appendingPathComponent("wal.mbtiles")
        try database(walURL, image: pixel)
        var wal: OpaquePointer?
        guard sqlite3_open(walURL.path, &wal) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(wal) }
        try sql(wal, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO tiles SELECT zoom_level,1,tile_row,tile_data FROM tiles LIMIT 1;")
        let mainBytes = try Data(contentsOf: walURL)
        let snapshot = folder.appendingPathComponent("snapshot.mbtiles")
        try RasterMBTilesDatabase.snapshotSelected(walURL, to: snapshot)
        let copy = try RasterMBTilesDatabase(url: snapshot)
        try check(copy.tileData(x: 1, y: 0, zoom: 1) == pixel, "Snapshot must include committed but uncheckpointed WAL tiles")
        try check(try Data(contentsOf: walURL) == mainBytes, "Snapshot must not rewrite the selected source database")
        try check(!FileManager.default.fileExists(atPath: snapshot.path + "-wal") && !FileManager.default.fileExists(atPath: snapshot.path + "-shm"), "Imported snapshot must stand alone without WAL sidecars")
        print("PASS: \(checks) native safety checks (manifest preservation, vault attempt lifecycle, raster validation and WAL snapshots). All fixtures were temporary and synthetic.")
    }
}
@main private enum NativeSafetyRunner {
    static func main() {
        do { try NativeSafetyTests.run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
#endif
