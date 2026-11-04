import SwiftUI
import UniformTypeIdentifiers
#if canImport(NomadCore)
import NomadCore
#endif

@MainActor
struct NotesView: View {
    @State private var store = NotesStore()
    @State private var query = ""
    @State private var editingNote: LocalNote?
    @State private var pendingDelete: LocalNote?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var importing = false
    @State private var readingImport = false
    @State private var pendingImport: NotesImportPreview?
    @State private var exporting = false
    @State private var exportDocument = NoteExportDocument(data: Data())
    @State private var exportType = UTType.json
    @State private var exportName = "nomad-notes"
    @State private var showingHelp = false
    @State private var showingTrash = false
    @AppStorage("notes.sort") private var sort = "modified"
    @AppStorage("notes.homeQuery") private var homeQuery = ""
    @State private var appliedHome = false

    private var searchResult: Result<[LocalNote], Error> { Result { try store.search(query) } }
    private var filteredNotes: [LocalNote] {
        guard case .success(let values) = searchResult else { return [] }
        switch sort {
        case "title": return values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "created": return values.sorted { $0.createdAt > $1.createdAt }
        default: return values
        }
    }

    var body: some View {
        List {
            if let error = store.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if readingImport { ProgressView("Reading notes…") }
            if case .failure(let error) = searchResult {
                Label(error.localizedDescription, systemImage: "magnifyingglass").foregroundStyle(.orange)
            } else if store.notes.isEmpty {
                ContentUnavailableView("Your offline notebook", systemImage: "note.text",
                    description: Text("Write Markdown, add #tags, link [[Other notes]], or import text from Files."))
            } else if filteredNotes.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(filteredNotes) { note in
                    Button { editingNote = note } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(note.title).font(.headline).foregroundStyle(.primary)
                            Text(note.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            if !note.tags.isEmpty { Text(note.tags.prefix(12).map { "#" + $0 }.joined(separator: " ")).font(.caption).foregroundStyle(.tint) }
                            Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                        .swipeActions { Button("Move to trash", role: .destructive) { pendingDelete = note } }
                }
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $query, prompt: "Search text, #tags or title:")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editingNote = LocalNote() } label: { Label("New note", systemImage: "square.and.pencil") }.disabled(!store.canWrite)
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("Import Markdown or notes archive", systemImage: "square.and.arrow.down") { importing = true }.disabled(!store.canWrite || readingImport)
                    Button("Export notebook with trash (JSON)", systemImage: "square.and.arrow.up") { exportNotebook() }.disabled(!store.canWrite)
                    Button("Export active notes as Markdown folder", systemImage: "folder") { exportMarkdown() }.disabled(!store.canWrite || store.notes.isEmpty)
                    Button("Trash (\(store.trash.count))", systemImage: "trash") { showingTrash = true }
                    Menu("Tags") {
                        Button("Without tags") { query = "NOT tags:*" }
                        ForEach(store.allTags, id: \.self) { tag in Button("#" + tag) { query = "#" + tag } }
                    }.disabled(store.notes.isEmpty)
                    Picker("Sort notes", selection: $sort) {
                        Text("Recently edited").tag("modified"); Text("Recently created").tag("created"); Text("Title").tag("title")
                    }
                    Button("Use current search on opening Notes") { homeQuery = query; notice = "Saved this search as your Notes home view." }.disabled((try? NoteQuery(query)) == nil)
                    Button("Reload saved notebook", systemImage: "arrow.clockwise") { store.reload() }
                    Button("Markdown and search help", systemImage: "questionmark.circle") { showingHelp = true }
                } label: { Label("Notebook options", systemImage: "ellipsis.circle") }
            }
        }
        .onAppear { if !appliedHome { query = homeQuery; appliedHome = true } }
        .sheet(item: $editingNote) { note in NoteEditor(note: note, store: store) }
        .sheet(isPresented: $showingTrash) { NotesTrashView(store: store) }
        .sheet(isPresented: $showingHelp) { NotesHelpView() }
        .sheet(item: $pendingImport) { preview in
            NavigationStack {
                List {
                    Section("Ready to import") {
                        Text("\(preview.archive.notes.count) active notes and \(preview.archive.trash.count) trashed notes")
                        Text("Exact title/text duplicates are skipped. Different notes with matching identifiers become new copies. Existing notes are preserved.").foregroundStyle(.secondary)
                    }
                    ForEach(Array((preview.archive.notes + preview.archive.trash).prefix(100))) { note in Text(note.title) }
                    if preview.archive.notes.count + preview.archive.trash.count > 100 { Text("Showing the first 100 titles.").foregroundStyle(.secondary) }
                }.navigationTitle("Import notes")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pendingImport = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") {
                                do {
                                    let result = try store.importArchive(preview.archive)
                                    notice = "Imported \(result.added) notes; skipped \(result.skipped) identical notes."
                                    pendingImport = nil
                                } catch { errorMessage = error.localizedDescription; pendingImport = nil }
                            }
                        }
                    }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): readImports(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .confirmationDialog("Move this note to trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to trash", role: .destructive) {
                if let note = pendingDelete { do { try store.delete(note) } catch { errorMessage = error.localizedDescription } }
                pendingDelete = nil
            }
        } message: { Text("You can restore it from Notebook options → Trash. Nothing is automatically purged.") }
        .alert("Notes error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func exportNotebook() {
        do { exportDocument = NoteExportDocument(data: try store.exportArchive()); exportType = .json; exportName = "nomad-notes"; exporting = true }
        catch { errorMessage = error.localizedDescription }
    }
    private func exportMarkdown() {
        do {
            _ = try store.exportArchive() // Validate the current disk snapshot before exporting in-memory notes.
            exportDocument = NoteExportDocument(notes: store.notes); exportType = .folder; exportName = "Nomad Markdown Notes"; exporting = true
        } catch { errorMessage = error.localizedDescription }
    }
    private func readImports(_ urls: [URL]) {
        readingImport = true
        Task {
            defer { readingImport = false }
            do { pendingImport = NotesImportPreview(archive: try await Task.detached(priority: .userInitiated) { try NoteFileImport.read(urls) }.value) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NotesImportPreview: Identifiable { let id = UUID(); let archive: NotesArchive }

/// Provider access stays scoped until coordinated, bounded reads finish. Import confirmation performs the only write.
private enum NoteFileImport {
    static func read(_ urls: [URL]) throws -> NotesArchive {
        guard !urls.isEmpty, urls.count <= 1_000 else { throw NotesError.message("Import between 1 and 1,000 files at a time.") }
        var notes: [LocalNote] = [], trash: [LocalNote] = [], total = 0, ids = Set<UUID>()
        for url in urls {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let limit = url.pathExtension.lowercased() == "json" ? NotesArchive.maximumBytes : NotesArchive.maximumNoteBytes
            var coordinationError: NSError?, payload: Result<Data, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { local in
                payload = Result {
                    let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else { throw NotesError.message("The selected file is unsafe or too large: \(url.lastPathComponent)") }
                    let data = try Data(contentsOf: local)
                    guard data.count <= limit else { throw NotesError.message("The selected file grew beyond its import limit.") }; return data
                }
            }
            if let coordinationError { throw coordinationError }
            guard let payload else { throw NotesError.message("The file provider did not supply \(url.lastPathComponent).") }
            let data = try payload.get(); total += data.count
            guard total <= NotesArchive.maximumBytes else { throw NotesError.message("Import at most 64 MB of note text at a time.") }
            let archive = url.pathExtension.lowercased() == "json" ? try NotesArchive.decode(data) : NotesArchive(notes: [try NotesStore.markdownNote(data: data, filename: url.lastPathComponent)])
            for (values, isTrash) in [(archive.notes, false), (archive.trash, true)] {
                for note in values {
                    let value = ids.insert(note.id).inserted ? note : LocalNote(title: note.title, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt)
                    ids.insert(value.id); if isTrash { trash.append(value) } else { notes.append(value) }
                }
            }
        }
        let archive = NotesArchive(notes: notes, trash: trash); try archive.validate(); return archive
    }
}

private struct NoteExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .folder] }
    var data: Data
    var notes: [LocalNote]?
    init(data: Data) { self.data = data }
    init(notes: [LocalNote]) { self.notes = notes; self.data = Data() }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let notes else { return FileWrapper(regularFileWithContents: data) }
        var wrappers: [String: FileWrapper] = [:], names = Set<String>()
        for note in notes {
            let base = Self.basename(note.title)
            var name = base + ".md", index = 2
            while !names.insert(name.lowercased()).inserted { name = base + " (\(index)).md"; index += 1 }
            wrappers[name] = FileWrapper(regularFileWithContents: Data(note.body.utf8))
        }
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }
    static func basename(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        var value = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(100))
        while value.utf8.count > 180 { value.removeLast() }
        return value.isEmpty ? "Untitled" : value
    }
}

