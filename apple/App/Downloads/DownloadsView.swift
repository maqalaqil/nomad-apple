import SwiftUI

struct DownloadsView: View {
    @Bindable var library: LibraryStore
    @State private var store = DownloadStore.shared
    @State private var adding = false
    @State private var url = ""
    @State private var checksum = ""
    @State private var error: String?
    @State private var removing: ContentDownload?
    @State private var importing: UUID?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Text("Download content before going offline. Transfers and verification run one at a time. Transfer, verification, and importing into a reader are separate steps.")
                    .foregroundStyle(.secondary)
                if let error = store.error { Text(error).foregroundStyle(.orange) }
                NavigationLink { CatalogDownloadsView() } label: { Label("Browse Wikipedia and map regions", systemImage: "books.vertical") }
                NavigationLink { OPDSCatalogsView() } label: { Label("Custom book catalogs · OPDS", systemImage: "books.vertical.circle") }
                Button("Add download", systemImage: "plus.circle") { adding = true }.disabled(!store.canWrite)
            }
            if store.items.isEmpty {
                ContentUnavailableView("Your download list is empty", systemImage: "arrow.down.circle", description: Text("Add a ZIM, map archive, model, course file, or another resource to prepare it locally."))
            }
            ForEach(store.items) { item in
                let expected = item.expectedBytes ?? item.expected
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(item.name).font(.headline).lineLimit(2)
                        Spacer()
                        Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    if item.state == .queued {
                        Text(expected > 0 ? "Waiting in queue · \(size(expected))" : "Waiting in queue · size not yet known").font(.caption).foregroundStyle(.secondary)
                    }
                    if item.state == .downloading {
                        if expected > 0 { ProgressView(value: Double(min(item.received, expected)), total: Double(expected)) }
                        else { ProgressView() }
                        Text("\(size(item.received)) of \(expected > 0 ? size(expected) : "unknown size")").font(.caption)
                    }
                    if item.state == .verifying { ProgressView("Checking local file…") }
                    if let message = item.message { Text(message).font(.caption).foregroundStyle(item.state == .failed ? Color.orange : Color.secondary) }
                    HStack {
                        if item.state == .downloading || item.state == .queued { Button("Pause") { store.pause(item.id) } }
                        if item.state == .paused || item.state == .failed { Button("Resume") { store.start(item.id) } }
                        if item.state == .ready {
                            ShareLink(item: store.fileURL(item)) { Label("Share or save file", systemImage: "square.and.arrow.up") }
                            if ["zim", "pdf", "txt", "md", "epub"].contains(store.fileURL(item).pathExtension) {
                                Button(importing == item.id ? "Importing…" : "Add to library") {
                                    importing = item.id
                                    Task {
                                        do {
                                            let file = try store.completedFile(item.id)
                                            try await library.importDownloadedFile(file.url, sourceRoot: file.sourceRoot, expectedBytes: file.expectedBytes, name: file.name)
                                            notice = "Added to the Knowledge Library. Open it there to check the content. Removing the download entry keeps the imported resource available."
                                        }
                                        catch { self.error = error.localizedDescription }
                                        importing = nil
                                    }
                                }.disabled(importing != nil)
                            }
                            if store.fileURL(item).pathExtension == "pmtiles" {
                                Button(importing == item.id ? "Importing…" : "Add to offline maps") {
                                    importing = item.id
                                    Task {
                                        do {
                                            let file = try store.completedFile(item.id)
                                            let maps = PMTilesStore.shared
                                            if await maps.importDownloadedFile(file.url, sourceRoot: file.sourceRoot, expectedBytes: file.expectedBytes, name: file.name) {
                                                notice = "Added to Offline Map Archives. Open Maps to check its coverage. Removing the download entry keeps the imported map available."
                                            } else { error = maps.error ?? "The map could not be imported." }
                                        } catch { self.error = error.localizedDescription }
                                        importing = nil
                                    }
                                }.disabled(importing != nil || PMTilesStore.shared.importing)
                            }
                            if store.fileURL(item).pathExtension == "gguf" {
                                Button(importing == item.id ? "Importing…" : "Add to local AI models") {
                                    importing = item.id
                                    Task {
                                        do {
                                            let file = try store.completedFile(item.id)
                                            let models = GGUFModelStore.shared
                                            guard !models.isBusy else { throw CatalogError.message("The local model engine is busy. Try importing again after it finishes.") }
                                            await models.importModel(file.url, name: file.name)
                                            if let message = models.error { error = message }
                                            else { notice = "Added \(file.name) to Local AI Models. Open that module to load and test the model on this device." }
                                        } catch { self.error = error.localizedDescription }
                                        importing = nil
                                    }
                                }.disabled(importing != nil || GGUFModelStore.shared.isBusy)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { removing = item }.disabled(item.state == .verifying || importing == item.id)
                    }.buttonStyle(.bordered)
                }.padding(.vertical, 8)
            }
            Section("Using the files") {
                Text("Use Add to library, Add to offline maps, or Add to local AI models on supported completed files. Library and PMTiles imports avoid duplicating downloaded archive bytes when the filesystem supports it. External file imports and other formats may need a full additional copy. Imported resources stay available when their download entries are removed; their storage is freed only after all retained copies are removed.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("For Education or Drug Reference, save the file with your file browser and use the module’s import control. Some formats need ZIP archives extracted first.").font(.footnote).foregroundStyle(.secondary)
                #if os(macOS)
                Text("Keep NOMAD running to verify completed transfers and advance the queue. macOS does not automatically relaunch this app when a background transfer finishes. After quitting, reopen NOMAD to reconnect saved transfers; resume any paused or failed items. New downloads need a connection. Completed content remains local.")
                    .font(.footnote).foregroundStyle(.secondary)
                #else
                Text("iOS and iPadOS control background transfers. Force-quitting the app can stop them; reopen it and resume interrupted downloads. New downloads need a connection. Completed content remains local.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    Section("Direct file URL") {
                        TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section("SHA-256 checksum, if published") {
                        TextField("Optional checksum", text: $checksum).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("A matching checksum confirms the file matches the publisher’s expected bytes. Without one, only transfer completion is checked.").font(.caption)
                    }
                }
                .navigationTitle("Download content")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download") {
                            do { try store.add(urlText: url, checksum: checksum); adding = false; url = ""; checksum = "" }
                            catch { self.error = error.localizedDescription }
                        }.disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Download needs attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .alert("Download needs attention", isPresented: Binding(get: { error != nil && !adding }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .alert("Content imported", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .confirmationDialog("Remove this download and its local downloaded file? Imported copies in other modules stay available.", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { if let removing { store.remove(removing.id) }; removing = nil }
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
