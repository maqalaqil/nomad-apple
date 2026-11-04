import SwiftUI
import UIKit
import PDFKit

/// A full-page preview with normalized top-left selection coordinates. Export
/// uses exactly the same visible crop-box dimensions, including page rotation.
struct PDFMarkupEditor: View {
    let data: Data
    let name: String
    let redaction: Bool
    let onOutput: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var pageImage: CGImage?
    @State private var marks: [PDFWorkshopMark] = []
    @State private var kind: PDFWorkshopMark.Kind = .ink
    @State private var annotationText = ""
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var inkPoints: [CGPoint] = []
    @State private var busy = false
    @State private var progress = 0.0
    @State private var confirming = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    private var currentKind: PDFWorkshopMark.Kind { redaction ? .redact : kind }
    private var currentMarks: [PDFWorkshopMark] { marks.filter { $0.page == pageIndex } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(redaction ? "Drag rectangles over every area to remove. Review all pages before creating the permanent copy." : "Draw with your finger or Apple Pencil, or drag a rectangle for a highlight or text note.")
                    .font(.callout).padding(.horizontal)
                if !redaction {
                    Picker("Visible annotation", selection: $kind) {
                        Text("Draw / signature").tag(PDFWorkshopMark.Kind.ink)
                        Text("Highlight").tag(PDFWorkshopMark.Kind.highlight)
                        Text("Text").tag(PDFWorkshopMark.Kind.text)
                    }.pickerStyle(.segmented).padding(.horizontal)
                    if kind == .text { TextField("Text to place inside the rectangle", text: $annotationText).textFieldStyle(.roundedBorder).padding(.horizontal) }
                }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { pageIndex -= 1 }.disabled(pageIndex <= 0 || busy)
                    Spacer()
                    Text("Page \(pageIndex + 1) of \(pageCount) · \(currentMarks.count) marks")
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { pageIndex += 1 }.disabled(pageIndex + 1 >= pageCount || busy)
                }.padding(.horizontal)
                GeometryReader { geometry in
                    if let pageImage {
                        let scale = min(geometry.size.width / CGFloat(pageImage.width), geometry.size.height / CGFloat(pageImage.height))
                        let size = CGSize(width: CGFloat(pageImage.width) * scale, height: CGFloat(pageImage.height) * scale)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: pageImage, scale: 1).resizable().frame(width: size.width, height: size.height)
                            Canvas { context, canvas in
                                for mark in currentMarks { paint(mark, context: &context, size: canvas) }
                                if currentKind == .ink, inkPoints.count > 1 {
                                    paint(PDFWorkshopMark(page: pageIndex, kind: .ink, points: inkPoints), context: &context, size: canvas)
                                } else if let dragStart, let dragEnd {
                                    paint(PDFWorkshopMark(page: pageIndex, kind: currentKind, rectangle: rectangle(dragStart, dragEnd), text: annotationText), context: &context, size: canvas)
                                }
                            }.frame(width: size.width, height: size.height)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                    guard !busy else { return }
                                    let point = normalized(value.location, size: size)
                                    if currentKind == .ink {
                                        if inkPoints.isEmpty { inkPoints.append(normalized(value.startLocation, size: size)) }
                                        if inkPoints.count < 20_000 { inkPoints.append(point) }
                                    } else { dragStart = normalized(value.startLocation, size: size); dragEnd = point }
                                }.onEnded { _ in finishMark() })
                                .accessibilityLabel(redaction ? "Drag to select a redaction area" : "Draw or select an annotation area")
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { ProgressView("Rendering page…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.background(Color.gray.opacity(0.12)).clipped()
                HStack {
                    Button("Undo last mark", systemImage: "arrow.uturn.backward") { if !marks.isEmpty { marks.removeLast() } }.disabled(marks.isEmpty || busy)
                    Spacer()
                    Text("\(marks.count) marks on \(Set(marks.map(\.page)).count) pages").font(.caption)
                }.padding(.horizontal)
                if busy {
                    ProgressView(value: progress).padding(.horizontal)
                    Button("Cancel export", role: .cancel) { task?.cancel() }
                }
                Text(redaction ? "The new PDF is image-only. Text, forms, links, metadata, attachments and signatures are removed from every page. Originals are kept. Use rectangles large enough to cover all sensitive pixels." : "These are visible, flattened marks. They do not provide certificate signing, identity verification or tamper detection. Export can invalidate existing digital signatures and flatten forms.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            .navigationTitle(redaction ? "Permanent redaction" : "Sign and annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { task?.cancel(); dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(redaction ? "Review export" : "Create copy") { if redaction { confirming = true } else { export() } }
                        .disabled(marks.isEmpty || busy || pageImage == nil)
                }
            }
            .confirmationDialog("Create permanent redacted copy?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Rasterize all pages and permanently mask \(marks.count) areas", role: .destructive) { export() }
                Button("Keep reviewing", role: .cancel) {}
            } message: { Text("Review every selected rectangle. The new PDF will keep only the masked page images; it cannot restore removed areas. Your original input remains unchanged.") }
            .alert("PDF editor", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .task(id: pageIndex) { await loadPage() }
            .onDisappear { generation = UUID(); task?.cancel() }
        }
        .interactiveDismissDisabled(busy)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }

    private func rectangle(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func finishMark() {
        defer { dragStart = nil; dragEnd = nil; inkPoints = [] }
        guard !busy, marks.count < 2_000 else { return }
        if currentKind == .ink {
            guard inkPoints.count >= 2 else { return }
            marks.append(PDFWorkshopMark(page: pageIndex, kind: .ink, points: inkPoints))
        } else if let dragStart, let dragEnd {
            let rect = rectangle(dragStart, dragEnd)
            guard rect.width >= 0.003, rect.height >= 0.003 else { return }
            if currentKind == .text && annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error = "Enter text before placing its rectangle."; return }
            marks.append(PDFWorkshopMark(page: pageIndex, kind: currentKind, rectangle: rect, text: annotationText))
        }
    }

    private func paint(_ mark: PDFWorkshopMark, context: inout GraphicsContext, size: CGSize) {
        if mark.kind == .ink {
            var path = Path()
            for (index, point) in mark.points.enumerated() {
                let point = CGPoint(x: point.x * size.width, y: point.y * size.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Color(red: 0.06, green: 0.16, blue: 0.55)), style: StrokeStyle(lineWidth: max(1, min(size.width, size.height) * 0.003), lineCap: .round, lineJoin: .round))
        } else {
            let rect = CGRect(x: mark.rectangle.minX * size.width, y: mark.rectangle.minY * size.height, width: mark.rectangle.width * size.width, height: mark.rectangle.height * size.height)
            context.fill(Path(rect), with: .color(mark.kind == .redact ? .black : mark.kind == .highlight ? .yellow.opacity(0.4) : .blue.opacity(0.08)))
            if mark.kind == .text {
                context.stroke(Path(rect), with: .color(.blue), lineWidth: 1)
                context.draw(Text(mark.text).font(.system(size: max(8, min(24, rect.height * 0.65)))).foregroundColor(.blue), in: rect)
            }
        }
    }

    @MainActor private func loadPage() async {
        pageImage = nil; dragStart = nil; dragEnd = nil; inkPoints = []
        let index = pageIndex, snapshot = data
        let worker = Task.detached(priority: .userInitiated) { () throws -> (CGImage, Int) in
            let document = try PDFWorkshopEngine.document(snapshot)
            guard let page = document.page(at: index) else { throw PDFWorkshopError.message("Page is unavailable.") }
            return (try PDFWorkshopEngine.render(page, longestSide: 1_600), document.pageCount)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard index == pageIndex else { return }
            pageImage = result.0; pageCount = result.1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func export() {
        busy = true; progress = 0
        let token = UUID(); generation = token
        let source = data, selected = marks, isRedaction = redaction
        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                let report: (Double) -> Void = { value in Task { @MainActor in if generation == token { progress = value } } }
                return try isRedaction ? PDFWorkshopEngine.redactedPDF(source, marks: selected, progress: report) : PDFWorkshopEngine.annotatedPDF(source, marks: selected, progress: report)
            }
            do {
                let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                busy = false; task = nil
                onOutput(output, isRedaction ? "redacted.pdf" : "annotated.pdf"); dismiss()
            } catch is CancellationError { if generation == token { busy = false; task = nil } }
            catch { if generation == token { busy = false; task = nil; self.error = error.localizedDescription } }
        }
    }
}