@MainActor
private struct NoteEditor: View {
    let store: NotesStore
    private let original: LocalNote
    private let editingExisting: Bool
    @State private var draft: LocalNote
    @State private var errorMessage: String?
    @State private var confirmingDiscard = false
    @State private var showingPreview = false
    @State private var exporting = false
    @State private var exportData = Data()
    @Environment(\.dismiss) private var dismiss

    init(note: LocalNote, store: NotesStore) {
        self.store = store; original = note; editingExisting = store.notes.contains { $0.id == note.id }; _draft = State(initialValue: note)
    }
    private var hasChanges: Bool { draft.title != original.title || draft.body != original.body }
    private var hasContent: Bool { !(draft.title + draft.body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("Title") { TextField("Note title", text: $draft.title) }
                Section {
                    Toggle("Preview Markdown", isOn: $showingPreview)
                    if showingPreview { NoteMarkdownPreview(markdown: draft.body, store: store) }
                    else { TextEditor(text: $draft.body).frame(minHeight: 320).font(.body.monospaced()).accessibilityLabel("Note text") }
                } header: { Text("Note") } footer: { Text("Saved locally when you tap Save. #tags are read from the text; code blocks are excluded. [[Note title]] links open matching notes.") }
                if !draft.tags.isEmpty { Section("Tags") { Text(draft.tags.map { "#" + $0 }.joined(separator: " ")) } }
                if hasContent {
                    Section {
                        Button("Export Markdown file", systemImage: "square.and.arrow.up") { exportData = Data(draft.body.utf8); exporting = true }
                        ShareLink(item: "\(draft.title)\n\n\(draft.body)") { Label("Share a text copy", systemImage: "square.and.arrow.up") }
                        if editingExisting {
                            Button("Save draft as a new copy", systemImage: "doc.on.doc") { saveCopy() }
                        }
                    } footer: { Text("Exports include the current draft. Markdown files keep the body unchanged and use the note title as their filename.") }
                }
            }
            .navigationTitle(original.title.isEmpty ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if hasChanges { confirmingDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try store.save(draft, replacing: editingExisting ? original : nil); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.disabled(!hasContent)
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }; Button("Keep editing", role: .cancel) {}
            }
            .alert("Could not save note", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Keep editing", role: .cancel) { errorMessage = nil }
                Button("Reload saved notebook") { store.reload(); errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .fileExporter(isPresented: $exporting, document: NoteExportDocument(data: exportData), contentType: UTType(filenameExtension: "md") ?? .plainText, defaultFilename: NoteExportDocument.basename(draft.title) + ".md") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
        }
    }
    private func saveCopy() {
        do { try store.save(LocalNote(title: draft.title + " (copy)", body: draft.body)); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct NotesTrashView: View {
    let store: NotesStore
    @State private var pendingDelete: LocalNote?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Trashed notes stay on this iPad and in notebook JSON exports until you permanently delete them.").foregroundStyle(.secondary) }
                if store.trash.isEmpty { ContentUnavailableView("Trash is empty", systemImage: "trash") }
                ForEach(store.trash) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(note.title).font(.headline); Text(note.body).lineLimit(3).foregroundStyle(.secondary)
                        HStack {
                            Button("Restore") { do { try store.restore(note) } catch { self.error = error.localizedDescription } }.buttonStyle(.bordered)
                            Button("Delete permanently", role: .destructive) { pendingDelete = note }.buttonStyle(.bordered)
                        }
                    }
                }
            }.navigationTitle("Notes trash")
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Permanently delete this note?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                    Button("Delete permanently", role: .destructive) { if let note = pendingDelete { do { try store.permanentlyDelete(note) } catch { self.error = error.localizedDescription } }; pendingDelete = nil }
                } message: { Text("This cannot be undone. Export a notebook archive first if you need another copy.") }
                .alert("Could not update trash", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

/// A native Markdown preview: no web view, embedded browser scripts, or remote image requests.
@MainActor
private struct NoteMarkdownPreview: View {
    let markdown: String
    let store: NotesStore
    @State private var wikiTitle: String?
    @State private var externalURL: URL?
    @Environment(\.openURL) private var openURL
    private var blocks: [NoteMarkdownBlock] { NoteMarkdownBlock.parse(String(markdown.prefix(120_000))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if markdown.count > 120_000 { Text("Preview shows the first 120,000 characters. The editor and export retain the complete note.").font(.caption).foregroundStyle(.orange) }
            if blocks.count > 1_000 { Text("Preview shows the first 1,000 text blocks. Export or edit to access the complete note.").font(.caption).foregroundStyle(.orange) }
            ForEach(Array(blocks.prefix(1_000).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text): inline(text).font(level == 1 ? .title : level == 2 ? .title2 : .headline)
                case .code(let code): ScrollView(.horizontal) { Text(code).font(.body.monospaced()).textSelection(.enabled).padding(10) }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .quote(let text): HStack { Rectangle().fill(.secondary).frame(width: 3); inline(text).foregroundStyle(.secondary) }
                case .list(let marker, let text): HStack(alignment: .top) { Text(marker).foregroundStyle(.secondary); inline(text) }
                case .rule: Divider()
                case .paragraph(let text): inline(text)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "nomad-note", let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value { wikiTitle = title }
                else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { externalURL = url }
                return .handled
            })
            .sheet(isPresented: Binding(get: { wikiTitle != nil }, set: { if !$0 { wikiTitle = nil } })) { NoteLinkedView(title: wikiTitle ?? "", store: store) }
            .confirmationDialog("Open this external link?", isPresented: Binding(get: { externalURL != nil }, set: { if !$0 { externalURL = nil } }), titleVisibility: .visible) {
                Button("Open link") { if let url = externalURL { openURL(url) }; externalURL = nil }
            } message: { Text(externalURL?.absoluteString ?? "External links may need an internet connection.") }
    }
    private func inline(_ source: String) -> Text {
        var value = source
        let regex = try! NSRegularExpression(pattern: "\\[\\[([^\\]\\n]{1,512})\\]\\]")
        // Leave code spans literal, including wikilink-looking text inside them.
        let codePattern = try! NSRegularExpression(pattern: "(`+)([\\s\\S]*?)\\1")
        let codeRanges = codePattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            if codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) { continue }
            guard let range = Range(match.range, in: value), let titleRange = Range(match.range(at: 1), in: source) else { continue }
            let title = String(source[titleRange])
            var url = URLComponents(); url.scheme = "nomad-note"; url.host = "lookup"; url.queryItems = [.init(name: "title", value: title)]
            let label = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            if let destination = url.url { value.replaceSubrange(range, with: "[\(label)](\(destination.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))") }
        }
        return Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
    }
}

