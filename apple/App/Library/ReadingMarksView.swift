import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ReadingMarksView: View {
    var bookKey: String? = nil
    var onOpen: ((ReadingMark) -> Void)? = nil
    @State private var store = ReadingMarkStore.shared
    @State private var editing: ReadingMark?
    @State private var deleting: ReadingMark?
    @State private var error: String?
    @State private var exporting = false
    @State private var exportData = Data()
    @State private var query = ""
    private var marks: [ReadingMark] {
        let values = bookKey.map(store.forBook) ?? store.marks.sorted { $0.createdAt > $1.createdAt }
        return values.filter { query.isEmpty || [$0.title, $0.bookTitle, $0.quote, $0.note].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    var body: some View {
        List {
            Section {
                Text("Bookmarks and notes stay on this device. Locations use chapter and scroll position, so different text sizes may shift the exact line. Notes do not modify the EPUB or add permanent highlights.").font(.footnote).foregroundStyle(.secondary)
                if bookKey == nil { Text("Marks remain available here if a book is deleted. Reimported copies have a new book identity.").font(.caption).foregroundStyle(.secondary) }
            }
            if let message = store.error {
                Section { Text(message).foregroundStyle(.orange); Button("Reload saved marks") { store.reload() } }
            }
            ForEach(marks) { mark in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mark.title).font(.headline)
                        Text(mark.bookTitle).font(.caption).foregroundStyle(.secondary)
                        if !mark.quote.isEmpty { Text(mark.quote).font(.callout).textSelection(.enabled) }
                        if !mark.note.isEmpty { Text(mark.note).textSelection(.enabled) }
                        Text("\(mark.chapterPath) · \(Int(mark.fraction * 100))% of chapter").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if let onOpen { Button("Open location", systemImage: "book") { onOpen(mark) } }
                        Button("Edit note", systemImage: "square.and.pencil") { editing = mark }.disabled(!store.canWrite)
                        Spacer()
                        Button("Delete", role: .destructive) { deleting = mark }.disabled(!store.canWrite)
                    }.buttonStyle(.borderless)
                }
            }
            if marks.isEmpty { ContentUnavailableView("No matching reading marks", systemImage: "bookmark", description: Text("Open an EPUB and use Reading marks to bookmark a position or save a note.")) }
        }
        .navigationTitle("Reading marks")
        .searchable(text: $query, prompt: "Search notes and quotations")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Export JSON", systemImage: "square.and.arrow.up") {
            do { exportData = try store.export(bookKey: bookKey); exporting = true } catch { self.error = error.localizedDescription }
        }.disabled(!store.canWrite) } }
        .sheet(item: $editing) { mark in ReadingMarkEditor(mark: mark) }
        .fileExporter(isPresented: $exporting, document: ReadingMarksDocument(data: exportData), contentType: .json, defaultFilename: "reading-marks") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .confirmationDialog("Delete this saved reading mark?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete mark", role: .destructive) {
                do { if let deleting { try store.delete(deleting.id, expectedUpdatedAt: deleting.updatedAt) }; deleting = nil } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Reading marks", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

struct ReadingMarkEditor: View {
    @State var mark: ReadingMark
    private let expectedUpdatedAt: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    init(mark: ReadingMark) {
        _mark = State(initialValue: mark)
        expectedUpdatedAt = ReadingMarkStore.shared.marks.contains(where: { $0.id == mark.id }) ? mark.updatedAt : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    Text(mark.bookTitle)
                    Text("\(mark.chapterPath) · \(Int(mark.fraction * 100))% of chapter").font(.caption).foregroundStyle(.secondary)
                }
                Section("Title") { TextField("Bookmark or note title", text: $mark.title) }
                Section("Selected quotation, if any") { TextEditor(text: $mark.quote).frame(minHeight: 90).accessibilityLabel("Quotation") }
                Section("Your note") { TextEditor(text: $mark.note).frame(minHeight: 160).accessibilityLabel("Reading note") }
                Text("Title: 200 characters. Quotation: 4,000. Note: 8,000. The EPUB file is unchanged.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Save reading mark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do { mark.updatedAt = Date(); try ReadingMarkStore.shared.save(mark, expectedUpdatedAt: expectedUpdatedAt); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(mark.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ReadingMarkStore.shared.canWrite) }
            }
            .alert("Reading mark", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

private struct ReadingMarksDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor @Observable
final class EPUBReaderActions {
    private(set) var ready = false
    @ObservationIgnored private weak var webView: WKWebView?
    func attach(_ view: WKWebView) { webView = view; ready = true }
    func loading() { ready = false }
    func detach(_ view: WKWebView) { if webView === view { ready = false; webView = nil } }
    func find(_ query: String, backwards: Bool) async throws -> Bool {
        guard ready, let webView else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        let result = try await webView.find(query, configuration: configuration)
        return result.matchFound
    }
    func selectedText() async throws -> String {
        guard ready, let webView else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("return String(window.getSelection()?.toString() || '').slice(0,4000);", arguments: [:], in: nil,
                in: WKContentWorld.world(name: "org.projectnomad.epub-selection")) { result in
                switch result {
                case .success(let value): continuation.resume(returning: String((value as? String ?? "").prefix(4_000)))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}
