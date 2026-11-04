import SwiftUI

struct StorageAuditView: View {
    @State private var report: StorageAuditReport?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?
    @State private var export: URL?
    var body: some View {
        List {
            Section {
                Text("Counts native app files without opening their contents. Downloads continue during the scan, so the result is a snapshot. Apple-managed language models, the app binary, Keychain, system caches and external Files locations are excluded.")
                Button(busy ? "Scanning…" : "Refresh storage report", systemImage: "arrow.clockwise") { scan() }.disabled(busy)
                if busy { ProgressView(); Button("Cancel") { task?.cancel() } }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            if let report {
                Section("This app’s native files") {
                    LabeledContent("Unique file data", value: bytes(report.uniqueFileBytes))
                    LabeledContent("Allocated storage estimate", value: bytes(report.allocatedBytesEstimate))
                    if let free = report.freeBytesEstimate { LabeledContent("Available storage estimate", value: bytes(free)) }
                    Text("Measured \(report.measuredAt.formatted()). Shared hardlinks are counted once in the totals. Per-module sizes can include the same shared archive. APFS compression, clones and system accounting can differ from these estimates.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Export storage report", systemImage: "square.and.arrow.up") {
                        do {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NOMAD-storage-report.json")
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            try encoder.encode(report).write(to: url, options: .atomic); export = url
                        } catch { self.error = error.localizedDescription }
                    }
                    if let export { ShareLink("Share report", item: export) }
                }
                Section("Files by module") {
                    ForEach(report.categories) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent(category.title, value: bytes(category.logicalBytes))
                            Text("\(category.fileCount) files").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !report.warnings.isEmpty { Section("Scan notes") { ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.orange) } } }
            }
        }
        .navigationTitle("Storage report")
        .task { scan() }
        .onDisappear { task?.cancel() }
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func scan() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            let worker = Task.detached(priority: .utility) { try StorageAudit.scan() }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); report = value; export = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
