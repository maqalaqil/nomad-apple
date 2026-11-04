import Foundation
import AVFoundation

@main struct MediaRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadMediaRegression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("silent.wav")
        try wave(seconds: 2).write(to: source)
        let metadata = try await LocalMediaMetadata.read(source)
        precondition(abs(metadata.duration - 2) < 0.01 && metadata.kind == .audio)
        // Exercise the production default-root branch without touching app/user storage.
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames != false
        let historicRoot = support.appendingPathComponent(caseSensitive ? "NOMAD/Collections/media" : "Nomad/Collections/media", isDirectory: true)
        let seeded = MediaLibraryStore(rootURL: historicRoot)
        await seeded.importFiles([source])
        precondition(seeded.writable && seeded.items.count == 1 && seeded.error == nil)
        let seededItem = seeded.items[0]
        try seeded.recordPlayback(seededItem.id, position: 0.75)
        let historicManifest = historicRoot.appendingPathComponent("library.json")
        let beforeDefaultOpen = try Data(contentsOf: historicManifest)
        let actualDefault = MediaLibraryStore(supportDirectoryURL: support)
        precondition(actualDefault.writable && actualDefault.error == nil && actualDefault.root.path == historicRoot.path)
        precondition(actualDefault.items.count == 1 && actualDefault.item(seededItem.id)?.position == 0.75)
        let afterDefaultOpen = try Data(contentsOf: historicManifest)
        precondition(afterDefaultOpen == beforeDefaultOpen)
        let preservedMedia = try Data(contentsOf: seeded.fileURL(seededItem))
        try actualDefault.savePlaylist(LocalMediaPlaylist(title: "Existing-root queue", itemIDs: [seededItem.id]))
        let defaultReopened = MediaLibraryStore(supportDirectoryURL: support)
        precondition(defaultReopened.playlists.first?.title == "Existing-root queue" && defaultReopened.item(seededItem.id)?.position == 0.75)
        let afterDefaultMedia = try Data(contentsOf: defaultReopened.fileURL(seededItem))
        precondition(afterDefaultMedia == preservedMedia)
        let unsafeSupport = root.appendingPathComponent("UnsafeSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeSupport, withIntermediateDirectories: true)
        let rootLink = unsafeSupport.appendingPathComponent("NOMAD")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: historicRoot.deletingLastPathComponent().deletingLastPathComponent())
        let beforeBlockedOpen = try Data(contentsOf: historicManifest)
        let unsafeDefault = MediaLibraryStore(supportDirectoryURL: unsafeSupport)
        precondition(!unsafeDefault.writable && unsafeDefault.error != nil)
        do { try unsafeDefault.savePlaylist(LocalMediaPlaylist(title: "Refused", itemIDs: [])); fatalError("Wrote through symlink storage root") } catch {}
        let afterBlockedOpen = try Data(contentsOf: historicManifest)
        precondition(afterBlockedOpen == beforeBlockedOpen)
        try FileManager.default.removeItem(at: rootLink)
        unsafeDefault.reload()
        precondition(unsafeDefault.writable && unsafeDefault.items.isEmpty && unsafeDefault.error == nil)
        print("PASS: production default-root existing spelling, existing bytes/progress preserved, playlist reopen, symlink-root refusal and safe reload")

        let storage = root.appendingPathComponent("library")
        let store = MediaLibraryStore(rootURL: storage)
        await store.importFiles([source, source])
        precondition(store.writable && store.items.count == 2 && store.error == nil)
        let first = store.items[0], second = store.items[1]
        precondition(first.fileName != second.fileName)
        try store.recordPlayback(first.id, position: 0.5, completed: false)
        let playlist = LocalMediaPlaylist(title: "Offline queue", itemIDs: [first.id, second.id])
        try store.savePlaylist(playlist)
        let restored = MediaLibraryStore(rootURL: storage)
        precondition(restored.item(first.id)?.position == 0.5 && restored.playlists[0].itemIDs == playlist.itemIDs)
        // Exercise the actual AVPlayer seek and stop/save lifecycle against local silent audio.
        let player = MediaPlaybackSession(store: restored, request: MediaPlaybackRequest(itemIDs: [first.id], startID: first.id))
        player.start()
        try await wait { !player.preparing }
        precondition(player.error == nil && player.player != nil)
        player.pauseAndSave()
        let resumed = CMTimeGetSeconds(player.player!.currentTime())
        precondition(resumed >= 0.49 && resumed < 1.2)
        player.close()
        let reopened = MediaLibraryStore(rootURL: storage)
        precondition((reopened.item(first.id)?.position ?? 0) >= 0.49)
        // Actual end-of-file notification should mark completion and advance the ordered playlist.
        try reopened.recordPlayback(first.id, position: 1.7, completed: false)
        let queue = MediaPlaybackSession(store: reopened, request: MediaPlaybackRequest(itemIDs: playlist.itemIDs, startID: first.id))
        queue.start()
        try await wait { queue.index == 1 || queue.error != nil }
        precondition(queue.error == nil && queue.index == 1 && reopened.item(first.id)?.completed == true)
        queue.close()
        let afterQueue = MediaLibraryStore(rootURL: storage)
        precondition(afterQueue.item(first.id)?.completed == true)
        try afterQueue.resetProgress(first.id)
        precondition(afterQueue.item(first.id)?.position == 0 && afterQueue.item(first.id)?.completed == false)
        // Failed metadata writes must not change visible progress or delete the copied media.
        let manifest = storage.appendingPathComponent("library.json")
        let saved = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { try afterQueue.recordPlayback(first.id, position: 1); fatalError("Saved progress after failed write") } catch {}
        precondition(afterQueue.item(first.id)?.position == 0)
        do { try afterQueue.delete(first); fatalError("Deleted media after failed manifest write") } catch {}
        let copiedURL = try afterQueue.fileURL(first)
        precondition(FileManager.default.fileExists(atPath: copiedURL.path))
        try FileManager.default.removeItem(at: manifest); try saved.write(to: manifest)
        // A staged deletion interrupted before manifest commit is restored on launch.
        let staged = storage.appendingPathComponent(".delete-\(first.id)")
        try FileManager.default.moveItem(at: copiedURL, to: staged)
        let recovered = MediaLibraryStore(rootURL: storage)
        precondition(recovered.writable && FileManager.default.fileExists(atPath: copiedURL.path))
        try recovered.delete(first)
        precondition(recovered.items.count == 1 && recovered.playlists[0].itemIDs == [second.id])
        precondition(FileManager.default.fileExists(atPath: source.path))
        let corrupt = Data("{ preserve corrupt original".utf8)
        try corrupt.write(to: manifest)
        let blocked = MediaLibraryStore(rootURL: storage)
        precondition(!blocked.writable && blocked.error != nil)
        do { try blocked.savePlaylist(LocalMediaPlaylist(title: "Unsafe replacement", itemIDs: [])); fatalError("Overwrote corrupt metadata") } catch {}
        let unchanged = try Data(contentsOf: manifest)
        precondition(unchanged == corrupt)
        // The original version-one archive has no progress/metadata/playlist fields.
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        struct LegacyItem: Encodable { let id: UUID; let title: String; let fileName: String; let importedAt: Date; let bytes: Int64 }
        struct LegacyArchive: Encodable { let version = 1; let items: [LegacyItem] }
        let legacy = LegacyItem(id: UUID(), title: "Legacy media", fileName: "", importedAt: Date(), bytes: 10)
        let validLegacy = LegacyItem(id: legacy.id, title: legacy.title, fileName: "\(legacy.id).wav", importedAt: legacy.importedAt, bytes: legacy.bytes)
        try JSONEncoder().encode(LegacyArchive(items: [validLegacy])).write(to: legacyRoot.appendingPathComponent("library.json"))
        let migrated = MediaLibraryStore(rootURL: legacyRoot)
        precondition(migrated.writable && migrated.items.count == 1 && migrated.items[0].duration == nil && migrated.items[0].position == 0)
        try migrated.recordPlayback(legacy.id, position: 1)
        precondition(MediaLibraryStore(rootURL: legacyRoot).item(legacy.id)?.position == 1)
        print("PASS: real WAV metadata/import, independent copies, AVPlayer seek/resume, stop-save/relaunch, actual completion and playlist auto-next, reset, atomic progress/delete rollback, interrupted delete recovery, playlist pruning, corrupt history preservation, v1 migration")
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        fatalError("AVPlayer lifecycle timed out")
    }
    static func wave(seconds: Int) -> Data {
        let samples = seconds * 8_000, count = samples * 2
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); number(UInt32(36 + count)); ascii("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(8_000)); number(UInt32(16_000)); number(UInt16(2)); number(UInt16(16)); ascii("data"); number(UInt32(count))
        data.append(Data(count: count)); return data
    }
}
