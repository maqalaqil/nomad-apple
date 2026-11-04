import Foundation
import Observation
import Darwin

struct NativeBenchmarkDevice: Codable, Sendable {
    let hardwareIdentifier: String
    let simulatorModel: String?
    let osVersion: String
    let physicalMemoryBytes: UInt64
    let logicalProcessorCount: Int
    let activeProcessorCount: Int
    let lowPowerMode: Bool
    let thermalState: String
    let appVersion: String
    var valid: Bool {
        physicalMemoryBytes <= UInt64(Int64.max) && (1...4_096).contains(logicalProcessorCount) &&
        (0...logicalProcessorCount).contains(activeProcessorCount)
    }
    static func capture() -> Self {
        var system = utsname(); uname(&system)
        let hardware = withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "unknown" }
        return Self(hardwareIdentifier: hardware, simulatorModel: process.environment["SIMULATOR_MODEL_IDENTIFIER"],
                    osVersion: process.operatingSystemVersionString, physicalMemoryBytes: process.physicalMemory,
                    logicalProcessorCount: process.processorCount, activeProcessorCount: process.activeProcessorCount,
                    lowPowerMode: process.isLowPowerModeEnabled, thermalState: thermal,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
    }
}

struct NativeBenchmarkResult: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let workloadVersion: Int
    let builderTag: String
    let configuration: NativeBenchmarkConfiguration
    let before: NativeBenchmarkDevice
    let after: NativeBenchmarkDevice
    let measurements: NativeBenchmarkMeasurements
    var valid: Bool {
        workloadVersion == 1 && configuration.valid && measurements.valid && before.valid && after.valid &&
        builderTag.count <= 120 && measurements.cpuHashes <= configuration.maximumHashes &&
        measurements.cpuBytes == Int64(measurements.cpuHashes) * Int64(configuration.blockBytes) &&
        measurements.storageBytes == Int64(configuration.storageBytes)
    }
}

private struct NativeBenchmarkHistory: Codable {
    let schemaVersion: Int
    let results: [NativeBenchmarkResult]
}

@MainActor @Observable
final class NativeBenchmarkStore {
    static let shared = NativeBenchmarkStore()
    private(set) var results: [NativeBenchmarkResult] = []
    private(set) var progress: NativeBenchmarkProgress?
    private(set) var latest: NativeBenchmarkResult?
    private(set) var canWrite = true
    var error: String?
    var builderTag = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    let root: URL
    var historyURL: URL { root.appendingPathComponent("history.json") }
    private var temporaryRoot: URL { root.appendingPathComponent("Temporary", isDirectory: true) }
    var isRunning: Bool { task != nil }
    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appendingPathComponent("NomadPad/Benchmarks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            // Recover only this module's uniquely named temporary runs after interruption.
            for url in try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("run-") && UUID(uuidString: String(url.lastPathComponent.dropFirst(4))) != nil {
                try FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let data = try Data(contentsOf: historyURL)
                guard data.count <= 4_000_000 else { throw NativeBenchmarkFailure(message: "Saved benchmark history exceeds 4 MB.") }
                let history = try JSONDecoder().decode(NativeBenchmarkHistory.self, from: data)
                guard history.schemaVersion == 1, history.results.count <= 100,
                      Set(history.results.map(\.id)).count == history.results.count,
                      history.results.allSatisfy(\.valid) else {
                    throw NativeBenchmarkFailure(message: "Saved benchmark history contains invalid results.")
                }
                results = history.results
            }
        } catch { self.error = "Benchmark storage could not be opened. Existing history has been preserved. \(error.localizedDescription)"; canWrite = false }
    }
    func run(configuration: NativeBenchmarkConfiguration = .init()) {
        guard !isRunning, canWrite else { return }
        let id = UUID(), before = NativeBenchmarkDevice.capture(), tag = String(builderTag.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        runID = id; error = nil; latest = nil; progress = .init(message: "Preparing local workload", fraction: 0)
        let directory = temporaryRoot
        task = Task { [self] in
            defer { task = nil; runID = nil; progress = nil }
            let worker = Task.detached(priority: .userInitiated) {
                try NativeBenchmarkEngine.run(configuration: configuration, temporaryRoot: directory) { [weak self] value in
                    Task { @MainActor in if self?.runID == id { self?.progress = value } }
                }
            }
            do {
                let measurements = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                let result = NativeBenchmarkResult(id: id, date: Date(), workloadVersion: 1, builderTag: tag,
                    configuration: configuration, before: before, after: NativeBenchmarkDevice.capture(), measurements: measurements)
                latest = result
                let next = Array(([result] + results).prefix(100))
                do { try save(next) }
                catch { throw NativeBenchmarkFailure(message: "Benchmark finished, but its result could not be saved: \(error.localizedDescription)") }
                results = next
            } catch is CancellationError { self.error = "Benchmark cancelled. Temporary data was removed; no result was saved." }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func delete(_ id: UUID) {
        guard canWrite, !isRunning else { return }
        do { let next = results.filter { $0.id != id }; try save(next); results = next }
        catch { self.error = error.localizedDescription }
    }
    func exportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(NativeBenchmarkHistory(schemaVersion: 1, results: results))
    }
    private func save(_ results: [NativeBenchmarkResult]) throws {
        guard canWrite else { throw NativeBenchmarkFailure(message: "Saved benchmark history is unreadable and has been preserved.") }
        let data = try JSONEncoder().encode(NativeBenchmarkHistory(schemaVersion: 1, results: results))
        guard data.count <= 4_000_000 else { throw NativeBenchmarkFailure(message: "Benchmark history is full.") }
        try data.write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
