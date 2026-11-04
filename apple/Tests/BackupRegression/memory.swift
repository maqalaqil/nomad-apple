import Foundation
import CryptoKit
import Darwin

/// Real production I/O with synthetic temporary bytes; no app container or device access.
@main struct BackupMemoryRegression {
    final class Sample: @unchecked Sendable {
        let baseline: UInt64
        var peak: UInt64
        var bytes: UInt64 = 0
        var error: Error?
        init() throws { baseline = try Self.residentBytes(); peak = baseline }
        func record(_ bytes: UInt64) {
            self.bytes += bytes
            do { peak = max(peak, try Self.residentBytes()) } catch { self.error = error }
        }
        static func residentBytes() throws -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { throw BackupFailure("RSS query failed: \(result)") }
            return info.resident_size
        }
    }

    static func main() async throws {
        try await Task.detached(priority: .utility) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-backup-memory-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("TEST-ONLY-sparse.bin")
            let byteCount: UInt64 = 512 * 1_024 * 1_024
            guard FileManager.default.createFile(atPath: source.path, contents: nil) else { throw BackupFailure("Could not create fixture") }
            let writer = try FileHandle(forWritingTo: source)
            try writer.truncate(atOffset: byteCount); try writer.close()
            let expected: String = autoreleasepool {
                let block = Data(repeating: 0, count: 1_024 * 1_024)
                var digest = SHA256()
                for _ in 0..<512 { digest.update(data: block) }
                return digest.finalize().map { String(format: "%02x", $0) }.joined()
            }
            for copies in [false, true] {
                // One outer pool models a long synchronous worker job. Production code
                // must release per-chunk bridging objects before this outer pool drains.
                try autoreleasepool {
                    let sample = try Sample(), started = Date()
                    let destination = copies ? root.appendingPathComponent("TEST-ONLY-copy.bin") : nil
                    let digest = try BackupFileIO.copyAndHash(source, to: destination, expected: byteCount, progress: { sample.record($0) })
                    if let error = sample.error { throw error }
                    guard digest == expected, sample.bytes == byteCount else { throw BackupFailure("Streaming integrity mismatch") }
                    let growth = sample.peak > sample.baseline ? sample.peak - sample.baseline : 0
                    guard growth < 64 * 1_024 * 1_024 else { throw BackupFailure("Unbounded backup RSS growth: \(growth) for \(byteCount) bytes") }
                    if let destination {
                        guard try BackupFileIO.fingerprint(destination).size == Int64(byteCount) else { throw BackupFailure("Wrong output size") }
                    }
                    print("PASS: production backup \(copies ? "copy+hash" : "hash-only"); bytes=\(sample.bytes), baselineRSS=\(sample.baseline), peakRSS=\(sample.peak), growth=\(growth), seconds=\(Date().timeIntervalSince(started))")
                }
            }
        }.value
    }
}
