#if os(macOS)
import SwiftUI
import PencilKit
import AppKit

/// Produces the same PencilKit stroke data used by the iPhone/iPad canvas.
enum CollectionSketchStroke {
    /// Pointer positions and the eraser radius use drawing units, independent of preview zoom.
    static func canvasPoint(_ location: CGPoint, zoom: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(x: min(size.width, max(0, location.x / zoom)), y: min(size.height, max(0, location.y / zoom)))
    }

    /// Tests the interpolated spline's transformed nibs, not empty areas inside renderBounds.
    /// Sampling is at most one drawing point apart after the transform; half a point of
    /// eraser tolerance closes sampling gaps. A work limit fails the entire edit safely.
    static func erasing(_ drawing: PKDrawing, at points: [CGPoint], radius: CGFloat) throws -> PKDrawing {
        guard !points.isEmpty, points.count <= 20_000, radius.isFinite, (0...40).contains(radius),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw CollectionStorage.StorageError.invalidDocument("The erase gesture exceeds its supported size.")
        }
        let tolerance = radius + 0.5
        let eraser: CGPath
        if points.count == 1 || points.dropFirst().allSatisfy({ $0 == points[0] }) {
            eraser = CGPath(ellipseIn: CGRect(x: points[0].x - tolerance, y: points[0].y - tolerance,
                width: tolerance * 2, height: tolerance * 2), transform: nil)
        } else {
            let path = CGMutablePath(); path.addLines(between: points)
            eraser = path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        let eraserBounds = eraser.boundingBoxOfPath
        var remainingSamples = 250_000
        var kept: [PKStroke] = []
        for stroke in drawing.strokes {
            guard stroke.renderBounds.intersects(eraserBounds), !stroke.path.isEmpty else { kept.append(stroke); continue }
            let transform = stroke.transform
            // Frobenius norm bounds the largest affine scale, including shear/rotation.
            let scale = sqrt(transform.a * transform.a + transform.b * transform.b + transform.c * transform.c + transform.d * transform.d)
            guard scale.isFinite, scale > 0, transform.tx.isFinite, transform.ty.isFinite else {
                throw CollectionStorage.StorageError.invalidDocument("This stroke has an unsupported transform and cannot be erased.")
            }
            let mask = stroke.mask?.cgPath
            let ranges = mask == nil ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
            func touches(_ point: PKStrokePoint) throws -> Bool {
                remainingSamples -= 1
                guard remainingSamples >= 0 else {
                    throw CollectionStorage.StorageError.invalidDocument("This erase gesture is too complex. Try a shorter gesture or erase fewer strokes at once.")
                }
                guard point.opacity > 0, point.size.width > 0, point.size.height > 0 else { return false }
                return autoreleasepool {
                    let rect = CGRect(x: point.location.x - point.size.width / 2, y: point.location.y - point.size.height / 2,
                        width: point.size.width, height: point.size.height)
                    let nib = CGPath(ellipseIn: rect, transform: nil)
                    var affine = transform
                    guard let transformed = nib.copy(using: &affine), transformed.boundingBoxOfPath.intersects(eraserBounds) else { return false }
                    if let mask {
                        // PencilKit masks use untransformed stroke coordinates.
                        guard let clipped = nib.intersection(mask).copy(using: &affine) else { return false }
                        return !clipped.isEmpty && clipped.intersects(eraser)
                    }
                    return transformed.intersects(eraser)
                }
            }
            var hit = false
            for range in ranges {
                for point in stroke.path.interpolatedPoints(in: range, by: .distance(1 / scale)) {
                    if try touches(point) { hit = true; break }
                }
                // Explicitly include endpoints even if a stride does not land on them.
                if !hit { hit = try touches(stroke.path.interpolatedPoint(at: range.upperBound)) }
                if hit { break }
            }
            if !hit { kept.append(stroke) }
        }
        guard kept.count != drawing.strokes.count else { return drawing }
        var result = drawing
        result.strokes = kept
        return result
    }

    static func make(points: [CGPoint], color: NSColor, width: CGFloat, ink: PKInk.InkType) throws -> PKStroke {
        guard !points.isEmpty, points.count <= 20_000, width.isFinite, (1...40).contains(width),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...8_192).contains($0.x) && (0...8_192).contains($0.y) }) else {
            throw CollectionStorage.StorageError.invalidDocument("The drawing stroke exceeds its supported size.")
        }
        let values = points.count == 1 ? [points[0], CGPoint(x: min(8_192, points[0].x + 0.05), y: points[0].y)] : points
        let controls = values.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 120,
                size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: controls, creationDate: Date()))
    }
}

