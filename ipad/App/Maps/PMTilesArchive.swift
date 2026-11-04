import Foundation
import Combine
import Darwin

enum PMTilesFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct PMTilesHeader: Codable, Equatable, Sendable {
    let tileType: UInt8
    let minZoom: UInt8
    let maxZoom: UInt8
    let minLongitude: Double
    let minLatitude: Double
    let maxLongitude: Double
    let maxLatitude: Double
    let centerLongitude: Double
    let centerLatitude: Double

    static func read(from url: URL) throws -> (header: PMTilesHeader, bytes: UInt64) {
        let (handle, size) = try PMTilesFileIO.openRegularFile(url)
        defer { try? handle.close() }
        return try read(from: handle, bytes: size)
    }

    fileprivate static func read(from handle: FileHandle, bytes size: UInt64) throws -> (header: PMTilesHeader, bytes: UInt64) {
        guard size >= 127 else { throw PMTilesFailure.message("Choose a complete PMTiles archive, at least 127 bytes long.") }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: 127) ?? Data()
        guard data.count == 127, String(decoding: data.prefix(7), as: UTF8.self) == "PMTiles", data[7] == 3 else {
            throw PMTilesFailure.message("This reader supports PMTiles version 3 archives. Convert older PMTiles files before importing.")
        }
        func u64(_ offset: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) } }
        func coordinate(_ offset: Int) -> Double {
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
            return Double(Int32(bitPattern: raw)) / 10_000_000
        }
        for offset in [8, 24, 40, 56] {
            let start = u64(offset), length = u64(offset + 8)
            guard start <= size, length <= size - start else {
                throw PMTilesFailure.message("This PMTiles archive is incomplete or has an invalid directory offset.")
            }
        }
        guard (1...2).contains(data[97]), (1...2).contains(data[98]) else {
            throw PMTilesFailure.message("This build supports uncompressed and gzip PMTiles. Brotli/Zstandard archives need conversion or another decompressor.")
        }
        guard (1...5).contains(data[99]), data[100] <= data[101], data[101] <= 26 else {
            throw PMTilesFailure.message("Unsupported tile format or zoom range in this PMTiles archive.")
        }
        let header = PMTilesHeader(tileType: data[99], minZoom: data[100], maxZoom: data[101], minLongitude: coordinate(102), minLatitude: coordinate(106), maxLongitude: coordinate(110), maxLatitude: coordinate(114), centerLongitude: coordinate(119), centerLatitude: coordinate(123))
        try header.validate()
        return (header, size)
    }

    fileprivate func validate() throws {
        guard (1...5).contains(tileType), minZoom <= maxZoom, maxZoom <= 26,
              (-180...180).contains(minLongitude), (-180...180).contains(maxLongitude),
              (-90...90).contains(minLatitude), (-90...90).contains(maxLatitude),
              (-90...90).contains(centerLatitude), (-180...180).contains(centerLongitude),
              minLatitude <= maxLatitude else {
            throw PMTilesFailure.message("This archive contains invalid geographic bounds.")
        }
    }
}

struct PMTilesArchive: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let byteCount: UInt64
    let header: PMTilesHeader
    let importedAt: Date
    var enabled: Bool
    var filename: String { id.uuidString.lowercased() + ".pmtiles" }
}

struct PMTilesSavedPlace: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var notes: String
    var latitude: Double
    var longitude: Double
    var color = "#cf632c"
}

struct PMTilesByteRange: Equatable {
    let start: UInt64
    let end: UInt64
    var count: Int { Int(end - start + 1) }

