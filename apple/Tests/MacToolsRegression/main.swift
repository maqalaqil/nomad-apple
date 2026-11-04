import Foundation
import AppKit
import PencilKit

@main struct MacToolsRegression {
    @MainActor static func main() async throws {
        guard let testDomain = Bundle.main.bundleIdentifier, testDomain.hasPrefix("org.nomad.tests.mac-tools.") else { fatalError("Run inside the isolated test bundle") }
        defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }
        var checks = 0
        func check(_ value: Bool, line: UInt = #line) {
            guard value else {
                FileHandle.standardError.write(Data("FAILED check \(checks + 1) at line \(line)\n".utf8))
                exit(1)
            }
            checks += 1
        }
        for ink: PKInk.InkType in [.pen, .pencil, .marker] {
            let stroke = try CollectionSketchStroke.make(points: [CGPoint(x: 20, y: 30), CGPoint(x: 150, y: 100)], color: .blue, width: 8, ink: ink)
            let original = PKDrawing(strokes: [stroke])
            let reopened = try PKDrawing(data: original.dataRepresentation())
            check(reopened.strokes.count == 1)
            check(reopened.strokes[0].ink.inkType == ink)
            check(abs(reopened.strokes[0].path[0].location.x - 20) < 0.1)
            check(abs(reopened.strokes[0].path[1].location.y - 100) < 0.1)
            let image = reopened.image(from: CGRect(x: 0, y: 0, width: 200, height: 150), scale: 1)
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            check(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 150)
            let png = bitmap.representation(using: .png, properties: [:])!
            check(png.starts(with: [137, 80, 78, 71]))
            // Actual stroke pixels must be rendered, not only a valid blank image.
            var occupied = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.05 { occupied += 1 }
                }
            }
            check(occupied > 50)
        }
        let dot = try CollectionSketchStroke.make(points: [.init(x: 40, y: 50)], color: .black, width: 3, ink: .pen)
        check(dot.path.count == 2)
        for points in [[], [.init(x: CGFloat.nan, y: 0)], [.init(x: 9_000, y: 0)], Array(repeating: .zero, count: 20_001)] as [[CGPoint]] {
            do { _ = try CollectionSketchStroke.make(points: points, color: .black, width: 3, ink: .pen); fatalError("Invalid stroke accepted") }
            catch { checks += 1 }
        }
        func survives(_ stroke: PKStroke, _ points: [CGPoint], radius: CGFloat = 6) throws -> Bool {
            try CollectionSketchStroke.erasing(PKDrawing(strokes: [stroke]), at: points, radius: radius).strokes.count == 1
        }
        let diagonal = try CollectionSketchStroke.make(points: [.init(x: 20, y: 20), .init(x: 180, y: 180)], color: .black, width: 4, ink: .pen)
        let diagonalEmpty = CGPoint(x: 30, y: 165)
        check(diagonal.renderBounds.contains(diagonalEmpty)) // Previously the bounds-only test erased here.
        check(try survives(diagonal, [diagonalEmpty]))
        check(try !survives(diagonal, [.init(x: 100, y: 100)]))
        check(try !survives(diagonal, [.init(x: 100, y: 106)]))
        // A fast drag crossing ink must hit even when neither event endpoint touches it.
        check(try !survives(diagonal, [.init(x: 20, y: 180), .init(x: 180, y: 20)]))
        check(try survives(diagonal, [.init(x: 20, y: 180), .init(x: 40, y: 160)]))
        let curve = try CollectionSketchStroke.make(points: [.init(x: 20, y: 180), .init(x: 20, y: 20), .init(x: 100, y: 20), .init(x: 180, y: 20), .init(x: 180, y: 180)], color: .black, width: 5, ink: .pen)
        let curveEmpty = CGPoint(x: 100, y: 130)
        check(curve.renderBounds.contains(curveEmpty))
        check(try survives(curve, [curveEmpty]))
        check(try !survives(curve, [curve.path.interpolatedLocation(at: 1.6)]))
        var transformed = diagonal
        transformed.transform = .init(a: 0, b: 2, c: -0.5, d: 0, tx: 250, ty: 20)
        let transformedEmpty = diagonalEmpty.applying(transformed.transform)
        check(transformed.renderBounds.contains(transformedEmpty))
        check(try survives(transformed, [transformedEmpty]))
        check(try !survives(transformed, [.init(x: 100, y: 100).applying(transformed.transform)]))
        check(try survives(transformed, [.init(x: 100, y: 100)])) // Original, untransformed position.
        let thick = try CollectionSketchStroke.make(points: [.init(x: 20, y: 50), .init(x: 180, y: 50)], color: .black, width: 40, ink: .pen)
        check(try !survives(thick, [.init(x: 100, y: 68)], radius: 0))
        check(try survives(thick, [.init(x: 100, y: 80)], radius: 0))
        var squeezed = thick
        squeezed.transform = .init(a: 3, b: 0, c: 0, d: 0.25, tx: 40, ty: 100)
        check(try !survives(squeezed, [.init(x: 340, y: 116)], radius: 0))
        check(try survives(squeezed, [.init(x: 340, y: 125)], radius: 0))
        let varyingPoints = [(CGPoint(x: 20, y: 20), CGFloat(2)), (CGPoint(x: 180, y: 20), CGFloat(40))].enumerated().map { index, value in
            PKStrokePoint(location: value.0, timeOffset: Double(index), size: .init(width: value.1, height: value.1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let varying = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: varyingPoints, creationDate: Date()))
        check(try survives(varying, [.init(x: 25, y: 34)], radius: 0))
        check(try !survives(varying, [.init(x: 170, y: 34)], radius: 0))
        var masked = thick
        masked.mask = NSBezierPath(rect: .init(x: 20, y: 20, width: 65, height: 60))
        check(try survives(masked, [.init(x: 130, y: 50)]))
        check(try !survives(masked, [.init(x: 50, y: 50)]))
        for zoom: CGFloat in [0.25, 0.5, 1, 2] {
            let actual = CollectionSketchStroke.canvasPoint(.init(x: 100 * zoom, y: 100 * zoom), zoom: zoom, size: .init(width: 1_800, height: 2_400))
            check(actual == CGPoint(x: 100, y: 100))
            check(try !survives(diagonal, [actual]))
            let empty = CollectionSketchStroke.canvasPoint(.init(x: diagonalEmpty.x * zoom, y: diagonalEmpty.y * zoom), zoom: zoom, size: .init(width: 1_800, height: 2_400))
            check(try survives(diagonal, [empty]))
        }
        check(try !survives(dot, [.init(x: 40, y: 50)]))
        check(try !survives(dot, [.init(x: 40, y: 50), .init(x: 40, y: 50)]))
        let repeated = try CollectionSketchStroke.make(points: (0..<10_000).map { $0.isMultiple(of: 2) ? CGPoint(x: 20, y: 20) : CGPoint(x: 180, y: 180) }, color: .black, width: 1, ink: .pen)
        do { _ = try survives(repeated, [diagonalEmpty], radius: 0); fatalError("Unbounded erase accepted") }
        catch { check(error.localizedDescription.contains("too complex")) }
        let both = PKDrawing(strokes: [diagonal, curve])
        let originalBytes = both.dataRepresentation()
        let noOp = try CollectionSketchStroke.erasing(both, at: [.init(x: 300, y: 300)], radius: 6)
        check(noOp.dataRepresentation() == originalBytes)
        let after = try CollectionSketchStroke.erasing(both, at: [curve.path.interpolatedLocation(at: 1.6)], radius: 6)
        check(after.strokes.count == 1)
        check(both.dataRepresentation() == originalBytes) // Value-type edit keeps original/history intact.
        do { _ = try CollectionSketchStroke.erasing(both, at: [.init(x: CGFloat.nan, y: 0)], radius: 6); fatalError("Invalid eraser accepted") }
        catch { checks += 1 }
        let board = NSPasteboard(name: .init("NomadVaultClipboardTest-\(UUID())"))
        defer { board.clearContents(); board.releaseGlobally() }
        VaultClipboard.copy("Synthetic secret", to: board, expiresAfter: .milliseconds(30))
        check(board.string(forType: .string) == "Synthetic secret")
        try await Task.sleep(for: .milliseconds(100))
        check(board.string(forType: .string) == nil)
        VaultClipboard.copy("Synthetic secret", to: board, expiresAfter: .milliseconds(30))
        board.clearContents(); board.setString("Later user copy", forType: .string)
        try await Task.sleep(for: .milliseconds(100))
        check(board.string(forType: .string) == "Later user copy")
        VaultClipboard.copy("First", to: board, expiresAfter: .milliseconds(20))
        VaultClipboard.copy("Second", to: board, expiresAfter: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(60))
        check(board.string(forType: .string) == "Second")
        try await Task.sleep(for: .milliseconds(200))
        check(board.string(forType: .string) == nil)
        print("PASS: \(checks) native Mac drawing serialization/rendering/eraser geometry/input-limit and isolated vault clipboard expiry checks; general clipboard and Keychain untouched")
    }
}
