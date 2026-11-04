import SwiftUI
import PDFKit
import QuickLook
#if canImport(NomadCore)
import NomadCore
#endif

@MainActor
struct DocumentPreview: View {
    let document: LibraryDocument
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var previewText: String?
    @State private var previewError: String?

    var body: some View {
        NavigationStack {
            Group {
                if !FileManager.default.fileExists(atPath: url.path) {
                    ContentUnavailableView("File unavailable", systemImage: "doc.badge.ellipsis",
                        description: Text("This local file is missing. Import another copy from Files."))
                } else {
                    switch document.kind {
                    case .pdf:
                        PDFPreview(url: url)
                    case .text, .markdown:
                        if let previewText {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    if let previewError { Text(previewError).font(.callout).foregroundStyle(.secondary) }
                                    Text(previewText).font(.body.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(24)
                            }
                        } else if let previewError {
                            ContentUnavailableView("Cannot read file", systemImage: "exclamationmark.triangle", description: Text(previewError))
                        } else { ProgressView("Opening local file…") }
                    case .zim:
                        ZIMReaderView(url: url)
                    case .epub:
                        EPUBReaderView(url: url)
                    case .model:
                        ContentUnavailableView("File saved on this iPad", systemImage: "internaldrive",
                            description: Text(document.indexingStatus + " You can export the original file using the share button."))
                    default:
                        QuickLookPreview(url: url)
                    }
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Label("Export file", systemImage: "square.and.arrow.up") }
                }
            }
            .task {
                guard document.kind == .text || document.kind == .markdown else { return }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let bytes = try handle.read(upToCount: 2 * 1_024 * 1_024) ?? Data()
                        return (String(decoding: bytes, as: UTF8.self), bytes.count == 2 * 1_024 * 1_024)
                    }.value
                    previewText = result.0
                    if result.1 { previewError = "Preview shows the first 2 MB. Export the file to view its full contents." }
                } catch { previewError = error.localizedDescription }
            }
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
