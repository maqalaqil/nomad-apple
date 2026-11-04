import SwiftUI
import UniformTypeIdentifiers
import SQLite3
import ImageIO

private struct SavedPlace: Codable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
}

// BEGIN RASTER_DATABASE: Foundation/SQLite/ImageIO engine, exercised by native fixture tests.
private final class RasterMBTilesDatabase {
    private var database: OpaquePointer?
    private var deadline = Date.distantFuture
    let metadata: [String: String]
    let sampleZoom: Int
    let sampleLongitude: Double
    let sampleLatitude: Double

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Maps", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw Self.failure("Choose a regular MBTiles file, not a folder or symbolic link.")
        }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            throw Self.failure("This file could not be opened as an MBTiles map.")
        }
        var success = false
        defer { if !success { sqlite3_close(opened) } }
        sqlite3_busy_timeout(opened, 1_000)
        sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, 20_000_000)
        guard sqlite3_exec(opened, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            throw Self.failure("The map database could not be opened safely.")
        }
        // Bound validation of user-supplied views/triggers. No extensions are loaded.
        let timeout = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        timeout.initialize(to: Date.timeIntervalSinceReferenceDate + 10)
        sqlite3_progress_handler(opened, 10_000, { context in
            guard let context else { return 1 }
            return Date.timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
        }, timeout)
        defer { sqlite3_progress_handler(opened, 0, nil, nil); timeout.deinitialize(count: 1); timeout.deallocate() }
        var result: [String: String] = [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(opened, "SELECT name, value FROM metadata LIMIT 1000", -1, &statement, nil) == SQLITE_OK else {
            throw Self.failure("This MBTiles file has no readable metadata table.")
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                result[String(cString: key)] = String(cString: value)
            }
            status = sqlite3_step(statement)
        }
        sqlite3_finalize(statement); statement = nil
        guard status == SQLITE_DONE else { throw Self.failure("Map metadata is damaged or too complex to read.") }
        guard ["png", "jpg", "jpeg", "webp"].contains(result["format"]?.lowercased() ?? "") else {
            throw Self.failure("This build reads raster MBTiles (PNG/JPEG/WebP). Vector MBTiles and NOMAD PMTiles need the vector-map integration.")
        }
        guard result["scheme"] == nil || result["scheme"]?.lowercased() == "tms" else {
            throw Self.failure("This map does not use the MBTiles TMS tile-row scheme.")
        }
        guard sqlite3_prepare_v2(opened, "SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw Self.failure("This MBTiles file has no readable tiles table or view.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              (0...2).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
              sqlite3_column_type(statement, 3) == SQLITE_BLOB else { throw Self.failure("This map contains no usable raster tiles.") }
        let z = Int(sqlite3_column_int64(statement, 0))
        let x = Int(sqlite3_column_int64(statement, 1)), y = Int(sqlite3_column_int64(statement, 2))
        guard (0...20).contains(z), x >= 0, x < (1 << z), y >= 0, y < (1 << z),
              let data = Self.blob(statement, column: 3), Self.decodedImage(data) != nil else {
            throw Self.failure("The map’s sample tile has invalid coordinates or unreadable raster image data.")
        }
        metadata = result; sampleZoom = z
        sampleLongitude = (Double(x) + 0.5) / Double(1 << z) * 360 - 180
        sampleLatitude = atan(sinh(.pi * (1 - 2 * (Double((1 << z) - 1 - y) + 0.5) / Double(1 << z)))) * 180 / .pi
        database = opened; success = true
    }

    deinit { if let database { sqlite3_close(database) } }

    private static func blob(_ statement: OpaquePointer?, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count < 20_000_000, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    static func decodedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...4096).contains(width.intValue), (1...4096).contains(height.intValue) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    func tileData(x: Int, y: Int, zoom: Int) -> Data? {
        guard (0...20).contains(zoom), y >= 0, y < (1 << zoom) else { return nil }
        let count = 1 << zoom, wrappedX = ((x % count) + count) % count
        // A corrupt or deliberately expensive view cannot block one tile lookup indefinitely.
        deadline = Date().addingTimeInterval(0.1)
        sqlite3_progress_handler(database, 1_000, { context in
            guard let context else { return 1 }
            let owner = Unmanaged<RasterMBTilesDatabase>.fromOpaque(context).takeUnretainedValue()
            return Date() > owner.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(zoom)); sqlite3_bind_int(statement, 2, Int32(wrappedX)); sqlite3_bind_int(statement, 3, Int32(count - 1 - y))
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_BLOB else { return nil }
        return Self.blob(statement, column: 0)
    }

    /// SQLite backup includes committed WAL pages and leaves the user’s source unchanged.
    static func snapshotSelected(_ source: URL, to destination: URL) throws {
        guard source.isFileURL else { throw failure("Choose a local map file from Files.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            outcome = Result {
                let sourceDatabase = try RasterMBTilesDatabase(url: coordinated)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("The staging file already exists.") }
                var target: OpaquePointer?
                guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                    if let target { sqlite3_close(target) }
                    throw failure("The map snapshot could not be created.")
                }
                defer { sqlite3_close(target) }
                guard let backup = sqlite3_backup_init(target, "main", sourceDatabase.database, "main") else {
                    throw failure("The map snapshot could not be started.")
                }
                let result = sqlite3_backup_step(backup, -1)
                let finished = sqlite3_backup_finish(backup)
                guard result == SQLITE_DONE, finished == SQLITE_OK else {
                    throw failure("The map could not be copied consistently. Close any app editing it and try again.")
                }
                // Reopen so SQLite reads the copied WAL header instead of retaining
                // the empty destination's cached journal mode.
                sqlite3_close(target); target = nil
                guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                      sqlite3_exec(target, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
                    throw failure("The map snapshot could not be made independent of its journal files.")
                }
                guard sqlite3_close(target) == SQLITE_OK else { throw failure("The map snapshot could not be closed.") }
                target = nil
                // Apple SQLite can leave a stale shared-memory file after leaving WAL mode.
                // This owned, closed DELETE-mode snapshot no longer uses either sidecar.
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: destination.path + suffix)
                    if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw failure("The selected map could not be read.") }
        try outcome.get()
    }
}
// END RASTER_DATABASE

