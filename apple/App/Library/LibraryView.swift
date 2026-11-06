import SwiftUI
import UniformTypeIdentifiers
#if canImport(NomadCore)
import NomadCore
#endif

@MainActor
struct LibraryView: View {
    let store: LibraryStore
    @State private var query = ""
    @State private var showingImporter = false
    @State private var selectedDocument: LibraryDocument?
    @State private var pendingDelete: LibraryDocument?
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var importProgress: String?
    @State private var inspecting: LibraryDocument?

    private var results: [SearchHit] { store.search(query) }

    var body: some View {
        List {
            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let importProgress {
                Section {
                    HStack { ProgressView(); Text(importProgress) }
                }
            }
            Section {
                Label("Imported files are stored on this device and available without internet.", systemImage: "internaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if store.documents.isEmpty {
                    ContentUnavailableView {
                        Label("Your offline library", systemImage: "books.vertical")
                    } description: {
                        Text("Import books, PDFs, text, or Markdown to read locally, or explore the included samples.")
                    } actions: {
                        Button("Try sample library", systemImage: "books.vertical") {
                            Task { await importSamples() }
                        }
                        .disabled(importProgress != nil)
                        .accessibilityIdentifier("library.importSamples")
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Section("\(store.documents.count) saved files") {
                        ForEach(store.documents) { document in
                            Button { selectedDocument = document } label: { documentRow(document) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { requestDelete(document) }
                                }
                                .contextMenu {
                                    Button("File details / edit title", systemImage: "info.circle") { inspecting = document }
                                    ShareLink(item: store.fileURL(for: document)) { Label("Export file", systemImage: "square.and.arrow.up") }
                                    Button("Delete local copy", role: .destructive) { requestDelete(document) }
                                }
                        }
                    }
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Section("Matching passages and filenames") {
                    ForEach(results) { hit in
                        Button {
                            selectedDocument = store.documents.first { $0.id == hit.documentID }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(hit.documentTitle).font(.headline).foregroundStyle(.primary)
                                Text(hit.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section {
                Text("Search includes filenames and extracted PDF/text passages. PDF indexing is limited to 200 pages or 400,000 characters; text indexing to 2 MB or 400,000 characters. Open a ZIM archive to search its articles or an EPUB to read its chapters. Use GGUF models to import and run an AI model.")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Recheck library metadata and text indexes", destination: LibraryRescanView(store: store))
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search files and passages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingImporter = true } label: { Label("Import", systemImage: "plus") }
                    .disabled(importProgress != nil)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    var failures: [String] = []
                    for (index, url) in urls.enumerated() {
                        importProgress = "Importing \(index + 1) of \(urls.count): \(url.lastPathComponent)"
                        // LibraryStore balances security-scoped access for the entire asynchronous copy.
                        do { try await store.importFile(url) }
                        catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                    importProgress = nil
                    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $selectedDocument) { document in
            DocumentPreview(document: document, url: store.fileURL(for: document))
                .presentationSizing(.page)
        }
        .sheet(item: $inspecting) { document in LibraryMetadataView(store: store, document: document) }
        .confirmationDialog("Delete this local copy?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            if let document = pendingDelete {
                Button("Delete \(document.title)", role: .destructive) {
                    do { try store.delete(document) }
                    catch { errorMessage = error.localizedDescription }
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file and its search index will be removed from this library. The original imported file is unaffected.")
        }
        .alert("Library error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func importSamples() async {
        let names = ["A library that travels.txt", "Weekend notebook.txt", "A Library That Travels.epub"]
        let urls = names.compactMap { Bundle.main.url(forResource: $0, withExtension: nil, subdirectory: "SampleLibrary") }
        guard urls.count == names.count else {
            errorMessage = "The sample library is missing from this installation. You can still import your own files."
            return
        }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            importProgress = "Preparing sample \(index + 1) of \(urls.count)"
            do { try await store.importFile(url) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        importProgress = nil
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
    }

    private func requestDelete(_ document: LibraryDocument) {
        pendingDelete = document
        showingDeleteConfirmation = true
    }

    private func documentRow(_ document: LibraryDocument) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol(for: document.kind)).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title).font(.headline)
                Text("\(document.kind.label) · \(ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(document.indexingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 5)
    }

    private func symbol(for kind: DocumentKind) -> String {
        switch kind {
        case .pdf: "doc.richtext"
        case .text, .markdown: "doc.text"
        case .zim: "books.vertical"
        case .epub: "book.closed"
        case .model: "cpu"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .other: "doc"
        }
    }
}
