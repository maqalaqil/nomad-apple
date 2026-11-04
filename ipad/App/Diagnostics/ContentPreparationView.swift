#if DEBUG
import SwiftUI

/// Explicit development launch action for the collection the user requested.
/// Normal launches never queue content automatically.
struct ContentPreparationView: View {
    @State private var status = "Waiting for the saved download session…"
    @State private var finished = false
    @State private var failed = false
    private let store = DownloadStore.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Arabic + English + worldwide maps").font(.title2.bold())
                if !finished { ProgressView() }
                Text(status).foregroundStyle(failed ? .orange : .primary)
                Text("This launch action uses the same catalog, storage preflight and serial download queue as the app. Closing this screen does not cancel already queued downloads.").foregroundStyle(.secondary)
            }.padding(30).navigationTitle("Content preparation")
                .task { await prepare() }
        }
    }

    @MainActor private func prepare() async {
        guard !finished else { return }
        do {
            for _ in 0..<60 {
                try Task.checkCancellation()
                if !store.isReconnecting { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            try Task.checkCancellation()
            guard !store.isReconnecting else { throw CatalogError.message("Download session restoration is taking longer than expected. Reopen the app and try again.") }
            status = try OfflineContentCatalog.queueFullCollection(store: store)
            saveReport(status: "queued-or-already-present", message: status)
        } catch {
            failed = true
            status = error is CancellationError ? "Preparation canceled before completion." : error.localizedDescription
            saveReport(status: "not-completed", message: status)
        }
        finished = true
    }

    private func saveReport(status: String, message: String) {
        do {
            let record = ["status": status, "message": message, "at": ISO8601DateFormatter().string(from: Date())]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL.documentsDirectory.appendingPathComponent("nomad-content-preparation.json"), options: .atomic)
        } catch { self.status += "\nCould not save the preparation report: \(error.localizedDescription)" }
    }
}
#endif