struct DrawingCanvas: View {
    @Binding var drawing: PKDrawing
    let onChange: () -> Void
    @State private var color = Color.blue
    @State private var width = 4.0
    @State private var zoom = 0.5
    @State private var tool = "Pen"
    @State private var points: [CGPoint] = []
    @State private var preview: NSImage?
    @State private var undo: [Data] = []
    @State private var redo: [Data] = []
    @State private var error: String?
    private var size: CGSize {
        CGSize(width: max(1_800, min(8_192, drawing.bounds.maxX.isFinite ? drawing.bounds.maxX + 32 : 1_800)),
               height: max(2_400, min(8_192, drawing.bounds.maxY.isFinite ? drawing.bounds.maxY + 32 : 2_400)))
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Drawing tool", selection: $tool) { ForEach(["Pen", "Pencil", "Marker", "Erase stroke"], id: \.self) { Text($0) } }.frame(width: 165)
                ColorPicker("Ink", selection: $color, supportsOpacity: false).labelsHidden()
                Slider(value: $width, in: 1...40).frame(width: 110).accessibilityLabel("Stroke width")
                Text("\(Int(width)) pt").monospacedDigit().frame(width: 42)
                Button("Undo", systemImage: "arrow.uturn.backward") { restore(undoing: true) }.disabled(undo.isEmpty)
                Button("Redo", systemImage: "arrow.uturn.forward") { restore(undoing: false) }.disabled(redo.isEmpty)
                Spacer()
                Slider(value: $zoom, in: 0.25...2).frame(width: 100).accessibilityLabel("Canvas zoom")
                Text("\(Int(zoom * 100))%")
            }.padding(.horizontal)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.white
                    if let preview { Image(nsImage: preview).resizable().frame(width: size.width * zoom, height: size.height * zoom) }
                    Canvas { context, _ in
                        guard tool != "Erase stroke", !points.isEmpty else { return }
                        var path = Path(); path.move(to: CGPoint(x: points[0].x * zoom, y: points[0].y * zoom))
                        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x * zoom, y: point.y * zoom)) }
                        context.stroke(path, with: .color(color.opacity(tool == "Marker" ? 0.4 : 1)), style: StrokeStyle(lineWidth: width * zoom, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: size.width * zoom, height: size.height * zoom)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard points.count < 20_000 else { return }
                    points.append(CollectionSketchStroke.canvasPoint(event.location, zoom: zoom, size: size))
                }.onEnded { _ in commitStroke() })
                .accessibilityLabel("Editable drawing canvas. Use a mouse or trackpad to draw; choose Erase stroke to remove whole strokes.")
            }.background(Color.gray.opacity(0.15))
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
        }
        .onAppear(perform: refresh)
    }
    private func refresh() {
        let rect = CGRect(origin: .zero, size: size)
        preview = drawing.image(from: rect, scale: min(1, 4_096 / max(rect.width, rect.height)))
    }
    private func appendHistory(_ data: Data, to values: inout [Data]) {
        values.append(data)
        while values.count > 20 || values.reduce(0, { $0 + $1.count }) > 32 * 1_024 * 1_024 { values.removeFirst() }
    }
    private func commitStroke() {
        defer { points = [] }
        guard !points.isEmpty else { return }
        do {
            var next = drawing
            if tool == "Erase stroke" {
                next = try CollectionSketchStroke.erasing(next, at: points, radius: max(6, width))
            } else {
                guard next.strokes.count < 5_000 else { throw CollectionStorage.StorageError.invalidDocument("This drawing contains the maximum 5,000 strokes.") }
                let ink: PKInk.InkType = tool == "Pencil" ? .pencil : tool == "Marker" ? .marker : .pen
                next.strokes.append(try CollectionSketchStroke.make(points: points, color: NSColor(color), width: width, ink: ink))
            }
            let encoded = next.dataRepresentation()
            guard encoded.count <= 64 * 1_024 * 1_024 else { throw CollectionStorage.StorageError.invalidDocument("The editable drawing exceeds 64 MB.") }
            let original = drawing.dataRepresentation()
            guard encoded != original else { return }
            appendHistory(original, to: &undo); redo = []; drawing = next; error = nil; onChange(); refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func restore(undoing: Bool) {
        guard let data = undoing ? undo.last : redo.last else { return }
        do {
            let restored = try PKDrawing(data: data), current = drawing.dataRepresentation()
            if undoing { undo.removeLast(); appendHistory(current, to: &redo) }
            else { redo.removeLast(); appendHistory(current, to: &undo) }
            drawing = restored; onChange(); refresh(); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
#endif