private final class RasterArchive {
    private let database: RasterMBTilesDatabase
    private let cache = NSCache<NSString, UIImage>()
    let name: String
    let minZoom: Int
    let maxZoom: Int
    let initialZoom: Int
    let latitude: Double
    let longitude: Double
    init(url: URL) throws {
        database = try RasterMBTilesDatabase(url: url)
        let metadata = database.metadata
        name = metadata["name"] ?? url.deletingPathExtension().lastPathComponent
        minZoom = max(0, min(20, Int(metadata["minzoom"] ?? "") ?? 0))
        maxZoom = max(minZoom, min(20, Int(metadata["maxzoom"] ?? "") ?? 20))
        let center = metadata["center"]?.split(separator: ",").compactMap { Double($0) } ?? []
        let proposedLongitude = center.count >= 2 ? center[0] : database.sampleLongitude
        let proposedLatitude = center.count >= 2 ? center[1] : database.sampleLatitude
        longitude = proposedLongitude.isFinite ? min(180, max(-180, proposedLongitude)) : database.sampleLongitude
        latitude = proposedLatitude.isFinite ? min(85.0511, max(-85.0511, proposedLatitude)) : database.sampleLatitude
        let proposedZoom = center.count >= 3 && center[2].isFinite && (0...20).contains(center[2]) ? Int(center[2]) : database.sampleZoom
        initialZoom = min(maxZoom, max(minZoom, proposedZoom))
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }
    func tile(x: Int, y: Int, zoom: Int) -> UIImage? {
        guard (0...20).contains(zoom), y >= 0, y < (1 << zoom) else { return nil }
        let count = 1 << zoom, wrappedX = ((x % count) + count) % count
        let key = "\(zoom)/\(wrappedX)/\(y)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = database.tileData(x: x, y: y, zoom: zoom), let decoded = RasterMBTilesDatabase.decodedImage(data) else { return nil }
        let image = UIImage(cgImage: decoded)
        cache.setObject(image, forKey: key, cost: decoded.width * decoded.height * 4)
        return image
    }
}

