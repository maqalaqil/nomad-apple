import SwiftUI
import UniformTypeIdentifiers
#if canImport(NomadCore)
import NomadCore
#endif

@MainActor
struct BooksLibraryView: View {
    let store: LibraryStore
    @State private var importing = false
    @State private var busy = false
    @State private var query = ""
    @State private var selected: LibraryDocument?
    @State private var deleting: LibraryDocument?
    @State private var errorMessage: String?
    @State private var inspecting: LibraryDocument?
    private var books: [LibraryDocument] {
        let allBooks = store.documents.filter { $0.kind == .epub || $0.kind == .pdf }
        let hits = Set(store.search(query, documentIDs: Set(allBooks.map(\.id))).map(\.documentID))
        return allBooks.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || hits.contains($0.id)
        }
    }
    var body: some View {
        List {
            Section {
                Text("Read imported EPUB chapters and PDFs offline. EPUB text size, reading position, bookmarks and notes are saved on this iPad.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { importing = true } label: { Label("Import books from Files", systemImage: "plus.circle") }.disabled(busy)
                NavigationLink("Reading bookmarks and notes", destination: ReadingMarksView())
                if busy { ProgressView("Copying books to this iPad…") }
                if let error = store.lastError { Text(error).foregroundStyle(.red).font(.callout) }
            }
            Section("Your books") {
                ForEach(books) { book in
                    Button { selected = book } label: {
                        HStack(spacing: 14) {
                            Image(systemName: book.kind == .epub ? "book.closed" : "doc.richtext").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(book.title).font(.headline).foregroundStyle(.primary)
                                Text("\(book.kind.label) · \(ByteCountFormatter.string(fromByteCount: book.byteCount, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = book } }
                    .contextMenu { Button("File details / edit title", systemImage: "info.circle") { inspecting = book } }
                }
                if books.isEmpty { ContentUnavailableView(query.isEmpty ? "Your offline bookshelf" : "No matching books", systemImage: "books.vertical", description: Text("Import EPUB or PDF files to get started.")) }
            }
            Section {
                Text("DRM-protected books and format conversion are not supported. EPUB search here matches book titles; Find in chapter searches the open chapter. PDF text search uses the library index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Books")
        .searchable(text: $query, prompt: "Book title or PDF text")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                busy = true
                Task {
                    var failures: [String] = []
                    for url in urls { do { try await store.importFile(url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") } }
                    busy = false
                    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $selected) { book in DocumentPreview(document: book, url: store.fileURL(for: book)) }
        .sheet(item: $inspecting) { book in LibraryMetadataView(store: store, document: book) }
        .confirmationDialog("Delete this book from the iPad?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete book", role: .destructive) {
                guard let book = deleting else { return }
                do { try store.delete(book) } catch { errorMessage = error.localizedDescription }
                deleting = nil
            }
        } message: { Text(deleting?.title ?? "") }
        .alert("Books", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
