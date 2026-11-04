import SwiftUI
import UniformTypeIdentifiers

struct ITToolsView: View {
    var body: some View {
        ToolBundledEditorView(title: "IT Tools", directoryName: "ITTools", description: "The complete upstream IT Tools frontend is bundled locally. Tool preferences and favourites use local web storage. Network-dependent operations and external links are blocked.")
    }
}

struct ExcalidrawView: View {
    var body: some View {
        ToolBundledEditorView(title: "Excalidraw", directoryName: "Excalidraw", description: "The full Excalidraw editor runs locally, with bundled fonts and automatic scene/library storage on this device. Wait for Saved on this device before leaving. Export .excalidraw files for backups and separate drawings; PNG, SVG, and library exports are also available. Online collaboration, accounts, and external library downloads require services and are unavailable here.")
    }
}

private struct ToolBundledEditorView: View {
    let title: String
    let directoryName: String
    let description: String
    @StateObject private var controller: ToolCyberChefController
    @State private var information = false

    init(title: String, directoryName: String, description: String) {
        self.title = title; self.directoryName = directoryName; self.description = description
        _controller = StateObject(wrappedValue: ToolCyberChefController(applicationName: title))
    }

    private var directory: URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return [root.appendingPathComponent("WebTools/\(directoryName)", isDirectory: true), root.appendingPathComponent("Resources/WebTools/\(directoryName)", isDirectory: true)]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    var body: some View {
        Group {
            if let directory {
                ZStack(alignment: .top) {
                    ToolCyberChefWebView(directory: directory, controller: controller, useLocalScheme: true)
                    if controller.loading { ProgressView("Loading \(title)…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding() }
                }
            } else {
                ContentUnavailableView("\(title) assets not bundled", systemImage: "shippingbox", description: Text("Run apple/scripts/fetch-web-editors.py before rebuilding. No remote website is loaded."))
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Offline information", systemImage: "info.circle") { information = true } }
        }
        .sheet(isPresented: $information) {
            NavigationStack {
                List {
                    Section("Offline workspace") { Text(description) }
                    Section("Files and storage") {
                        #if os(macOS)
                        Text("Imports use the file picker; exports offer Save As and sharing. Save exported files outside the app for backups. Cloud files must be downloaded before going offline. Local browser data can be lost when reinstalling the app.")
                        #else
                        Text("Imports use Files; exports open the share sheet. Choose Save to Files to retain exported content. Cloud files must be downloaded before going offline. Local browser data can be lost when reinstalling the app, so keep exported backups.")
                        #endif
                        Text("The complete editor/tool catalog is included. Individual browser APIs and all upstream operations still require device compatibility testing. Memory-intensive work can be stopped by the system.")
                    }
                    if directoryName == "ITTools", let directory {
                        Section("Open-source distribution") {
                            Text("IT Tools v2024.10.22-7ca5933 · GNU GPL v3. Corresponding upstream source and the local integration notes are included with the app.")
                            Button("Export IT Tools source archive") { information = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.offerExportForSharing(directory.appendingPathComponent("it-tools-source.tar.gz")) } }
                            Button("Read license") { information = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.offerExportForSharing(directory.appendingPathComponent("LICENSE")) } }
                        }
                    }
                }
                .navigationTitle("About \(title)")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { information = false } } }
            }
        }
        .fileImporter(isPresented: $controller.importing, allowedContentTypes: controller.importsDirectories ? [.folder] : [.item], allowsMultipleSelection: controller.allowsMultipleImports, onCompletion: controller.finishImport, onCancellation: controller.cancelImport)
        .sheet(item: $controller.export) { exported in
            ToolCyberChefShareSheet(url: exported.url).onDisappear { controller.finishExport(exported.url) }
        }
        .alert("\(title) message", isPresented: $controller.dialogPresented, presenting: controller.dialog) { dialog in
            if dialog.kind == .prompt { TextField("Response", text: $controller.dialogText) }
            Button("OK") { controller.answerDialog(dialog.kind == .prompt ? controller.dialogText : "yes") }
            if dialog.kind != .alert { Button("Cancel", role: .cancel) { controller.answerDialog(nil) } }
        } message: { dialog in Text(dialog.message) }
        .alert(title, isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .onDisappear { controller.cleanupImports() }
    }
}

extension ToolCyberChefController {
    func offerExportForSharing(_ source: URL) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NomadWeb-source-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: file)
            offerExport(file)
        } catch { self.error = error.localizedDescription }
    }
}
