import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct FileWorkspaceView: View {
    @Bindable var library: LibraryStore
    @State private var workspace = FileWorkspace()
    var body: some View { WorkspaceFolderView(workspace: workspace, library: library, directory: workspace.root) }
}

private struct WorkspaceFolderView: View {
    @Bindable var workspace: FileWorkspace
    @Bindable var library: LibraryStore
    let directory: URL
    @State private var entries: [WorkspaceEntry] = []
    @State private var error: String?
    @State private var importing = false
    @State private var preview: URL?
    @State private var renaming: WorkspaceEntry?
    @State private var removing: WorkspaceEntry?
    @State private var creatingFolder = false
    @State private var name = ""
    @State private var query = ""

    var body: some View {
        List {
            if directory == workspace.root {
                Section {
                    Text("Your app-owned file workspace. Organize files and folders here, import copies from Files, or share them back. Knowledge Library and other modules keep their own imported copies.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let error = workspace.error { Text(error).foregroundStyle(.orange) }
            if let clipboard = workspace.clipboard {
                Section {
                    HStack {
                        Text("\(clipboard.move ? "Move" : "Copy"): \(clipboard.url.lastPathComponent)").lineLimit(1)
                        Spacer()
                        Button("Paste here") { run { try await workspace.paste(in: directory) } }.disabled(workspace.busy)
                        Button("Cancel") { workspace.clipboard = nil }
                    }
                }
            }
            if workspace.busy { ProgressView("Working with local files…") }
            if entries.isEmpty && !workspace.busy { ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text("Import files or create a folder to start organizing.")) }
            ForEach(entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { entry in
                Group {
                    if entry.isDirectory {
                        NavigationLink { WorkspaceFolderView(workspace: workspace, library: library, directory: entry.url) } label: { row(entry) }
                    } else { Button { preview = entry.url } label: { row(entry) }.buttonStyle(.plain) }
                }
                .contextMenu {
                    Button("Rename") { renaming = entry; name = entry.name }
                    Button("Copy") { workspace.clipboard = (entry.url, false) }
                    Button("Move") { workspace.clipboard = (entry.url, true) }
                    if !entry.isDirectory {
                        ShareLink(item: entry.url) { Label("Share or export", systemImage: "square.and.arrow.up") }
                        Button("Copy to Knowledge Library") { run { try await library.importFile(entry.url) } }
                    }
                    Button("Delete", role: .destructive) { removing = entry }
                }.disabled(workspace.busy)
            }
        }
        .navigationTitle(directory == workspace.root ? "Files" : directory.lastPathComponent)
        .searchable(text: $query, prompt: "Search this folder")
        .toolbar {
            Button("New folder", systemImage: "folder.badge.plus") { name = ""; creatingFolder = true }.disabled(workspace.busy)
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }.disabled(workspace.busy)
        }
        .task { refresh() }
        .onChange(of: workspace.revision) { _, _ in refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): run { try await workspace.importFiles(urls, into: directory) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .quickLookPreview($preview)
        .alert(creatingFolder ? "New folder" : "Rename item", isPresented: Binding(get: { creatingFolder || renaming != nil }, set: { if !$0 { creatingFolder = false; renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { creatingFolder = false; renaming = nil }
            Button("Save") {
                do {
                    if let renaming { try workspace.rename(renaming, to: name) }
                    else { try workspace.createFolder(name, in: directory) }
                    refresh()
                } catch { self.error = error.localizedDescription }
                creatingFolder = false; renaming = nil
            }
        }
        .confirmationDialog("Delete \(removing?.name ?? "this item")? Folders include all their contents. This cannot be undone.", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let removing { do { try workspace.remove(removing); refresh() } catch { self.error = error.localizedDescription } }
                removing = nil
            }
        }
        .alert("Files need attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func row(_ entry: WorkspaceEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(NomadTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).lineLimit(2)
                if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 5)
    }
    private func refresh() { do { entries = try workspace.list(directory) } catch { self.error = error.localizedDescription } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation(); refresh() } catch { self.error = error.localizedDescription; refresh() } }
    }
}
