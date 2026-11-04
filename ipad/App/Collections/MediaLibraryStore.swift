import Foundation
import AVFoundation
import Observation

struct LocalMediaItem: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case audio, video }
    let id: UUID
    var title: String
    let fileName: String
    let importedAt: Date
    let bytes: Int64
    var duration: Double?
    var kind: Kind?
    var embeddedCaptionCount: Int?
    var position: Double = 0
    var completed = false
    var lastPlayedAt: Date?
    enum CodingKeys: String, CodingKey { case id, title, fileName, importedAt, bytes, duration, kind, embeddedCaptionCount, position, completed, lastPlayedAt }
    init(id: UUID, title: String, fileName: String, importedAt: Date = Date(), bytes: Int64,
         duration: Double? = nil, kind: Kind? = nil, embeddedCaptionCount: Int? = nil) {
        self.id = id; self.title = title; self.fileName = fileName; self.importedAt = importedAt; self.bytes = bytes
        self.duration = duration; self.kind = kind; self.embeddedCaptionCount = embeddedCaptionCount
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        fileName = try values.decode(String.self, forKey: .fileName); importedAt = try values.decode(Date.self, forKey: .importedAt)
        bytes = try values.decode(Int64.self, forKey: .bytes); duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind); embeddedCaptionCount = try values.decodeIfPresent(Int.self, forKey: .embeddedCaptionCount)
        position = try values.decodeIfPresent(Double.self, forKey: .position) ?? 0
        completed = try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }
    var progress: Double { guard let duration, duration > 0 else { return 0 }; return min(1, max(0, position / duration)) }
}

struct LocalMediaPlaylist: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var itemIDs: [UUID]
}

private struct MediaArchive: Codable {
    var version = 2
    var items: [LocalMediaItem]
    var playlists: [LocalMediaPlaylist]
    init(items: [LocalMediaItem] = [], playlists: [LocalMediaPlaylist] = []) { self.items = items; self.playlists = playlists }
    enum CodingKeys: String, CodingKey { case version, items, playlists }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        items = try values.decode([LocalMediaItem].self, forKey: .items)
        playlists = try values.decodeIfPresent([LocalMediaPlaylist].self, forKey: .playlists) ?? []
    }
}