@MainActor
private struct NoteLinkedView: View {
    let title: String
    let store: NotesStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                let matches = store.linkedNotes(title: title)
                if matches.isEmpty {
                    ContentUnavailableView("No matching note", systemImage: "link", description: Text("No active note is titled “\(title)”. The link is kept in your Markdown."))
                }
                if matches.count > 1 { Text("Several notes use this title. Choose the intended one.").foregroundStyle(.secondary) }
                ForEach(matches) { note in
                    NavigationLink { NoteLinkedReader(noteID: note.id, store: store) } label: {
                        VStack(alignment: .leading) { Text(note.title); Text(note.body).lineLimit(2).foregroundStyle(.secondary) }
                    }
                }
            }.navigationTitle(title).toolbar { Button("Done") { dismiss() } }
        }
    }
}

@MainActor
private struct NoteLinkedReader: View {
    let noteID: UUID
    let store: NotesStore
    @State private var editing: LocalNote?
    var body: some View {
        Group {
            if let note = store.notes.first(where: { $0.id == noteID }) {
                ScrollView { NoteMarkdownPreview(markdown: note.body, store: store).padding() }
                    .navigationTitle(note.title).toolbar { Button("Edit note") { editing = note } }
            } else { ContentUnavailableView("Note is no longer available", systemImage: "note.text") }
        }.sheet(item: $editing) { note in NoteEditor(note: note, store: store) }
    }
}