    static func parse(_ value: String?, fileSize: UInt64, limit: UInt64 = 32 * 1_024 * 1_024) throws -> PMTilesByteRange {
        guard fileSize > 0, let value, value.hasPrefix("bytes="), !value.contains(",") else {
            throw PMTilesFailure.message("A single byte range is required for a PMTiles read.")
        }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw PMTilesFailure.message("Invalid byte range.") }
        let start: UInt64, end: UInt64
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { throw PMTilesFailure.message("Invalid suffix range.") }
            start = fileSize - min(fileSize, suffix); end = fileSize - 1
        } else {
            guard let first = UInt64(parts[0]), first < fileSize else { throw PMTilesFailure.message("Byte range starts outside the file.") }
            start = first
            if parts[1].isEmpty { end = fileSize - 1 }
            else {
                guard let last = UInt64(parts[1]), last >= start else { throw PMTilesFailure.message("Invalid byte range end.") }
                end = min(last, fileSize - 1)
            }
        }
        guard end - start + 1 <= limit else { throw PMTilesFailure.message("This map requested a data chunk larger than 32 MB.") }
        return PMTilesByteRange(start: start, end: end)
    }
}

/// Opens a fixed-size regular file without following a last-component symbolic
/// link. Archive reads/copies never materialize the whole archive in memory.
enum PMTilesFileIO {
    static let copyChunkBytes = 4 * 1_024 * 1_024
    static let storageReserve: UInt64 = 512 * 1_024 * 1_024

    static func openRegularFile(_ url: URL) throws -> (FileHandle, UInt64) {
        guard url.isFileURL else { throw PMTilesFailure.message("Choose a local PMTiles file from Files.") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else {
            try? handle.close()
            throw PMTilesFailure.message("Choose a regular file, not a folder or symbolic link.")
        }
        return (handle, UInt64(metadata.st_size))
    }

    static func requireCapacity(for bytes: UInt64, in directory: URL, provider: (@Sendable () -> Int64)?) throws {
        let free: Int64
        if let provider { free = provider() }
        else if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { free = available }
        else if let available = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber { free = available.int64Value }
        else { throw PMTilesFailure.message("Available storage could not be checked. Try again before importing this archive.") }
        let (required, overflow) = bytes.addingReportingOverflow(storageReserve)
        guard !overflow, free >= 0, UInt64(free) >= required else {
            let amount = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
            throw PMTilesFailure.message("Import needs another \(amount) of free storage plus 512 MB reserve. The source archive is kept. Free space or remove an unused download before trying again.")
        }
    }

    static func copySelected(_ source: URL, to staging: URL, in directory: URL,
                             capacityProvider: (@Sendable () -> Int64)?) throws -> (header: PMTilesHeader, bytes: UInt64) {
        guard source.isFileURL else { throw PMTilesFailure.message("Choose a local PMTiles file from Files.") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        // Check before coordination as well: some providers materialize a cloud
        // file during coordination, which can itself consume substantial space.
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PMTilesFailure.message("Choose a regular file, not a folder or symbolic link.")
        }
        if let size = attributes[.size] as? NSNumber { try requireCapacity(for: size.uint64Value, in: directory, provider: capacityProvider) }
        var coordinationError: NSError?
        var outcome: Result<(header: PMTilesHeader, bytes: UInt64), Error>?
        var ownsStaging = false
        var completed = false
        defer { if ownsStaging && !completed { try? FileManager.default.removeItem(at: staging) } }
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinated in
            outcome = Result {
                try Task.checkCancellation()
                let (input, expectedBytes) = try openRegularFile(coordinated)
                defer { try? input.close() }
                let original = try PMTilesHeader.read(from: input, bytes: expectedBytes)
                try requireCapacity(for: expectedBytes, in: directory, provider: capacityProvider)
                let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                ownsStaging = true
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? output.close() }
                try input.seek(toOffset: 0)
                var copied: UInt64 = 0
                while copied < expectedBytes {
                    try Task.checkCancellation()
                    let count = Int(min(UInt64(copyChunkBytes), expectedBytes - copied))
                    // Drain bridged Foundation objects on each chunk, including
                    // on worker threads without an outer AppKit/UIKit run loop.
                    let written = try autoreleasepool {
                        let chunk = try input.read(upToCount: count) ?? Data()
                        guard !chunk.isEmpty else { throw PMTilesFailure.message("The source archive became shorter during import.") }
                        try output.write(contentsOf: chunk)
                        return chunk.count
                    }
                    copied += UInt64(written)
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
                    throw PMTilesFailure.message("The source archive changed size during import.")
                }
                try output.synchronize()
                let result = try PMTilesHeader.read(from: staging)
                guard result.bytes == expectedBytes, result.header == original.header else {
                    throw PMTilesFailure.message("The archive copy could not be validated.")
                }
                return result
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw PMTilesFailure.message("The selected archive could not be coordinated for reading.") }
        let result = try outcome.get()
        completed = true
        return result
    }
}