struct LocalMediaMetadata: Sendable {
    let duration: Double
    let kind: LocalMediaItem.Kind
    let embeddedCaptionCount: Int
    static func read(_ url: URL) async throws -> Self {
        guard url.isFileURL, !["m3u8", "m3u", "pls", "url"].contains(url.pathExtension.lowercased()) else {
            throw CollectionStorage.StorageError.invalidDocument("Import a complete audio or video file, not a streaming playlist or internet shortcut.")
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard !tracks.isEmpty else { throw CollectionStorage.StorageError.invalidDocument("This file has no playable media tracks.") }
        for track in tracks {
            guard try await track.load(.isSelfContained) else {
                throw CollectionStorage.StorageError.invalidDocument("This media references data outside its file. Import a self-contained media file for offline playback.")
            }
        }
        let (playable, duration, protected) = try await asset.load(.isPlayable, .duration, .hasProtectedContent)
        let seconds = CMTimeGetSeconds(duration)
        guard playable, !protected, seconds.isFinite, seconds > 0 else {
            throw CollectionStorage.StorageError.invalidDocument("This iPad cannot play the file's codec, protection scheme, or duration. DRM-protected content is not supported.")
        }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let captions = try await asset.loadMediaSelectionGroup(for: .legible)?.options.count ?? 0
        return Self(duration: seconds, kind: videos.isEmpty ? .audio : .video, embeddedCaptionCount: captions)
    }
}

@MainActor @Observable
final class MediaLibraryStore {
    static let shared = MediaLibraryStore()
    private(set) var items: [LocalMediaItem] = []
    private(set) var playlists: [LocalMediaPlaylist] = []
    private(set) var working = false
    private(set) var activity = ""
    var error: String?
    private(set) var root: URL
    private let defaultSupport: URL?
    @ObservationIgnored private var manifest: LocalManifestFile
    private(set) var loaded = false
    var writable: Bool { manifest.isReady && loaded }
    init(rootURL: URL? = nil, supportDirectoryURL: URL? = nil) {
        let support = supportDirectoryURL ?? URL.applicationSupportDirectory
        defaultSupport = rootURL == nil ? support : nil
        let initialRoot = rootURL ?? support.appendingPathComponent("NOMAD/Collections/media", isDirectory: true)
        root = initialRoot
        manifest = LocalManifestFile(url: initialRoot.appendingPathComponent("library.json"))
        reload()
    }
    func reload() {
        guard !working else { return }
        loaded = false
        do {
            if let defaultSupport {
                let resolved = try CollectionStorageDirectory.directory(in: defaultSupport, components: ["NOMAD", "Collections", "media"])
                if resolved != root {
                    root = resolved
                    manifest = LocalManifestFile(url: resolved.appendingPathComponent("library.json"))
                }
            } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            let archive = try manifest.load(MediaArchive.self) { archive in
                guard [1, 2].contains(archive.version), archive.items.count <= 10_000, archive.playlists.count <= 100,
                      Set(archive.items.map(\.id)).count == archive.items.count, Set(archive.playlists.map(\.id)).count == archive.playlists.count else {
                    throw CollectionStorage.StorageError.invalidDocument("The media library format is invalid or exceeds its limits.")
                }
                let ids = Set(archive.items.map(\.id))
                guard archive.items.allSatisfy({ Self.valid($0) }), archive.playlists.allSatisfy({
                    !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 &&
                    Set($0.itemIDs).count == $0.itemIDs.count && Set($0.itemIDs).isSubset(of: ids)
                }) else { throw CollectionStorage.StorageError.invalidDocument("The saved media library contains invalid file references, progress, or playlists.") }
            } ?? MediaArchive()
            items = archive.items; playlists = archive.playlists
            try recoverDeletions()
            loaded = true
            error = nil
        } catch { self.error = "The saved media library could not be opened. Existing data has been preserved. \(error.localizedDescription)" }
    }
    func fileURL(_ item: LocalMediaItem) throws -> URL {
        guard Self.valid(item), items.contains(where: { $0.id == item.id && $0.fileName == item.fileName }) else {
            throw CollectionStorage.StorageError.invalidFileName
        }
        let url = root.appendingPathComponent(item.fileName)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CollectionStorage.StorageError.invalidDocument("The imported media file is missing or is not a regular local file.")
        }
        return url
    }
    func item(_ id: UUID) -> LocalMediaItem? { items.first { $0.id == id } }
    func importFiles(_ urls: [URL]) async {
        guard writable, !working else { return }
        working = true
        defer { working = false; activity = "" }
        var failures: [String] = []
        for (index, source) in urls.enumerated() {
            activity = "Importing \(index + 1) of \(urls.count): \(source.lastPathComponent)"
            let id = UUID(), suffix = String(source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(16))
            let filename = id.uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
            let destination = root.appendingPathComponent(filename)
            var copied = false
            do {
                guard items.count < 10_000 else { throw CollectionStorage.StorageError.invalidDocument("The media library accepts up to 10,000 files.") }
                try await Task.detached(priority: .userInitiated) { try CollectionStorage.copySelectedFile(source, to: destination) }.value
                copied = true
                let metadata = try await LocalMediaMetadata.read(destination)
                let bytes = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                let item = LocalMediaItem(id: id, title: source.deletingPathExtension().lastPathComponent, fileName: filename, bytes: bytes,
                    duration: metadata.duration, kind: metadata.kind, embeddedCaptionCount: metadata.embeddedCaptionCount)
                try persist(items + [item], playlists: playlists)
            } catch {
                if copied { try? FileManager.default.removeItem(at: destination) }
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n\n") }
    }
    func updateMetadata(_ id: UUID, metadata: LocalMediaMetadata) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard metadata.duration.isFinite, metadata.duration > 0, (0...1_000).contains(metadata.embeddedCaptionCount) else {
            throw CollectionStorage.StorageError.invalidDocument("Media metadata is invalid.")
        }
        if items[index].duration == metadata.duration && items[index].kind == metadata.kind && items[index].embeddedCaptionCount == metadata.embeddedCaptionCount { return }
        var next = items
        next[index].duration = metadata.duration; next[index].kind = metadata.kind; next[index].embeddedCaptionCount = metadata.embeddedCaptionCount
        next[index].position = min(next[index].position, metadata.duration)
        try persist(next, playlists: playlists)
    }
    func recordPlayback(_ id: UUID, position: Double, completed: Bool? = nil) throws {
        guard position.isFinite, position >= 0, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].position = min(position, next[index].duration ?? position)
        if let completed { next[index].completed = completed }
        next[index].lastPlayedAt = Date()
        try persist(next, playlists: playlists)
    }
    func resetProgress(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items; next[index].position = 0; next[index].completed = false; next[index].lastPlayedAt = nil
        try persist(next, playlists: playlists)
    }
    func savePlaylist(_ playlist: LocalMediaPlaylist) throws {
        guard !playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, playlist.title.count <= 120,
              Set(playlist.itemIDs).count == playlist.itemIDs.count, Set(playlist.itemIDs).isSubset(of: Set(items.map(\.id))) else {
            throw CollectionStorage.StorageError.invalidDocument("Give the playlist a name of up to 120 characters and select existing media without duplicates.")
        }
        var next = playlists
        if let index = next.firstIndex(where: { $0.id == playlist.id }) { next[index] = playlist }
        else { guard next.count < 100 else { throw CollectionStorage.StorageError.invalidDocument("The playlist limit is 100.") }; next.append(playlist) }
        try persist(items, playlists: next)
    }
    func deletePlaylist(_ id: UUID) throws { try persist(items, playlists: playlists.filter { $0.id != id }) }
    func delete(_ item: LocalMediaItem) throws {
        guard writable else { throw CollectionStorage.StorageError.invalidDocument("The saved media library must load successfully before files can be deleted.") }
        guard !working, items.contains(where: { $0.id == item.id && $0.fileName == item.fileName }), Self.valid(item) else { return }
        let file = root.appendingPathComponent(item.fileName), staging = root.appendingPathComponent(".delete-\(item.id)")
        var staged = false
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: staging); staged = true }
        let nextPlaylists = playlists.map { playlist in var next = playlist; next.itemIDs.removeAll { $0 == item.id }; return next }
        do { try persist(items.filter { $0.id != item.id }, playlists: nextPlaylists) }
        catch { if staged { try? FileManager.default.moveItem(at: staging, to: file) }; throw error }
        if staged { try FileManager.default.removeItem(at: staging) }
    }
    private func persist(_ next: [LocalMediaItem], playlists: [LocalMediaPlaylist]) throws {
        guard writable else { throw CollectionStorage.StorageError.invalidDocument("The saved media library must load successfully before it can be changed.") }
        try manifest.save(MediaArchive(items: next, playlists: playlists))
        items = next; self.playlists = playlists
    }
    private nonisolated static func valid(_ item: LocalMediaItem) -> Bool {
        let suffix = item.fileName.dropFirst(item.id.uuidString.count)
        return item.fileName.hasPrefix(item.id.uuidString) && (suffix.isEmpty || (suffix.hasPrefix(".") && suffix.count <= 17 && suffix.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })) &&
            !item.title.isEmpty && item.bytes >= 0 && item.position.isFinite && item.position >= 0 &&
            (item.duration == nil || (item.duration!.isFinite && item.duration! > 0)) &&
            (item.duration == nil || item.position <= item.duration!) &&
            (item.embeddedCaptionCount == nil || (0...1_000).contains(item.embeddedCaptionCount!))
    }
    private func recoverDeletions() throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.lastPathComponent.hasPrefix(".delete-") {
            guard let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) else { continue }
            if let item = item(id) {
                let original = root.appendingPathComponent(item.fileName)
                if !FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: url, to: original) }
                else { try FileManager.default.removeItem(at: url) }
            } else { try FileManager.default.removeItem(at: url) }
        }
    }
}
