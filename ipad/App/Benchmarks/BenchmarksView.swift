import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BenchmarksView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = NativeBenchmarkStore.shared
    @State private var exporting = false
    @State private var export = BenchmarkJSONDocument(data: Data())
    @State private var deleting: NativeBenchmarkResult?
    var body: some View {
        List {
            Section("Local iPad measurements") {
                Text("A short, single-worker SHA-256 workload and a 64 MiB temporary file write/read. Results stay on this device until you export them.")
                TextField("Builder tag (optional)", text: $store.builderTag).disabled(store.isRunning)
                if let progress = store.progress {
                    ProgressView(value: progress.fraction) { Text(progress.message) }
                    Button("Cancel benchmark", role: .destructive) { store.cancel() }
                } else {
                    Button { store.run() } label: { Label("Run CPU and storage checks", systemImage: "gauge.with.dots.needle.67percent") }.disabled(!store.canWrite)
                }
                if let error = store.error { Text(error).foregroundStyle(.orange).font(.callout) }
                if !store.canWrite && FileManager.default.fileExists(atPath: store.historyURL.path) {
                    ShareLink(item: store.historyURL) { Label("Export preserved history file", systemImage: "square.and.arrow.up") }
                }
            }
            if let latest = store.latest {
                Section("Latest run") { BenchmarkResultSummary(result: latest) }
            }
            Section("Saved results · last 100") {
                ForEach(store.results) { result in
                    NavigationLink {
                        BenchmarkResultDetail(result: result)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.builderTag.isEmpty ? result.date.formatted(date: .abbreviated, time: .shortened) : result.builderTag).font(.headline)
                            Text("SHA-256 \(result.measurements.cpuMiBPerSecond.formatted(.number.precision(.fractionLength(1)))) MiB/s · \(result.before.hardwareIdentifier)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("Delete", role: .destructive) { deleting = result }.disabled(store.isRunning) }
                }
                if store.results.isEmpty { Text("No saved measurements yet.").foregroundStyle(.secondary) }
                Button {
                    do { export = BenchmarkJSONDocument(data: try store.exportData()); exporting = true }
                    catch { store.error = error.localizedDescription }
                } label: { Label("Export results as JSON", systemImage: "square.and.arrow.up") }.disabled(store.results.isEmpty)
            }
            Section("How to read these results") {
                Text("SHA-256 repeats a changing 1 MiB block on one worker for about 2 seconds, capped at 8,192 hashes. This measures CryptoKit's SHA-256 implementation, including hardware acceleration.")
                Text("Storage writes 64 MiB, synchronizes the file, then reads it while verifying SHA-256. The operating system may serve reads from cache. These are app-level timings, not raw flash specifications.")
                Text("Temperature, Low Power Mode, other apps, and simulator use affect the result. Keep the app in the foreground; backgrounding cancels a running benchmark. This workload has no NOMAD desktop score or leaderboard equivalence. Temporary data is removed after completion or cancellation.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Benchmarks")
        .onChange(of: scenePhase) { _, phase in if phase == .background { store.cancel() } }
        .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "nomad-apple-benchmarks") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .confirmationDialog("Delete this saved benchmark?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete result", role: .destructive) { if let result = deleting { store.delete(result.id) }; deleting = nil }
        }
    }
}

private struct BenchmarkResultSummary: View {
    let result: NativeBenchmarkResult
    var body: some View {
        LabeledContent("SHA-256", value: "\(result.measurements.cpuMiBPerSecond.formatted(.number.precision(.fractionLength(1)))) MiB/s")
        LabeledContent("Write + synchronize", value: "\(result.measurements.writeMiBPerSecond.formatted(.number.precision(.fractionLength(1)))) MiB/s")
        LabeledContent("Read + SHA-256 verify", value: "\(result.measurements.readVerifyMiBPerSecond.formatted(.number.precision(.fractionLength(1)))) MiB/s")
    }
}

private struct BenchmarkResultDetail: View {
    let result: NativeBenchmarkResult
    var body: some View {
        List {
            Section("Measured throughput") { BenchmarkResultSummary(result: result) }
            Section("Device and conditions") {
                LabeledContent("Hardware", value: result.before.hardwareIdentifier)
                if let simulator = result.before.simulatorModel { LabeledContent("Simulator model", value: simulator) }
                LabeledContent("OS", value: result.before.osVersion)
                LabeledContent("Physical memory", value: ByteCountFormatter.string(fromByteCount: Int64(result.before.physicalMemoryBytes), countStyle: .memory))
                LabeledContent("Logical processors", value: "\(result.before.logicalProcessorCount)")
                LabeledContent("Thermal state", value: "\(result.before.thermalState) → \(result.after.thermalState)")
                LabeledContent("Low Power Mode", value: "\(result.before.lowPowerMode ? "On" : "Off") → \(result.after.lowPowerMode ? "On" : "Off")")
                LabeledContent("Run time", value: result.date.formatted())
                if !result.builderTag.isEmpty { LabeledContent("Builder tag", value: result.builderTag) }
                LabeledContent("App version", value: result.before.appVersion)
            }
            Section("Workload v\(result.workloadVersion)") {
                LabeledContent("CPU hashes", value: result.measurements.cpuHashes.formatted())
                LabeledContent("CPU elapsed", value: "\(result.measurements.cpuSeconds.formatted(.number.precision(.fractionLength(3)))) s")
                LabeledContent("Temporary file", value: ByteCountFormatter.string(fromByteCount: result.measurements.storageBytes, countStyle: .memory))
                Text("Read timing includes SHA-256 verification and may reflect cached data. No desktop NOMAD comparison or leaderboard submission is performed.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Benchmark result")
    }
}

private struct BenchmarkJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
