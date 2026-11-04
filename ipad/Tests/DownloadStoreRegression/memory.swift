import Foundation
import Darwin

/// No requests should be needed: this exercises recovery of a completed pending payload.
private final class ForbiddenNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { fatalError("The sparse-file recovery test attempted a network request") }
    override func stopLoading() {}
}

private func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw NSError(domain: "task_info", code: Int(result)) }
    return info.resident_size
}

private func fileStat(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return value
}

@main struct DownloadMemoryRegression {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NomadDownloadMemory-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Pending"), withIntermediateDirectories: true)
        // Same logical byte count as the reported large download. ftruncate creates holes,
        // so this reads real 19.1 GB through FileHandle without consuming 19.1 GB of disk.
        let byteCount: Int64 = 19_095_710_684
        // Independently calculated with Python hashlib/OpenSSL and a reused zero buffer.
        let digest = "f5d49be81f1efdca0e56638a48c1b673dd3f410f88146288c27d43eda1cdd7cc"
        let id = UUID(), pausedID = UUID()
        let item = ContentDownload(id: id, url: URL(string: "https://example.org/sparse.zim")!,
            name: "Sparse memory fixture", filename: "\(id.uuidString).zim", sha256: digest,
            expectedBytes: byteCount, state: .verifying, received: byteCount, expected: byteCount)
        let paused = ContentDownload(id: pausedID, url: URL(string: "https://example.org/paused.zim")!,
            name: "Preserved manual pause", filename: "\(pausedID.uuidString).zim", sha256: nil,
            expectedBytes: 1, state: .paused)
        let pending = root.appendingPathComponent("Pending/\(id.uuidString).download")
        let fd = open(pending.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let truncated = ftruncate(fd, byteCount), savedErrno = errno
        close(fd)
        guard truncated == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedErrno)) }
        let originalStat = try fileStat(pending)
        precondition(originalStat.st_size == byteCount && originalStat.st_blocks * 512 < 1_048_576,
                     "The fixture must be sparse, with less than 1 MiB of allocated file blocks")
        try JSONEncoder().encode([paused, item]).write(to: root.appendingPathComponent("downloads.json"))
        func configuration() -> URLSessionConfiguration {
            let value = URLSessionConfiguration.ephemeral
            value.protocolClasses = [ForbiddenNetwork.self]
            return value
        }
        let store = DownloadStore(rootURL: root, sessionConfiguration: configuration(), reconnectTasks: false)
        precondition(store.canWrite && store.items.count == 2)
        let initial = try residentBytes()
        var peak = initial
        let started = Date()
        store.reconcile(tasks: [])
        precondition(store.items.first(where: { $0.id == id })?.state == .verifying)
        store.remove(id) // Removal must remain blocked while the verifier owns the file.
        precondition(store.items.count == 2 && fm.fileExists(atPath: pending.path))
        while store.items.first(where: { $0.id == id })?.state == .verifying {
            peak = max(peak, try residentBytes())
            // Fail early if a regression brings back one retained buffer per MiB; never
            // allow the test to accumulate the logical file's full size in RAM.
            if peak > initial + 128 * 1_024 * 1_024 || Date().timeIntervalSince(started) > 180 {
                fputs("FAIL: hashing exceeded 128 MiB RSS growth or 180 seconds; peak=\(peak), initial=\(initial)\n", stderr)
                try? fm.removeItem(at: root)
                exit(EXIT_FAILURE)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        peak = max(peak, try residentBytes())
        let ready = try store.completedFile(id)
        precondition(ready.expectedBytes == UInt64(byteCount))
        precondition(store.items.first(where: { $0.id == id })?.message == "SHA-256 verified.")
        precondition(store.items.first(where: { $0.id == pausedID })?.state == .paused)
        let movedStat = try fileStat(ready.url)
        precondition(movedStat.st_ino == originalStat.st_ino && movedStat.st_dev == originalStat.st_dev,
                     "Verification must move the completed bytes, not rewrite or duplicate them")
        precondition(movedStat.st_size == byteCount && movedStat.st_blocks * 512 < 1_048_576)
        precondition(!fm.fileExists(atPath: pending.path))
        let reopened = DownloadStore(rootURL: root, sessionConfiguration: configuration(), reconnectTasks: false)
        reopened.reconcile(tasks: [])
        precondition(reopened.items.first(where: { $0.id == id })?.state == .ready)
        precondition(reopened.items.first(where: { $0.id == pausedID })?.state == .paused)
        precondition(peak <= initial + 128 * 1_024 * 1_024)
        print("PASS: production SHA-256 verified \(byteCount) sparse bytes; initialRSS=\(initial), peakRSS=\(peak), growth=\(peak - initial), seconds=\(Date().timeIntervalSince(started)); recovered verifying entry, same inode, manual pause preserved, ready survives relaunch")
    }
}
