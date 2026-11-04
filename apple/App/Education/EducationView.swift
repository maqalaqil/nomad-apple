import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import AVKit

private struct LocalLesson: Codable, Identifiable {
    var id = UUID()
    var title: String
    var filename: String
    var completed = false
}

struct EducationView: View {
    @State private var lessons: [LocalLesson] = []
    @State private var importer = false
    @State private var busy = false
    @State private var preview: URL?
    @State private var error: String?
    @State private var deleting: LocalLesson?
    @State private var manifest = LocalManifestFile(url: URL.applicationSupportDirectory.appending(path: "NomadPad/Lessons/lessons.json"))
    private let root = URL.applicationSupportDirectory.appending(path: "NomadPad/Lessons")

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Learn at your own pace.").font(.title2.bold())
                    Text("Import lesson videos, PDFs, or text files and keep a local completion record. Kolibri channels, interactive exercises, and classroom profiles are still being integrated.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: Double(lessons.filter(\.completed).count), total: Double(max(1, lessons.count)))
                    Text("\(lessons.filter(\.completed).count) of \(lessons.count) lessons completed").font(.caption)
                }.padding(.vertical, 8)
            }
            if !manifest.isReady {
                Section {
                    Text("Saved lessons could not be loaded. Changes are disabled to preserve your files.").foregroundStyle(.orange)
                    Button("Reload saved lessons") { load() }
                }
            }
            ForEach(lessons) { lesson in
                HStack {
                    Button { toggle(lesson) } label: { Image(systemName: lesson.completed ? "checkmark.circle.fill" : "circle").font(.title2) }.buttonStyle(.borderless).accessibilityLabel(lesson.completed ? "Mark incomplete" : "Mark complete")
                    Button { preview = root.appending(path: lesson.filename) } label: {
                        VStack(alignment: .leading) {
                            Text(lesson.title).foregroundStyle(.primary)
                            Text(lesson.completed ? "Completed" : "Ready to study").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }.disabled(!manifest.isReady || busy)
                    .swipeActions { Button("Delete", role: .destructive) { deleting = lesson }.disabled(!manifest.isReady || busy) }
            }
        }
        .toolbar { Button("Import lessons", systemImage: "plus") { importer = true }.disabled(busy || !manifest.isReady); if busy { ProgressView() } }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .plainText, .movie, .audio], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): importLessons(urls); case .failure(let error): self.error = error.localizedDescription }
        }
        .quickLookPreview($preview)
        .task { load() }
        .alert("Education", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Remove this lesson and its local file?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Remove lesson", role: .destructive) {
                guard let deleting, manifest.isReady, !busy else { return }
                do {
                    let updated = lessons.filter { $0.id != deleting.id }
                    try persist(updated); lessons = updated
                    let file = root.appending(path: deleting.filename)
                    if FileManager.default.fileExists(atPath: file.path) {
                        do { try FileManager.default.removeItem(at: file) }
                        catch {
                            // Restore the record if deleting its file fails.
                            try persist(lessons + [deleting]); lessons.append(deleting)
                            throw error
                        }
                    }
                } catch { self.error = error.localizedDescription }
                self.deleting = nil
            }
        }
    }
    private func load() {
        guard !busy, !manifest.isReady else { return }
        do {
            lessons = try manifest.load([LocalLesson].self) { saved in
                guard Set(saved.map(\.id)).count == saved.count, Set(saved.map(\.filename)).count == saved.count,
                      saved.allSatisfy({ lesson in
                          LocalStorage.isSafeBasename(lesson.filename) &&
                          UUID(uuidString: (lesson.filename as NSString).deletingPathExtension) != nil &&
                          !lesson.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      }) else { throw CocoaError(.fileReadCorruptFile) }
            } ?? []
        } catch { self.error = "Saved lessons could not be read. The original files are preserved. \(error.localizedDescription)" }
    }
    private func persist(_ updated: [LocalLesson]) throws {
        try manifest.save(updated)
    }
    private func toggle(_ lesson: LocalLesson) {
        guard manifest.isReady, !busy else { return }
        var updated = lessons
        if let i = updated.firstIndex(where: { $0.id == lesson.id }) { updated[i].completed.toggle() }
        do { try persist(updated); lessons = updated } catch { self.error = error.localizedDescription }
    }
    private func importLessons(_ urls: [URL]) {
        guard manifest.isReady, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            for url in urls {
                let filename = LocalStorage.internalFilename(id: UUID(), source: url)
                let destination = root.appending(path: filename)
                do {
                    try await Task.detached {
                        try CollectionStorage.copySelectedFile(url, to: destination)
                    }.value
                    let updated = lessons + [LocalLesson(title: url.deletingPathExtension().lastPathComponent, filename: filename)]
                    try persist(updated); lessons = updated
                } catch { try? FileManager.default.removeItem(at: destination); self.error = error.localizedDescription }
            }
        }
    }
}
