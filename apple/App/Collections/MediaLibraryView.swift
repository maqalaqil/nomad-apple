import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MediaLibraryView: View {
    @State private var store = MediaLibraryStore.shared
    @State private var importing = false
    @State private var playing: MediaPlaybackRequest?
    @State private var deleting: LocalMediaItem?
    @State private var editingPlaylist: LocalMediaPlaylist?
    @State private var query = ""
    private var visibleItems: [LocalMediaItem] {
        store.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted { $0.importedAt > $1.importedAt }
    }
    var body: some View {
        List {
            Section {
                Text("Imported media is stored on this device. Playback resumes from its saved position; reaching the end marks an item completed.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !store.writable { Button("Reload preserved media library") { store.reload() } }
                if store.working { HStack { ProgressView(); Text(store.activity).font(.subheadline) } }
            }
            Section("Playlists") {
                ForEach(store.playlists) { playlist in
                    NavigationLink { MediaPlaylistDetail(id: playlist.id, store: store) } label: {
                        Label("\(playlist.title) · \(playlist.itemIDs.count)", systemImage: "list.bullet")
                    }
                }
                Button("New playlist", systemImage: "text.badge.plus") { editingPlaylist = LocalMediaPlaylist(title: "", itemIDs: []) }.disabled(!store.writable)
            }
            Section("Imported media") {
                ForEach(visibleItems) { item in
                    Button { playing = MediaPlaybackRequest(itemIDs: [item.id], startID: item.id) } label: { MediaItemRow(item: item) }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = item }.disabled(store.working) }
                        .contextMenu {
                            Button("Reset playback progress", systemImage: "arrow.counterclockwise") { attempt { try store.resetProgress(item.id) } }
                            Menu("Add to playlist") {
                                ForEach(store.playlists) { playlist in
                                    Button(playlist.title) {
                                        var updated = playlist
                                        if !updated.itemIDs.contains(item.id) { updated.itemIDs.append(item.id) }
                                        attempt { try store.savePlaylist(updated) }
                                    }
                                }
                            }.disabled(store.playlists.isEmpty)
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }.disabled(store.working)
                        }
                }
                if visibleItems.isEmpty {
                    ContentUnavailableView(store.items.isEmpty ? "Your media library is empty" : "No matching media", systemImage: "play.rectangle",
                        description: Text("Import complete audio or video files from Files."))
                }
            }
            Section {
                Text("Playback depends on codecs supported by this device. Embedded captions and alternate audio use AVKit controls. DRM, streaming playlists, remote file references, external subtitle imports, and transcoding are not supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Media library")
        .searchable(text: $query, prompt: "Find imported media")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Import media", systemImage: "plus") { importing = true }.disabled(store.working || !store.writable) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audiovisualContent, .audio, .movie], allowsMultipleSelection: true) { result in
            do { let urls = try result.get(); Task { await store.importFiles(urls) } }
            catch { store.error = error.localizedDescription }
        }
        .sheet(item: $playing) { LocalMediaPlayer(store: store, request: $0) }
        .sheet(item: $editingPlaylist) { MediaPlaylistEditor(playlist: $0, store: store) }
        .confirmationDialog("Delete \(deleting?.title ?? "media")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete imported copy", role: .destructive) { if let item = deleting { attempt { try store.delete(item) } }; deleting = nil }
        } message: { Text("The local copy and playlist references are removed. The original file remains in Files.") }
        .alert("Media library", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func attempt(_ operation: () throws -> Void) { do { try operation() } catch { store.error = error.localizedDescription } }
}

private struct MediaItemRow: View {
    let item: LocalMediaItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .audio ? "music.note" : "play.rectangle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).foregroundStyle(.primary)
                Text("\(item.kind?.rawValue.capitalized ?? "Media") · \(item.duration.map(mediaTime) ?? "Duration available on playback") · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if item.completed { Label("Completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                else if item.position > 0 {
                    ProgressView(value: item.progress)
                    Text("Resume at \(mediaTime(item.position))").font(.caption).foregroundStyle(.secondary)
                }
                if let captions = item.embeddedCaptionCount, captions > 0 { Text("\(captions) embedded caption/subtitle options").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 4)
    }
}

private func mediaTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Unknown duration" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}

@MainActor
private struct MediaPlaylistDetail: View {
    let id: UUID
    let store: MediaLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var playing: MediaPlaybackRequest?
    @State private var editing: LocalMediaPlaylist?
    @State private var confirmingDelete = false
    private var playlist: LocalMediaPlaylist? { store.playlists.first { $0.id == id } }
    var body: some View {
        List {
            if let playlist {
                Section {
                    Button("Play playlist", systemImage: "play.fill") {
                        if let first = playlist.itemIDs.first { playing = MediaPlaybackRequest(itemIDs: playlist.itemIDs, startID: first) }
                    }.disabled(playlist.itemIDs.isEmpty)
                    Text("Items play in this order, resuming saved progress. Completed items start again from the beginning.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(playlist.itemIDs, id: \.self) { id in
                    if let item = store.item(id) {
                        Button { playing = MediaPlaybackRequest(itemIDs: playlist.itemIDs, startID: id) } label: { MediaItemRow(item: item) }
                    }
                }
                Button("Delete playlist", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(playlist?.title ?? "Playlist")
        .toolbar { Button("Edit") { editing = playlist } }
        .sheet(item: $playing) { LocalMediaPlayer(store: store, request: $0) }
        .sheet(item: $editing) { MediaPlaylistEditor(playlist: $0, store: store) }
        .confirmationDialog("Delete this playlist? Media files are kept.", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete playlist", role: .destructive) {
                do { try store.deletePlaylist(id); dismiss() } catch { store.error = error.localizedDescription }
            }
        }
    }
}

@MainActor
private struct MediaPlaylistEditor: View {
    @State var playlist: LocalMediaPlaylist
    let store: MediaLibraryStore
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { TextField("Playlist name", text: $playlist.title) }
                Section("Playback order") {
                    ForEach(playlist.itemIDs, id: \.self) { id in Text(store.item(id)?.title ?? "Removed media") }
                        .onDelete { playlist.itemIDs.remove(atOffsets: $0) }
                        .onMove { playlist.itemIDs.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Add media") {
                    ForEach(store.items.filter { !playlist.itemIDs.contains($0.id) }) { item in
                        Button(item.title, systemImage: "plus.circle") { playlist.itemIDs.append(item.id) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit playlist")
            #if !os(macOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { do { try store.savePlaylist(playlist); dismiss() } catch { self.error = error.localizedDescription } }
                        .disabled(playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