@MainActor final class PMTilesStore: ObservableObject {
    static let shared = PMTilesStore()
    @Published private(set) var archives: [PMTilesArchive] = []
    @Published private(set) var places: [PMTilesSavedPlace] = []
    @Published private(set) var canWrite = false
    @Published var error: String?
    @Published var importing = false
    let directory: URL
    private var manifest: LocalManifestFile
    private var lastSaved: State?
    private let capacityProvider: (@Sendable () -> Int64)?
    private static var activeImports = Set<UUID>()

    private struct State: Codable, Equatable { var archives: [PMTilesArchive]; var places: [PMTilesSavedPlace] }

    init(directoryURL: URL? = nil, availableBytesProvider: (@Sendable () -> Int64)? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = directoryURL ?? support.appendingPathComponent("NomadPad/PMTiles", isDirectory: true)
        manifest = LocalManifestFile(url: directory.appendingPathComponent("workspace.json"))
        capacityProvider = availableBytesProvider
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PMTilesFailure.message("Map storage is not a regular directory.") }
            let saved = try manifest.load(State.self, validate: Self.validate)
            if saved == nil {
                let existing = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard !existing.contains(where: { $0.pathExtension == "pmtiles" }) else {
                    throw PMTilesFailure.message("The workspace file is missing but map archives remain. Restore the workspace before importing or deleting maps.")
                }
            }
            lastSaved = saved
            // A staged deletion before an interrupted manifest save is restored;
            // after a committed save its remaining bytes can be safely removed.
            try recoverDeletions(referencedBy: saved?.archives ?? [])
            for archive in saved?.archives ?? [] {
                let inspected = try PMTilesHeader.read(from: fileURL(for: archive))
                guard inspected.bytes == archive.byteCount, inspected.header == archive.header else {
                    throw PMTilesFailure.message("Saved archive \(archive.name) is missing, incomplete, or changed. Its workspace entry has been preserved.")
                }
            }
            // Interrupted, unpublished copies have no library entry and their
            // source was never moved. Keep copies still active in another view.
            try cleanInterruptedImports()
            archives = saved?.archives ?? []
            places = saved?.places ?? []
            canWrite = true
        } catch {
            self.error = "Could not open map storage. Existing workspace and map files have been preserved: \(error.localizedDescription)"
        }
    }

    func fileURL(for archive: PMTilesArchive) -> URL { directory.appendingPathComponent(archive.filename) }
    private func deletionURL(_ id: UUID) -> URL { directory.appendingPathComponent(".delete-\(id.uuidString.lowercased()).pmtiles") }

    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        guard canWrite else { error = Self.protectedMessage; return }
        importing = true
        error = nil
        defer { importing = false }
        for source in urls {
            _ = await importOne(source)
            if Task.isCancelled || !canWrite { break }
        }
    }

    /// Only for completed, verified, immutable downloads inside the app-owned
    /// sourceRoot. A URL from the user's Files picker must use importFiles.
    /// A hardlink retains the download's bytes independently if either library
    /// entry is later removed; neither module may modify those bytes in place.
    @discardableResult
    func importDownloadedFile(_ source: URL, sourceRoot: URL, expectedBytes: UInt64, name: String? = nil) async -> Bool {
        guard !importing else { error = "Another map import is already running."; return false }
        guard canWrite else { error = Self.protectedMessage; return false }
        guard expectedBytes >= 127, expectedBytes <= UInt64(Int64.max) else { error = "The completed download has an invalid size."; return false }
        importing = true
        error = nil
        defer { importing = false }
        return await importOne(source, downloadRoot: sourceRoot, expectedBytes: expectedBytes, name: name)
    }

    private func importOne(_ source: URL, downloadRoot: URL? = nil, expectedBytes: UInt64? = nil, name: String? = nil) async -> Bool {
        let id = UUID()
        let destination = directory.appendingPathComponent(id.uuidString.lowercased() + ".pmtiles")
        let staging = directory.appendingPathComponent(".import-\(id.uuidString.lowercased())")
        Self.activeImports.insert(id)
        var ownsStaging = false
        var ownsDestination = false
        var committed = false
        defer {
            Self.activeImports.remove(id)
            if ownsStaging { try? FileManager.default.removeItem(at: staging) }
            if ownsDestination && !committed { try? FileManager.default.removeItem(at: destination) }
        }
        do {
            try Task.checkCancellation()
            guard canWrite else { throw PMTilesFailure.message(Self.protectedMessage) }
            let directory = self.directory, provider = capacityProvider
            let worker = Task.detached(priority: .userInitiated) {
                if let downloadRoot, let expectedBytes {
                    try PMTilesFileIO.requireCapacity(for: 0, in: directory, provider: provider)
                    if try InternalDownloadLink.stage(source: source, sourceRoot: downloadRoot, destination: staging, expectedBytes: expectedBytes) {
                        do {
                            let linked = try PMTilesHeader.read(from: staging)
                            guard linked.bytes == expectedBytes else { throw PMTilesFailure.message("The completed download changed size.") }
                            return linked
                        } catch { try? FileManager.default.removeItem(at: staging); throw error }
                    }
                    // Unsupported filesystem/link policy: ordinary external-safe
                    // copy still checks for another full archive plus reserve.
                }
                let copied = try PMTilesFileIO.copySelected(source, to: staging, in: directory, capacityProvider: provider)
                if let expectedBytes, copied.bytes != expectedBytes {
                    try? FileManager.default.removeItem(at: staging)
                    throw PMTilesFailure.message("The completed download changed size.")
                }
                return copied
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            ownsStaging = true
            try Task.checkCancellation()
            let archive = PMTilesArchive(id: id, name: name ?? source.deletingPathExtension().lastPathComponent, byteCount: result.bytes, header: result.header, importedAt: Date(), enabled: true)
            try FileManager.default.moveItem(at: staging, to: destination)
            ownsStaging = false
            ownsDestination = true
            try commit(State(archives: archives + [archive], places: places))
            committed = true
            return true
        } catch {
            self.error = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = archives.firstIndex(where: { $0.id == id }) else { return }
        var candidate = archives; candidate[index].enabled = enabled
        persist(State(archives: candidate, places: places))
    }

    func remove(_ archive: PMTilesArchive) {
        guard canWrite else { error = Self.protectedMessage; return }
        guard archives.contains(where: { $0.id == archive.id }) else { return }
        let original = fileURL(for: archive), staged = deletionURL(archive.id)
        var moved = false
        do {
            // Rename preserves every byte; deletion happens only after metadata
            // is durable. On a failed save, restore the original path.
            _ = try PMTilesHeader.read(from: original)
            try FileManager.default.moveItem(at: original, to: staged)
            moved = true
            try commit(State(archives: archives.filter { $0.id != archive.id }, places: places))
        } catch {
            if moved {
                do { try FileManager.default.moveItem(at: staged, to: original) }
                catch { self.error = "Map deletion was interrupted. All bytes remain in \(staged.lastPathComponent); reopen the map library to restore them. \(error.localizedDescription)"; canWrite = false; return }
            }
            self.error = "Could not delete map; its bytes were preserved: \(error.localizedDescription)"
            return
        }
        do { try FileManager.default.removeItem(at: staged) }
        catch { self.error = "The map was removed from the library, but its stored bytes could not be cleaned up. Reopen the map library to retry cleanup. \(error.localizedDescription)" }
    }

    func addPlace(name: String, notes: String, latitude: Double, longitude: Double) {
        let place = PMTilesSavedPlace(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved place" : name, notes: notes, latitude: latitude, longitude: longitude)
        persist(State(archives: archives, places: places + [place]))
    }

    func removePlace(_ id: UUID) { persist(State(archives: archives, places: places.filter { $0.id != id })) }

    private static let protectedMessage = "Map storage could not be read or saved safely. Reopen the map library after restoring its workspace; the original files have been preserved."

    private static func validate(_ state: State) throws {
        guard state.archives.count <= 10_000, state.places.count <= 100_000,
              Set(state.archives.map(\.id)).count == state.archives.count,
              Set(state.places.map(\.id)).count == state.places.count else {
            throw PMTilesFailure.message("Map workspace contains duplicate identifiers or too many entries.")
        }
        for archive in state.archives {
            guard archive.byteCount >= 127, archive.byteCount <= UInt64(Int64.max), archive.name.utf8.count <= 1_024 else {
                throw PMTilesFailure.message("Map workspace contains an invalid archive size or name.")
            }
            try archive.header.validate()
        }
        for place in state.places {
            guard (-90...90).contains(place.latitude), (-180...180).contains(place.longitude),
                  place.name.utf8.count <= 1_024, place.notes.utf8.count <= 64 * 1_024,
                  place.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                throw PMTilesFailure.message("Saved places need valid coordinates, a name up to 1 KB, and notes up to 64 KB.")
            }
        }
    }

    private func commit(_ candidate: State) throws {
        guard canWrite else { throw PMTilesFailure.message(Self.protectedMessage) }
        try Self.validate(candidate)
        do {
            // A second map screen/import may have changed the file while a large
            // copy was running. Do not replace its newer data with our snapshot.
            let current = try manifest.load(State.self, validate: Self.validate)
            guard current == lastSaved else { throw PMTilesFailure.message("The map workspace changed in another screen. Reopen it before making more changes.") }
            try manifest.save(candidate)
        } catch { canWrite = false; throw error }
        lastSaved = candidate
        archives = candidate.archives
        places = candidate.places
    }

    private func persist(_ candidate: State) {
        do { try commit(candidate) }
        catch { self.error = "Could not save map state: \(error.localizedDescription)" }
    }

    private func recoverDeletions(referencedBy archives: [PMTilesArchive]) throws {
        let referenced = Set(archives.map(\.id))
        for staged in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = staged.lastPathComponent
            guard name.hasPrefix(".delete-"), name.hasSuffix(".pmtiles"),
                  let id = UUID(uuidString: String(name.dropFirst(8).dropLast(8))),
                  staged.lastPathComponent == deletionURL(id).lastPathComponent else { continue }
            let (handle, _) = try PMTilesFileIO.openRegularFile(staged); try handle.close()
            if referenced.contains(id) {
                let original = directory.appendingPathComponent(id.uuidString.lowercased() + ".pmtiles")
                guard !FileManager.default.fileExists(atPath: original.path) else { throw PMTilesFailure.message("A map deletion has two saved copies. Preserve both and repair the workspace before continuing.") }
                try FileManager.default.moveItem(at: staged, to: original)
            } else {
                try FileManager.default.removeItem(at: staged)
            }
        }
    }

    private func cleanInterruptedImports() throws {
        for staged in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = staged.lastPathComponent
            guard name.hasPrefix(".import-"), let id = UUID(uuidString: String(name.dropFirst(8))),
                  name == ".import-\(id.uuidString.lowercased())", !Self.activeImports.contains(id) else { continue }
            let (handle, _) = try PMTilesFileIO.openRegularFile(staged); try handle.close()
            try FileManager.default.removeItem(at: staged)
        }
    }
}