struct OfflinePlacesView: View {
    private struct PendingMap: Identifiable { let id = UUID(); let url: URL; let name: String }
    @State private var archive: RasterArchive?
    @State private var places: [SavedPlace] = []
    @State private var zoom = 2
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @GestureState private var drag = CGSize.zero
    @State private var importer = false
    @State private var addPlace = false
    @State private var placeName = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var error: String?
    @State private var busy = false
    @State private var placesFile = LocalManifestFile(url: URL.applicationSupportDirectory.appending(path: "NomadPad/Maps/places.json"))
    @State private var deletingPlace: SavedPlace?
    @State private var pendingMap: PendingMap?
    private let root = URL.applicationSupportDirectory.appending(path: "NomadPad/Maps")

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(archive?.name ?? "Local map collection", systemImage: "map")
                Spacer()
                if busy { ProgressView() }
                Button("Import map", systemImage: "square.and.arrow.down") { importer = true }.disabled(busy || pendingMap != nil)
                Button("Save place", systemImage: "mappin.and.ellipse") {
                    let coordinate = coordinate(at: center)
                    latitude = String(format: "%.6f", coordinate.0); longitude = String(format: "%.6f", coordinate.1)
                    placeName = ""; addPlace = true
                }.disabled(!placesFile.isReady)
            }.padding()
            if !placesFile.isReady {
                HStack {
                    Text("Saved places could not be loaded. Changes are disabled to preserve your file.").font(.caption).foregroundStyle(.orange)
                    Button("Reload places") { loadPlaces() }
                }.padding(.horizontal)
            }
            if let archive {
                GeometryReader { geometry in
                    let world = Double(1 << zoom) * 256
                    let originX = center.x * world - geometry.size.width / 2 - drag.width
                    let originY = center.y * world - geometry.size.height / 2 - drag.height
                    let startX = Int(floor(originX / 256)), startY = Int(floor(originY / 256))
                    let columns = Int(ceil(geometry.size.width / 256)) + 2, rows = Int(ceil(geometry.size.height / 256)) + 2
                    ZStack {
                        Color(red: 0.12, green: 0.17, blue: 0.15)
                        ForEach(0..<(columns * rows), id: \.self) { index in
                            let x = startX + index % columns, y = startY + index / columns
                            Group {
                                if let tile = archive.tile(x: x, y: y, zoom: zoom) { Image(uiImage: tile).resizable() }
                                else { Rectangle().fill(.white.opacity(0.02)).overlay { Text("No downloaded tile").font(.caption2).foregroundStyle(.secondary) } }
                            }.frame(width: 256, height: 256).position(x: Double(x) * 256 - originX + 128, y: Double(y) * 256 - originY + 128)
                        }
                        ForEach(places) { place in
                            let point = normalized(latitude: place.latitude, longitude: place.longitude)
                            Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.orange)
                                .position(x: point.x * world - originX, y: point.y * world - originY)
                                .accessibilityLabel(place.name)
                        }
                        Image(systemName: "plus").foregroundStyle(.white).shadow(radius: 2)
                    }.clipped().contentShape(Rectangle())
                        .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                            center.x = (center.x - value.translation.width / world + 1).truncatingRemainder(dividingBy: 1)
                            center.y = min(1, max(0, center.y - value.translation.height / world))
                        })
                        .overlay(alignment: .bottomTrailing) {
                            HStack {
                                Button { zoom = max(archive.minZoom, zoom - 1) } label: { Image(systemName: "minus") }
                                Text("\(zoom)").monospacedDigit()
                                Button { zoom = min(archive.maxZoom, zoom + 1) } label: { Image(systemName: "plus") }
                            }.buttonStyle(.bordered).padding().background(.regularMaterial, in: Capsule()).padding()
                        }
                }
            } else {
                ContentUnavailableView("Bring your map offline", systemImage: "map", description: Text("Import a raster .mbtiles file to browse without a network. Saved places also work without a map. For .pmtiles files, open the NOMAD vector maps reader in Offline Maps."))
            }
            if !places.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(places) { place in
                            Button { center = normalized(latitude: place.latitude, longitude: place.longitude) } label: { Label(place.name, systemImage: "mappin") }.buttonStyle(.bordered)
                                .contextMenu { Button("Delete saved place", role: .destructive) { deletingPlace = place }.disabled(!placesFile.isReady) }
                        }
                    }.padding()
                }
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [UTType(filenameExtension: "mbtiles") ?? .data]) { result in
            switch result { case .success(let url): importMap(url); case .failure(let error): self.error = error.localizedDescription }
        }
        .sheet(isPresented: $addPlace) {
            NavigationStack {
                Form {
                    TextField("Place name", text: $placeName)
                    TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                }.navigationTitle("Save a place").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addPlace = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        guard let lat = Double(latitude), let lon = Double(longitude), lat.isFinite, lon.isFinite, (-85.0511...85.0511).contains(lat), (-180...180).contains(lon), !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a name and valid coordinates (latitude between −85.0511 and 85.0511; longitude between −180 and 180)."; return }
                        if savePlaces(places + [SavedPlace(name: placeName.trimmingCharacters(in: .whitespacesAndNewlines), latitude: lat, longitude: lon)]) { addPlace = false }
                    } }
                }
            }
        }
        .sheet(item: $pendingMap) { pending in
            NavigationStack {
                Form {
                    Text(pending.name).font(.headline)
                    Text("This map contains a readable raster tile. Installing it replaces the current local map. Your saved places are kept.")
                }.navigationTitle("Install local map")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discardPendingMap() } }
                        ToolbarItem(placement: .confirmationAction) { Button("Install map") { installMap(pending.url) } }
                    }
            }.interactiveDismissDisabled()
        }
        .confirmationDialog("Delete this saved place?", isPresented: Binding(get: { deletingPlace != nil }, set: { if !$0 { deletingPlace = nil } }), titleVisibility: .visible) {
            Button("Delete saved place", role: .destructive) {
                if let deletingPlace { _ = savePlaces(places.filter { $0.id != deletingPlace.id }) }
                deletingPlace = nil
            }
        }
        .alert("Maps", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task { load() }
    }
    private func normalized(latitude: Double, longitude: Double) -> CGPoint {
        let lat = min(85.0511, max(-85.0511, latitude)) * .pi / 180
        return CGPoint(x: (longitude + 180) / 360, y: (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2)
    }
    private func coordinate(at point: CGPoint) -> (Double, Double) {
        (atan(sinh(.pi * (1 - 2 * point.y))) * 180 / .pi, point.x * 360 - 180)
    }
    private func load() {
        loadPlaces()
        do {
            let mapURL = root.appending(path: "current.mbtiles")
            if FileManager.default.fileExists(atPath: mapURL.path) { try openMap(mapURL) }
        } catch { self.error = error.localizedDescription }
    }
    private func loadPlaces() {
        guard !placesFile.isReady else { return }
        do {
            places = try placesFile.load([SavedPlace].self) { saved in
                guard Set(saved.map(\.id)).count == saved.count,
                      saved.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          $0.latitude.isFinite && $0.longitude.isFinite &&
                          (-85.0511...85.0511).contains($0.latitude) && (-180...180).contains($0.longitude)
                      }) else { throw CocoaError(.fileReadCorruptFile) }
            } ?? []
        } catch { self.error = "Saved places could not be read. The original file is preserved. \(error.localizedDescription)" }
    }
    private func openMap(_ url: URL) throws {
        let map = try RasterArchive(url: url)
        archive = map; zoom = map.initialZoom; center = normalized(latitude: map.latitude, longitude: map.longitude)
    }
    private func importMap(_ url: URL) {
        guard !busy, pendingMap == nil else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let staging = root.appending(path: "\(UUID().uuidString).mbtiles")
            do {
                let name = try await Task.detached {
                    try RasterMBTilesDatabase.snapshotSelected(url, to: staging)
                    return try RasterMBTilesDatabase(url: staging).metadata["name"] ?? url.deletingPathExtension().lastPathComponent
                }.value
                pendingMap = PendingMap(url: staging, name: name)
            } catch { try? FileManager.default.removeItem(at: staging); self.error = error.localizedDescription }
        }
    }
    private func discardPendingMap() {
        if let pendingMap { try? FileManager.default.removeItem(at: pendingMap.url) }
        pendingMap = nil
    }
    private func installMap(_ staging: URL) {
        let destination = root.appending(path: "current.mbtiles")
        let backupName = ".previous-\(UUID().uuidString).mbtiles"
        let backup = root.appending(path: backupName)
        var replaced = false
        do {
            _ = try RasterArchive(url: staging) // Revalidate before replacing the saved map.
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging, backupItemName: backupName, options: .withoutDeletingBackupItem)
                replaced = true
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
            try openMap(destination)
            pendingMap = nil
            if replaced { try? FileManager.default.removeItem(at: backup) }
        } catch {
            let installationError = error
            if replaced {
                do {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: backup)
                    try openMap(destination)
                } catch {
                    self.error = "The map could not be installed or restored automatically. The prior map backup is preserved at \(backup.lastPathComponent). \(error.localizedDescription)"
                    discardPendingMap(); return
                }
            }
            discardPendingMap()
            self.error = installationError.localizedDescription
        }
    }
    @discardableResult private func savePlaces(_ updated: [SavedPlace]) -> Bool {
        do {
            try placesFile.save(updated); places = updated
            return true
        } catch { self.error = error.localizedDescription }
        return false
    }
}