private struct NotesHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Writing") {
                    Text("Use # Heading, **bold**, *italic*, `code`, fenced code blocks, > quotations, bullet/numbered lists, and - [ ] tasks. Preview is read-only; edit the Markdown text to change it.")
                    Text("Add #work or #travel anywhere outside fenced, indented or inline code. Tags support Unicode letters and numbers, including Arabic, plus underscores and hyphens. Latin letter case is ignored.")
                    Text("[[Other note title]] opens matching active notes. Duplicate titles present a choice. Renaming a note does not rewrite links in other notes.")
                    Text("Preview supports common text blocks and inline formatting. Tables, embedded HTML, image attachments and remote image display are not implemented. Image references remain in the saved Markdown. External links open only after confirmation.")
                }
                Section("Search") {
                    Text("Words match title or body, case-insensitively. Separate words require every term. Use quotes for a phrase: \"first aid\".")
                    Text("#travel or tags:travel matches a whole tag. title:water searches titles; content:water searches note text. NOT tags:* finds untagged notes.")
                    Text("Use AND, OR and NOT in uppercase. AND binds before OR: water filter OR #medical. A * matches any number of characters in a word; ? matches one character.")
                    Text("Parentheses, stemming, fuzzy matches, Whoosh date expressions and last_modified: are not supported. Sort by title, creation or edit date from Notebook options.")
                }
                Section("Files and recovery") {
                    Text("Import UTF-8 .md/.markdown/.txt files or exported notebook JSON. Review before adding. Existing notes are never replaced; identical title/text duplicates are skipped. JSON preserves dates and trash; Markdown exports contain active note text with titles as filenames.")
                    Text("Notes stay in app storage, with no folder watching or automatic synchronization. Save changes before leaving the editor. Trash is retained until explicitly deleted. A failed or conflicting save keeps your draft open.")
                    Text("This native notebook has no web-server accounts, REST API or WYSIWYG editor. App Backup can protect the complete notebook; keep an export outside the app before removing it.")
                }
            }.navigationTitle("Notes help").toolbar { Button("Done") { dismiss() } }
        }
    }
}
