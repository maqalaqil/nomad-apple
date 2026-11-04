import Foundation
import CryptoKit

struct NativeBenchmarkConfiguration: Codable, Equatable, Sendable {
    var cpuSeconds: Double = 2
    var maximumHashes: Int = 8_192
    var blockBytes: Int = 1_048_576
    var storageBytes: Int = 64 * 1_048_576
    var valid: Bool {
        cpuSeconds.isFinite && cpuSeconds > 0 && cpuSeconds <= 10 &&
        (1...8_192).contains(maximumHashes) && (4_096...1_048_576).contains(blockBytes) &&
        storageBytes >= blockBytes && storageBytes <= 256 * 1_048_576 && storageBytes % blockBytes == 0
    }
}

struct NativeBenchmarkProgress: Sendable {
    let message: String
    let fraction: Double
}

struct NativeBenchmarkMeasurements: Codable, Sendable {
    let cpuHashes: Int
    let cpuBytes: Int64
    let cpuSeconds: Double
    let storageBytes: Int64
    let writeSeconds: Double
    let readVerifySeconds: Double
    let cpuLastDigest: String
    let storageDigest: String
    var cpuMiBPerSecond: Double { Double(cpuBytes) / 1_048_576 / cpuSeconds }
    var writeMiBPerSecond: Double { Double(storageBytes) / 1_048_576 / writeSeconds }
    var readVerifyMiBPerSecond: Double { Double(storageBytes) / 1_048_576 / readVerifySeconds }
    var valid: Bool {
        cpuHashes > 0 && cpuBytes > 0 && storageBytes > 0 &&
        [cpuSeconds, writeSeconds, readVerifySeconds].allSatisfy { $0.isFinite && $0 > 0 } &&
        [cpuLastDigest, storageDigest].allSatisfy { $0.count == 64 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }
    }
}

struct NativeBenchmarkFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum NativeBenchmarkEngine {
    /// Synchronous work; call from a detached task. One worker, at most 1 MiB buffers and 64 MiB disk with default settings.
    static func run(configuration: NativeBenchmarkConfiguration = .init(), temporaryRoot: URL,
                    progress: @Sendable (NativeBenchmarkProgress) -> Void = { _ in }) throws -> NativeBenchmarkMeasurements {
        guard configuration.valid else { throw NativeBenchmarkFailure(message: "Invalid benchmark workload parameters.") }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let available = (try? temporaryRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ??
            ((try? manager.attributesOfFileSystem(forPath: temporaryRoot.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
        guard available > Int64(configuration.storageBytes) + 512 * 1_024 * 1_024 else {
            throw NativeBenchmarkFailure(message: "Keep at least 512 MB free beyond the temporary benchmark file before running.")
        }
        let directory = temporaryRoot.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let result = try measure(configuration, directory: directory, progress: progress)
            try manager.removeItem(at: directory)
            return result
        } catch {
            do { try manager.removeItem(at: directory) }
            catch { throw NativeBenchmarkFailure(message: "Benchmark stopped, but temporary data could not be removed: \(error.localizedDescription)") }
            throw error
        }
    }

    private static func measure(_ configuration: NativeBenchmarkConfiguration, directory: URL,
                                progress: @Sendable (NativeBenchmarkProgress) -> Void) throws -> NativeBenchmarkMeasurements {
        var block = Data((0..<configuration.blockBytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        var hashes = 0, lastDigest = ""
        let cpuStart = ProcessInfo.processInfo.systemUptime
        var cpuElapsed = 0.0, lastUpdate = cpuStart
        progress(.init(message: "CPU: SHA-256 on one worker", fraction: 0))
        repeat {
            try Task.checkCancellation()
            var counter = UInt64(hashes).littleEndian
            withUnsafeBytes(of: &counter) { block.replaceSubrange(0..<8, with: $0) }
            let digest = SHA256.hash(data: block)
            hashes += 1
            cpuElapsed = ProcessInfo.processInfo.systemUptime - cpuStart
            if hashes == configuration.maximumHashes || cpuElapsed >= configuration.cpuSeconds { lastDigest = hex(digest) }
            if ProcessInfo.processInfo.systemUptime - lastUpdate >= 0.1 {
                progress(.init(message: "CPU: \(hashes) SHA-256 hashes", fraction: 0.5 * min(1, cpuElapsed / configuration.cpuSeconds)))
                lastUpdate = ProcessInfo.processInfo.systemUptime
            }
        } while hashes < configuration.maximumHashes && cpuElapsed < configuration.cpuSeconds
        try Task.checkCancellation()
        // Calculate the expected file digest outside the timed I/O phases.
        var expected = SHA256()
        for _ in 0..<(configuration.storageBytes / configuration.blockBytes) {
            try Task.checkCancellation(); expected.update(data: block)
        }
        let expectedDigest = hex(expected.finalize())
        let file = directory.appendingPathComponent("storage.bin")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw NativeBenchmarkFailure(message: "The temporary storage file could not be created.") }
        let writer = try FileHandle(forWritingTo: file)
        let writeStart = ProcessInfo.processInfo.systemUptime
        do {
            for offset in stride(from: 0, to: configuration.storageBytes, by: configuration.blockBytes) {
                try Task.checkCancellation()
                try writer.write(contentsOf: block)
                if offset % (8 * configuration.blockBytes) == 0 {
                    progress(.init(message: "Storage: writing temporary file", fraction: 0.5 + 0.25 * Double(offset) / Double(configuration.storageBytes)))
                }
            }
            try writer.synchronize()
            try writer.close()
        } catch { try? writer.close(); throw error }
        let writeSeconds = ProcessInfo.processInfo.systemUptime - writeStart
        try Task.checkCancellation()
        let reader = try FileHandle(forReadingFrom: file)
        let readStart = ProcessInfo.processInfo.systemUptime
        var readBytes = 0, actual = SHA256()
        do {
            while let data = try reader.read(upToCount: configuration.blockBytes), !data.isEmpty {
                try Task.checkCancellation()
                actual.update(data: data); readBytes += data.count
                if readBytes % (8 * configuration.blockBytes) == 0 {
                    progress(.init(message: "Storage: reading and verifying SHA-256", fraction: 0.75 + 0.25 * Double(readBytes) / Double(configuration.storageBytes)))
                }
            }
            try reader.close()
        } catch { try? reader.close(); throw error }
        let readSeconds = ProcessInfo.processInfo.systemUptime - readStart
        let actualDigest = hex(actual.finalize())
        guard readBytes == configuration.storageBytes, actualDigest == expectedDigest else {
            throw NativeBenchmarkFailure(message: "The temporary storage file failed its integrity check.")
        }
        try Task.checkCancellation()
        progress(.init(message: "Removing temporary benchmark data", fraction: 1))
        return NativeBenchmarkMeasurements(cpuHashes: hashes, cpuBytes: Int64(hashes) * Int64(configuration.blockBytes),
            cpuSeconds: cpuElapsed, storageBytes: Int64(readBytes), writeSeconds: writeSeconds, readVerifySeconds: readSeconds,
            cpuLastDigest: lastDigest, storageDigest: actualDigest)
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}
