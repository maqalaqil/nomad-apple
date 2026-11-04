import Foundation
import AppKit
import WebKit
import CryptoKit
import Darwin

// Same bridge conformance as the app's ZIMReaderView; every bridge operation synchronizes archive access.
extension NomadZIMArchive: @unchecked Sendable {}

struct MemoryFailure: Error { let message: String }
struct MemorySample {
    let rss: UInt64
    let footprint: UInt64
    static func read() -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return .init(rss: UInt64(info.resident_size), footprint: info.phys_footprint)
    }
}
final class MemoryGauge: @unchecked Sendable {
    let initial = MemorySample.read()
    private let lock = NSLock()
    private var maximumRSS: UInt64 = 0, maximumFootprint: UInt64 = 0
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nomad.test.memory"))
    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }; timer.resume()
    }
    deinit { timer.cancel() }
    func sample() { let current = MemorySample.read(); lock.lock(); maximumRSS = max(maximumRSS, current.rss); maximumFootprint = max(maximumFootprint, current.footprint); lock.unlock() }
    func finish(_ mode: String, bytes: Int64) throws {
        sample(); timer.cancel(); lock.lock(); let rss = maximumRSS, footprint = maximumFootprint; lock.unlock()
        let growth = footprint > initial.footprint ? footprint - initial.footprint : 0
        print("\(mode): bytes=\(bytes) RSS-growth=\(rss > initial.rss ? rss - initial.rss : 0) physical-footprint-growth=\(growth)")
        // ZIM memory maps clean archive pages: RSS includes those reclaimable pages. Private
        // physical footprint distinguishes actual retained NSData buffers from file mappings.
        guard growth < 96 * 1_024 * 1_024 else { throw MemoryFailure(message: "Large reader retained over 96 MiB beyond its baseline") }
    }
}
@MainActor final class Consumer: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    let memory: MemoryGauge
    var bytes: Int64 = 0
    var maximumChunk = 0
    var digest = SHA256()
    var done: ((Error?) -> Void)?
    init(url: URL, memory: MemoryGauge) { request = URLRequest(url: url); self.memory = memory }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { bytes += Int64(data.count); maximumChunk = max(maximumChunk, data.count); digest.update(data: data); memory.sample() }
    func didFinish() { let completion = done; done = nil; completion?(nil) }
    func didFailWithError(_ error: Error) { let completion = done; done = nil; completion?(error) }
}
@main struct LargeReaderMemoryRegression {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedBytes = Int64(CommandLine.arguments[3])!
        if mode == "course" {
            try await Task.detached {
                try autoreleasepool {
                    let memory = MemoryGauge()
                    let prepared = try CourseChannelImporter.prepare(selected: root.appendingPathComponent("export"), storageRoot: root.appendingPathComponent("course-output"))
                    guard prepared.count == 1, prepared[0].course.byteCount == expectedBytes,
                          prepared[0].course.copiedFileCount == 1 else { throw MemoryFailure(message: "Production course copy did not verify the complete synthetic asset") }
                    try memory.finish("Course production copy+MD5", bytes: expectedBytes)
                }
            }.value
        } else {
            _ = NSApplication.shared
            let archive = try NomadZIMArchive(url: root.appendingPathComponent("large.zim"))
            let handler = ZIMSchemeHandler(archive: archive), webView = WKWebView(frame: .zero)
            let memory = MemoryGauge()
            let consumer = Consumer(url: ZIMSchemeHandler.url(path: "test.bin")!, memory: memory)
            // One gauge samples the entire handler job; the mock consumer hashes/discards each
            // buffer synchronously without retaining any payload arrays.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                consumer.done = { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                handler.webView(webView, start: consumer)
            }
            let hash = consumer.digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard consumer.bytes == expectedBytes, consumer.maximumChunk <= 256 * 1_024,
                  hash == CommandLine.arguments[4] else { throw MemoryFailure(message: "Production ZIM stream failed byte count, chunk bound or SHA-256") }
            try memory.finish("ZIM production bridge+scheme consumer", bytes: consumer.bytes)
            _ = handler; _ = webView
        }
        print("PASS: actual production large-reader path completed with bounded retained memory")
    }
}
