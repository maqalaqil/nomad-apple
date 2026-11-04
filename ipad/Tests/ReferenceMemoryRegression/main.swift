import Foundation
import Darwin

private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() { lock.lock(); finished = true; lock.unlock() }
    func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

@main struct ReferenceMemoryRegression {
    static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw DrugReferenceError.message("Could not measure RSS") }
        return info.resident_size
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-reference-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("TEST-ONLY-labels.json")
        let records = 50_000
        try await Task.detached {
            guard FileManager.default.createFile(atPath: source.path, contents: nil) else { throw DrugReferenceError.message("Cannot create fixture") }
            let writer = try FileHandle(forWritingTo: source); defer { try? writer.close() }
            try writer.write(contentsOf: Data(#"{"meta":{"last_updated":"2026-11-04"},"results":["#.utf8))
            for index in 0..<records {
                try autoreleasepool {
                    let label: [String: Any] = ["set_id": "TEST_ONLY_\(index)", "id": "TEST_REVISION_\(index)", "version": "1", "effective_time": "20261104",
                        "openfda": ["brand_name": ["TEST-ONLY MEMORY FIXTURE"], "generic_name": ["SYNTHETIC NONCLINICAL"],
                                    "manufacturer_name": ["TEST-ONLY"], "product_type": ["HUMAN OTC DRUG"]],
                        "indications_and_usage": ["TEST ONLY. No clinical meaning or recommendation."],
                        "warnings": ["SYNTHETIC LABEL \(index). Not a medical dataset."],
                        "drug_interactions": ["TEST ONLY. This content must never ship as medical information."]]
                    if index > 0 { try writer.write(contentsOf: Data([44])) }
                    try writer.write(contentsOf: JSONSerialization.data(withJSONObject: label, options: .sortedKeys))
                }
            }
            try writer.write(contentsOf: Data("]}".utf8)); try writer.synchronize()
        }.value
        let repository = DrugReferenceRepository(storageRoot: root.appendingPathComponent("Store"))
        let completed = Completion(), baseline = try residentBytes(), started = Date()
        var peak = baseline
        let operation = Task.detached {
            defer { completed.finish() }
            return try await repository.prepareImport([source])
        }
        while !completed.isFinished() {
            peak = max(peak, try residentBytes())
            if peak > baseline + 96 * 1_024 * 1_024 || Date().timeIntervalSince(started) > 150 {
                operation.cancel()
                _ = try? await operation.value
                throw DrugReferenceError.message("Reference import exceeded RSS/time bound: baseline=\(baseline), peak=\(peak)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prepared = try await operation.value
        peak = max(peak, try residentBytes())
        guard prepared.labelCount == records, try await repository.current() == nil,
              prepared.exportDate == "2026-11-04", peak <= baseline + 96 * 1_024 * 1_024 else {
            throw DrugReferenceError.message("Synthetic import count, metadata, staging or memory assertion failed")
        }
        _ = try await repository.activate(prepared)
        let found = try await repository.search("memory fixture", indications: false, otcOnly: true)
        guard found.count == 1, found[0].labelCount == records,
              try await repository.detail(id: found[0].id).fields["warnings"] == "SYNTHETIC LABEL 0. Not a medical dataset." else {
            throw DrugReferenceError.message("Imported grouped search or source text was not retained")
        }
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("PASS: production Reference imported \(records) synthetic nonclinical records; inputBytes=\(bytes), baselineRSS=\(baseline), peakRSS=\(peak), growth=\(peak - baseline), seconds=\(Date().timeIntervalSince(started)); staging, metadata, grouping and exact source warning preserved")
    }
}
