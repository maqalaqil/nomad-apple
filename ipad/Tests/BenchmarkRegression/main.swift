import Foundation

@main struct BenchmarkRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadBenchmarkRegression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = NativeBenchmarkConfiguration(cpuSeconds: 0.02, maximumHashes: 32, blockBytes: 65_536, storageBytes: 1_048_576)
        let scratch = root.appendingPathComponent("scratch")
        let measured = try await Task.detached { try NativeBenchmarkEngine.run(configuration: configuration, temporaryRoot: scratch) }.value
        precondition(measured.valid && measured.cpuHashes > 0 && measured.storageBytes == 1_048_576)
        precondition(measured.cpuBytes == Int64(measured.cpuHashes * configuration.blockBytes))
        let scratchFiles = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        precondition(scratchFiles.isEmpty)
        let cancelled = Task.detached { try NativeBenchmarkEngine.run(temporaryRoot: scratch) }
        try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation did not stop CPU work") } catch is CancellationError {}
        let afterCancellation = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        precondition(afterCancellation.isEmpty)
        let storage = root.appendingPathComponent("history")
        let store = NativeBenchmarkStore(root: storage)
        store.builderTag = "Fixture builder"
        store.run(configuration: configuration)
        for _ in 0..<500 { if !store.isRunning { break }; try await Task.sleep(for: .milliseconds(10)) }
        precondition(!store.isRunning && store.results.count == 1 && store.error == nil)
        let restored = NativeBenchmarkStore(root: storage)
        precondition(restored.canWrite && restored.results.count == 1 && restored.results[0].builderTag == "Fixture builder")
        let exported = try restored.exportData()
        let json = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        precondition((json["results"] as? [[String: Any]])?.count == 1)
        // Atomic write failure must leave the prior in-memory history intact.
        try FileManager.default.removeItem(at: restored.historyURL)
        try FileManager.default.createDirectory(at: restored.historyURL, withIntermediateDirectories: false)
        restored.delete(restored.results[0].id)
        precondition(restored.results.count == 1 && restored.error != nil)
        try FileManager.default.removeItem(at: restored.historyURL)
        let corrupt = Data("Preserve this invalid original".utf8)
        try corrupt.write(to: restored.historyURL)
        let blocked = NativeBenchmarkStore(root: storage)
        precondition(!blocked.canWrite && blocked.error != nil)
        blocked.run(configuration: configuration)
        precondition(!blocked.isRunning)
        let preserved = try Data(contentsOf: blocked.historyURL)
        precondition(preserved == corrupt)
        let stale = storage.appendingPathComponent("Temporary/run-\(UUID())")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: stale.appendingPathComponent("storage.bin"))
        _ = NativeBenchmarkStore(root: storage)
        precondition(!FileManager.default.fileExists(atPath: stale.path))
        print("PASS: real bounded CPU/storage measurements, digest integrity, cancellation cleanup, history reload/JSON export, atomic deletion rollback, corrupt history preservation, interrupted-run cleanup")
    }
}
