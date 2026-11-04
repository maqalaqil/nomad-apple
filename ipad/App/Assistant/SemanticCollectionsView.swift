import SwiftUI

struct SemanticCollectionsView: View {
    @Bindable var library: LibraryStore
    @State private var store = SemanticIndexStore.shared
    @State private var language = "en"
    @State private var editing: KnowledgeCollection?
    @State private var deleting: KnowledgeCollection?
    @State private var error: String?
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searching = false
    private let languages = [("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Chinese", "zh-Hans")]

    var body: some View {
        Form {
            Section("Knowledge collections") {
                Text("With no collections, all imported documents are active. Once you create collections, only documents in enabled collections are used by the assistant. Deleted documents are always excluded.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(store.collections) { collection in
                    HStack {
                        Toggle(collection.name, isOn: Binding(get: { collection.enabled }, set: { value in
                            var updated = collection; updated.enabled = value
                            do { try store.saveCollection(updated) } catch { self.error = error.localizedDescription }
                        }))
                        Button("Edit") { editing = collection }
                        Button("Delete", role: .destructive) { deleting = collection }
                    }.disabled(!store.writable || store.busy)
                }
                Button("New collection", systemImage: "folder.badge.plus") { editing = KnowledgeCollection(name: "", documentIDs: []) }
                    .disabled(!store.writable || store.busy)
            }
            Section("On-device semantic index") {
                Text("Semantic retrieval finds related wording using Apple’s local sentence embeddings, then combines it with keyword matches. It indexes extracted PDF/text passages; ZIM archives keep their separate native search.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Document language", selection: $language) {
                    ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
                }.disabled(store.busy)
                Text("The selected system embedding must be available locally. This screen does not request a model download. Choose a language that matches your documents.")
                    .font(.caption).foregroundStyle(.secondary)
                if let snapshot = store.snapshot {
                    LabeledContent("Indexed passages", value: "\(snapshot.passages.count)")
                    LabeledContent("Index language / revision", value: "\(snapshot.language) / \(snapshot.revision)")
                    LabeledContent("Built", value: snapshot.createdAt.formatted())
                    Text("Rebuild after importing or changing collections. Search immediately excludes removed or disabled documents.").font(.caption)
                }
                if store.busy {
                    ProgressView("Indexing \(store.progress) of \(store.total) passages", value: Double(store.progress), total: Double(max(1, store.total)))
                    Button("Cancel indexing", role: .destructive) { store.cancel() }
                } else {
                    Button("Rebuild selected documents", systemImage: "arrow.triangle.2.circlepath") {
                        let selected = store.allowedDocuments(in: library)
                        store.rebuild(passages: library.retrievalPassages(documentIDs: selected, limit: 4_001), language: language)
                    }.disabled(!store.writable)
                }
                Text("This development index accepts up to 4,000 passages. Larger selections are rejected explicitly; extraction limits shown in the library still apply. Interrupted indexing preserves the previous index and can be restarted.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = store.message { Text(message).font(.caption) }
                if let error = store.error { Text(error).foregroundStyle(.orange) }
                if !store.writable { Button("Reload saved index") { store.reload() } }
            }
            Section("Test retrieval") {
                TextField("Search by meaning", text: $query)
                Button(searching ? "Searching…" : "Search index") {
                    searching = true
                    Task {
                        defer { searching = false }
                        do { results = Array(try await store.search(query, library: library, semantic: true).prefix(6)) }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(searching || store.busy || store.snapshot == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(results) { hit in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(hit.documentTitle).font(.headline)
                        Text(hit.excerpt).font(.subheadline).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
            }
        }
        .sheet(item: $editing) { collection in KnowledgeCollectionEditor(collection: collection, library: library, store: store) }
        .confirmationDialog("Delete this collection? Its documents remain in the library.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete collection", role: .destructive) {
                if let deleting { do { try store.deleteCollection(deleting.id) } catch { self.error = error.localizedDescription } }
                deleting = nil
            }
        }
        .alert("Knowledge collections", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct KnowledgeCollectionEditor: View {
    @State var collection: KnowledgeCollection
    let library: LibraryStore
    let store: SemanticIndexStore
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection name", text: $collection.name)
                Section("Documents") {
                    ForEach(library.documents) { document in
                        Toggle(document.title, isOn: Binding(get: { collection.documentIDs.contains(document.id) }, set: { on in
                            if on { collection.documentIDs.insert(document.id) } else { collection.documentIDs.remove(document.id) }
                        }))
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Knowledge collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.saveCollection(collection); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled()
        }
    }
}
