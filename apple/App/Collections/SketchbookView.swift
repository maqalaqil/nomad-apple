import PencilKit
import SwiftUI
import UniformTypeIdentifiers

private struct SavedSketch: Codable, Identifiable {
    let id: UUID
    var title: String
    var fileName: String
    let createdAt: Date
    var updatedAt: Date
}

private struct SketchArchive: Codable {
    var version = 1
    var sketches: [SavedSketch]
}

private struct SketchDraft: Identifiable {
    let id: UUID
    let original: SavedSketch?
    let title: String
    let drawing: PKDrawing
}

struct SketchbookView: View {
    @State private var sketches: [SavedSketch] = []
    @State private var draft: SketchDraft?
    @State private var deleting: SavedSketch?
    @State private var error: String?
    @State private var loaded = false
    @State private var exporting = false
    @State private var exportDocument = CollectionExportDocument(data: Data())
    @State private var exportType = UTType.png
    @State private var exportName = "sketch.png"

    var body: some View {
        List {
            if sketches.isEmpty {
                ContentUnavailableView("Your sketchbook is empty", systemImage: "pencil.and.outline",
                    description: Text("Draw with a pointer, Apple Pencil or your finger. Save editable drawings and export images."))
            }
            ForEach(sketches.sorted { $0.updatedAt > $1.updatedAt }) { sketch in
                Button { open(sketch) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sketch.title).foregroundStyle(.primary)
                            Text(sketch.updatedAt, format: .dateTime.month().day().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { deleting = sketch } }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { open(sketch) }
                    Button("Export PNG", systemImage: "photo") { prepareExport(sketch, asImage: true) }
                    Button("Export editable drawing", systemImage: "square.and.arrow.up") { prepareExport(sketch, asImage: false) }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = sketch }
                }
                .accessibilityHint("Open to draw. Additional export and delete actions are available in the context menu.")
            }
        }
        .navigationTitle("Sketchbook")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New sketch", systemImage: "plus") {
                    draft = SketchDraft(id: UUID(), original: nil, title: "Untitled sketch", drawing: PKDrawing())
                }.disabled(!loaded)
            }
        }
        .task { load() }
        #if os(macOS)
        .sheet(item: $draft) { draft in
            SketchEditor(draft: draft) { title, drawing in try save(draft: draft, title: title, drawing: drawing) }
                .frame(minWidth: 700, minHeight: 640)
        }
        #else
        .fullScreenCover(item: $draft) { draft in
            SketchEditor(draft: draft) { title, drawing in try save(draft: draft, title: title, drawing: drawing) }
        }
        #endif
        .confirmationDialog("Delete \(deleting?.title ?? "sketch")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete sketch", role: .destructive) {
                if let sketch = deleting { delete(sketch) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The saved drawing will be removed from this device.") }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType,
                      defaultFilename: exportName) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .alert("Sketchbook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        guard !loaded else { return }
        do {
            let archive = try CollectionStorage.load(SketchArchive.self, name: "sketches.json", collection: "sketches")
                ?? SketchArchive(sketches: [])
            guard archive.version == 1, Set(archive.sketches.map(\.id)).count == archive.sketches.count else {
                throw CollectionStorage.StorageError.invalidDocument("The sketchbook format is not supported.")
            }
            for sketch in archive.sketches { _ = try CollectionStorage.file(sketch.fileName, in: "sketches") }
            sketches = archive.sketches
            loaded = true
        } catch { self.error = "Your saved sketchbook could not be opened. It has not been overwritten. \(error.localizedDescription)" }
    }

    private func persist(_ replacement: [SavedSketch]) throws {
        try CollectionStorage.save(SketchArchive(sketches: replacement), name: "sketches.json", collection: "sketches")
        sketches = replacement
    }

    private func open(_ sketch: SavedSketch) {
        do {
            let data = try Data(contentsOf: CollectionStorage.file(sketch.fileName, in: "sketches"))
            draft = SketchDraft(id: sketch.id, original: sketch, title: sketch.title, drawing: try PKDrawing(data: data))
        } catch { self.error = "The drawing could not be opened. \(error.localizedDescription)" }
    }

    private func save(draft: SketchDraft, title: String, drawing: PKDrawing) throws {
        // A new revision file keeps the previous drawing intact until its manifest commits.
        let name = "\(draft.id.uuidString)-\(UUID().uuidString).drawing"
        let url = try CollectionStorage.file(name, in: "sketches")
        try drawing.dataRepresentation().write(to: url, options: .atomic)
        let record = SavedSketch(id: draft.id, title: title, fileName: name,
            createdAt: draft.original?.createdAt ?? Date(), updatedAt: Date())
        var replacement = sketches.filter { $0.id != draft.id }
        replacement.append(record)
        do { try persist(replacement) }
        catch { try? CollectionStorage.remove(name, collection: "sketches"); throw error }
        if let previous = draft.original {
            do { try CollectionStorage.remove(previous.fileName, collection: "sketches") }
            catch { self.error = "The drawing was saved, but an older revision could not be removed. \(error.localizedDescription)" }
        }
    }

    private func delete(_ sketch: SavedSketch) {
        do {
            try persist(sketches.filter { $0.id != sketch.id })
            do { try CollectionStorage.remove(sketch.fileName, collection: "sketches") }
            catch { try persist(sketches + [sketch]); throw error }
        } catch { self.error = "The sketch could not be deleted. \(error.localizedDescription)" }
    }

    private func prepareExport(_ sketch: SavedSketch, asImage: Bool) {
        do {
            let data = try Data(contentsOf: CollectionStorage.file(sketch.fileName, in: "sketches"))
            let safeTitle = sketch.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if asImage {
                let drawing = try PKDrawing(data: data)
                guard !drawing.bounds.isEmpty else {
                    throw CollectionStorage.StorageError.invalidDocument("Add some marks before exporting an image.")
                }
                let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
                // Keep very large drawings from allocating an unbounded image buffer.
                let scale = min(2, 4096 / max(bounds.width, bounds.height))
                guard let png = CollectionSketchImage.png(drawing.image(from: bounds, scale: scale)) else {
                    throw CollectionStorage.StorageError.invalidDocument("The image could not be created.")
                }
                exportDocument = CollectionExportDocument(data: png)
                exportType = .png
                exportName = safeTitle + ".png"
            } else {
                exportDocument = CollectionExportDocument(data: data)
                exportType = .data
                exportName = safeTitle + ".drawing"
            }
            exporting = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct SketchEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var drawing: PKDrawing
    @State private var dirty = false
    @State private var discarding = false
    @State private var error: String?
    let onSave: (String, PKDrawing) throws -> Void

    init(draft: SketchDraft, onSave: @escaping (String, PKDrawing) throws -> Void) {
        _title = State(initialValue: draft.title)
        _drawing = State(initialValue: draft.drawing)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Sketch title", text: $title).textFieldStyle(.roundedBorder).padding()
                    .onChange(of: title) { _, _ in dirty = true }
                DrawingCanvas(drawing: $drawing) { dirty = true }
                    .accessibilityLabel("Drawing canvas")
                if let error { Text(error).foregroundStyle(.red).font(.footnote).padding() }
            }
            .navigationTitle("Sketch")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(dirty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if dirty { discarding = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), drawing)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Discard unsaved changes?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep drawing", role: .cancel) { }
            }
        }
    }
}

#if !os(macOS)
private struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CollectionCanvasView {
        let canvas = CollectionCanvasView()
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .systemBackground
        canvas.contentSize = CGSize(width: 1800, height: 2400)
        canvas.minimumZoomScale = 0.5
        canvas.maximumZoomScale = 3
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = true
        return canvas
    }

    func updateUIView(_ canvas: CollectionCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            canvas.drawing = drawing
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        init(_ parent: DrawingCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onChange()
        }
    }
}

private final class CollectionCanvasView: PKCanvasView {
    private let picker = PKToolPicker()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            picker.addObserver(self)
            picker.setVisible(true, forFirstResponder: self)
            becomeFirstResponder()
        } else {
            picker.setVisible(false, forFirstResponder: self)
            picker.removeObserver(self)
        }
    }
}

#endif

private enum CollectionSketchImage {
    #if os(macOS)
    static func png(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
    #else
    static func png(_ image: UIImage) -> Data? { image.pngData() }
    #endif
}
