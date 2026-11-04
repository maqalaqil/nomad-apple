import SwiftUI
#if canImport(NomadCore)
import NomadCore
#endif

struct LibraryMetadataView: View {
    let store: LibraryStore
    @State private var original: LibraryDocument
    @State private var title: String
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var message: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: LibraryStore, document: LibraryDocument) {
        self.store = store; _original = State(initialValue: document); _title = State(initialValue: document.title)
    }
    private var current: LibraryDocument? { store.documents.first { $0.id == original.id } }
    var body: some View {
        NavigationStack {
            Form {
                if let current {
                    Section("Display title") {
                        TextField("Title", text: $title)
                        Button("Save title") {
                            do {
                                try store.rename(original, title: title)
                                if let updated = self.current { original = updated; title = updated.title }
                                message = "Display title saved. The content file was not changed."
                            } catch { self.error = error.localizedDescription }
                        }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("Stored file") {
                        LabeledContent("Format", value: current.kind.label)
                        LabeledContent("Bytes", value: current.byteCount.formatted())
                        LabeledContent("Imported", value: current.importedAt.formatted())
                        Text(current.filename).font(.caption).textSelection(.enabled)
                        Text(current.indexingStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Check metadata and search index") {
                        Text("Recheck this registered file and rebuild its bounded PDF/text index. ZIM and EPUB keep their own reader indexes; their archive bytes are not scanned or copied. Failed reads preserve the previous record.").font(.footnote).foregroundStyle(.secondary)
                        Button("Recheck file / rebuild text index", systemImage: "arrow.clockwise") {
                            busy = true; message = nil
                            work = Task {
                                defer { busy = false }
                                do { try await store.refreshIndex(current); message = "File metadata and supported text index refreshed. Rebuild any semantic index to use changed passages." }
                                catch is CancellationError { message = "Recheck stopped. Previously saved data remains available." }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(busy)
                        if busy { ProgressView("Checking local file…"); Button("Cancel") { work?.cancel() } }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } else { ContentUnavailableView("File removed", systemImage: "doc", description: Text("This file is no longer registered in the library.")) }
            }
            .navigationTitle("File details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { work?.cancel() }
            .alert("File details", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

struct LibraryRescanView: View {
    let store: LibraryStore
    @State private var busy = false
    @State private var done = 0
    @State private var total = 0
    @State private var failures: [String] = []
    @State private var message = ""
    @State private var work: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                Text("Recheck the files already registered in this library and rebuild supported PDF/text search indexes. No files are imported, deleted or recopied. Archives keep their native reader indexes.")
                Text("Text extraction remains limited to 2 MiB / 400,000 characters and PDF extraction to 200 pages / 400,000 characters. Missing, unsafe, locked or unreadable files preserve their previous records and are reported below.").font(.footnote).foregroundStyle(.secondary)
                if busy {
                    ProgressView(value: Double(done), total: Double(max(1, total))) { Text("Checked \(done) of \(total)") }
                    Button("Stop recheck") { work?.cancel() }
                } else {
                    Button("Recheck \(store.documents.count) registered files", systemImage: "arrow.clockwise") { begin() }.disabled(store.documents.isEmpty)
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !failures.isEmpty { Section("Files needing attention") { ForEach(Array(failures.enumerated()), id: \.offset) { Text($0.element).font(.callout) } } }
        }
        .navigationTitle("Recheck Library")
        .onDisappear { work?.cancel() }
    }
    private func begin() {
        let documents = store.documents
        total = documents.count; done = 0; failures = []; message = ""; busy = true
        work = Task {
            defer { busy = false }
            for document in documents {
                if Task.isCancelled { message = "Stopped after \(done) files. Completed checks remain saved."; return }
                do { try await store.refreshIndex(document) }
                catch is CancellationError { message = "Stopped after \(done) files. Completed checks remain saved."; return }
                catch { failures.append("\(document.title): \(error.localizedDescription)") }
                done += 1
            }
            message = "Checked \(done) files; \(failures.count) need attention. Rebuild semantic indexes if any indexed passages changed."
        }
    }
}
