import Foundation
import CryptoKit

// Requests are deliberately held in-process. No network or large fixture is used.
private final class HeldDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@main struct DownloadStoreRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadDownloadRegression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("A verified local archive".utf8)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        func fixture(_ name: String, suffix: String = "zim", checksum: String? = nil, expectedBytes: Int64? = nil) throws -> (DownloadStore, ContentDownload) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID()
            let item = ContentDownload(id: id, url: URL(string: "https://example.org/book.\(suffix)")!, name: "book.\(suffix)", filename: "\(id.uuidString).\(suffix)", sha256: checksum, expectedBytes: expectedBytes, state: .downloading, taskIdentifier: 42)
            try JSONEncoder().encode([item]).write(to: folder.appendingPathComponent("downloads.json"))
            return (DownloadStore(rootURL: folder, sessionConfiguration: .ephemeral, reconnectTasks: false), item)
        }
        func stage(_ store: DownloadStore, _ item: ContentDownload, task: Int, bytes: Data) throws -> URL {
            let url = store.root.appendingPathComponent("Incoming/\(item.id.uuidString).task-\(task).pending")
            try bytes.write(to: url)
            return url
        }
        func waitForVerification(_ store: DownloadStore) async throws {
            for _ in 0..<500 {
                if !store.items.contains(where: { $0.state == .verifying }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Verification timed out")
        }
        func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            fatalError("Timed out: \(label)")
        }
        func heldConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeldDownloadProtocol.self]
            return configuration
        }
        func assertSerial(_ store: DownloadStore) {
            precondition(store.items.filter { $0.state == .downloading || $0.state == .verifying }.count <= 1)
        }
        // OPDS can supply a MIME-derived extension for an extensionless acquisition URL.
        let named = DownloadStore(rootURL: root.appendingPathComponent("opds-names"), sessionConfiguration: heldConfiguration(), reconnectTasks: false)
        try named.add(urlText: "https://example.org/get/123", checksum: "", suggestedFilename: "Arabic كتاب.epub")
        precondition(named.items.first?.name == "Arabic كتاب.epub" && named.items.first?.filename.hasSuffix(".epub") == true)
        precondition(named.items.first?.url.absoluteString == "https://example.org/get/123")
        for invalid in ["../book.epub", "book/other.pdf", "book\\other.zim", "control\n.epub", "", String(repeating: "a", count: 241)] {
            do { try named.add(urlText: "https://example.org/get/124", checksum: "", suggestedFilename: invalid); fatalError("Unsafe suggested filename accepted") } catch {}
        }
        precondition(named.items.count == 1)
        // A server's .pending or .resume extension cannot collide with internal storage.
        for suffix in ["pending", "resume"] {
            let (store, item) = try fixture("collision-\(suffix)", suffix: suffix, checksum: checksum)
            let staged = try stage(store, item, task: 42, bytes: bytes)
            store.received(item.id, taskIdentifier: 42, stagedURL: staged)
            try await waitForVerification(store)
            precondition(store.items.first?.state == .ready)
            let saved = try Data(contentsOf: store.fileURL(item))
            precondition(saved == bytes)
            let ready = try store.completedFile(item.id)
            precondition(ready.url == store.fileURL(item) && ready.expectedBytes == UInt64(bytes.count))
            precondition(ready.name == item.name && ready.sourceRoot == store.root.appendingPathComponent("Files", isDirectory: true))
            precondition(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Pending/\(item.id).download").path))
            store.remove(item.id)
            precondition(store.items.isEmpty)
            precondition(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Files/\(item.filename)").path))
        }
        // Only a currently verified, unchanged regular file can enter direct reader import.
        let (readerStore, readerItem) = try fixture("reader-import", expectedBytes: Int64(bytes.count))
        do { _ = try readerStore.completedFile(readerItem.id); fatalError("An unfinished download was exposed") } catch {}
        readerStore.received(readerItem.id, taskIdentifier: 42, stagedURL: try stage(readerStore, readerItem, task: 42, bytes: bytes))
        try await waitForVerification(readerStore)
        _ = try readerStore.completedFile(readerItem.id)
        try Data("Changed".utf8).write(to: readerStore.fileURL(readerItem))
        do { _ = try readerStore.completedFile(readerItem.id); fatalError("A changed download was exposed") } catch {}
        try FileManager.default.removeItem(at: readerStore.fileURL(readerItem))
        let linkTarget = root.appendingPathComponent("reader-link-target")
        try bytes.write(to: linkTarget)
        try FileManager.default.createSymbolicLink(at: readerStore.fileURL(readerItem), withDestinationURL: linkTarget)
        do { _ = try readerStore.completedFile(readerItem.id); fatalError("A symbolic link was exposed") } catch {}
        readerStore.remove(readerItem.id)
        let preservedTarget = try Data(contentsOf: linkTarget)
        precondition(preservedTarget == bytes)
        let (stale, item) = try fixture("stale")
        stale.progress(item.id, taskIdentifier: 41, received: 900, expected: 1_000)
        stale.failed(item.id, taskIdentifier: 41, message: "Late failure")
        precondition(stale.items.first?.state == .downloading && stale.items.first?.received == 0)
        let old = try stage(stale, item, task: 41, bytes: bytes)
        stale.received(item.id, taskIdentifier: 41, stagedURL: old)
        precondition(stale.items.first?.state == .downloading)
        precondition(!FileManager.default.fileExists(atPath: old.path))
        stale.remove(item.id)
        let afterRemoval = try stage(stale, item, task: 42, bytes: bytes)
        stale.received(item.id, taskIdentifier: 42, stagedURL: afterRemoval)
        precondition(!FileManager.default.fileExists(atPath: afterRemoval.path))
        let (invalid, bad) = try fixture("checksum", checksum: String(repeating: "0", count: 64))
        invalid.received(bad.id, taskIdentifier: 42, stagedURL: try stage(invalid, bad, task: 42, bytes: bytes))
        try await waitForVerification(invalid)
        precondition(invalid.items.first?.state == .failed)
        precondition(!FileManager.default.fileExists(atPath: invalid.fileURL(bad).path))
        precondition(!FileManager.default.fileExists(atPath: invalid.root.appendingPathComponent("Pending/\(bad.id).download").path))
        let (empty, noBytes) = try fixture("empty")
        empty.received(noBytes.id, taskIdentifier: 42, stagedURL: try stage(empty, noBytes, task: 42, bytes: Data()))
        try await waitForVerification(empty)
        precondition(empty.items.first?.state == .failed)
        let (rollback, original) = try fixture("write-failure")
        let manifest = rollback.root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        rollback.remove(original.id)
        precondition(rollback.items.first?.id == original.id)
        precondition(rollback.error != nil)
        precondition(!rollback.canWrite)

        // Authoritative byte counts reject both truncated and oversized responses without a hash.
        for delta in [-1, 1] {
            let (sized, item) = try fixture("size-\(delta)", expectedBytes: Int64(bytes.count + delta))
            sized.received(item.id, taskIdentifier: 42, stagedURL: try stage(sized, item, task: 42, bytes: bytes))
            try await waitForVerification(sized)
            precondition(sized.items.first?.state == .failed)
            precondition(!FileManager.default.fileExists(atPath: sized.fileURL(item).path))
            precondition(!FileManager.default.fileExists(atPath: sized.root.appendingPathComponent("Pending/\(item.id).download").path))
        }
        let (sized, sizedItem) = try fixture("exact-size", expectedBytes: Int64(bytes.count))
        sized.received(sizedItem.id, taskIdentifier: 42, stagedURL: try stage(sized, sizedItem, task: 42, bytes: bytes))
        try await waitForVerification(sized)
        precondition(sized.items.first?.state == .ready)
        precondition(sized.items.first?.message?.contains("size verified") == true)
        let sizedReload = DownloadStore(rootURL: sized.root, sessionConfiguration: heldConfiguration(), reconnectTasks: false)
        sizedReload.reconcile(tasks: [])
        precondition(sizedReload.items.first?.expectedBytes == Int64(bytes.count))
        precondition(sizedReload.items.first?.state == .ready)

        // A successful file receipt can already be queued when the user pauses. Keep those
        // bytes paused even if cancellation returns no resume data, and survive a relaunch.
        let (latePaused, pausedItem) = try fixture("paused-late-completion", checksum: checksum, expectedBytes: Int64(bytes.count))
        latePaused.pause(pausedItem.id)
        precondition(latePaused.items.first?.state == .paused)
        let lateFile = try stage(latePaused, pausedItem, task: 42, bytes: bytes)
        latePaused.received(pausedItem.id, taskIdentifier: 42, stagedURL: lateFile)
        try await Task.sleep(for: .milliseconds(50))
        precondition(latePaused.items.first?.state == .paused)
        precondition(latePaused.items.first?.received == Int64(bytes.count))
        let pausedRecovery = DownloadStore(rootURL: latePaused.root, sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { 1_000_000_000 })
        pausedRecovery.reconcile(tasks: [])
        precondition(pausedRecovery.items.first?.state == .paused)
        pausedRecovery.start(pausedItem.id)
        try await waitForVerification(pausedRecovery)
        precondition(pausedRecovery.items.first?.state == .ready)

        let (afterCancellation, afterItem) = try fixture("pause-cancel-before-completion", expectedBytes: Int64(bytes.count))
        afterCancellation.pause(afterItem.id)
        try await Task.sleep(for: .milliseconds(50))
        afterCancellation.received(afterItem.id, taskIdentifier: 42, stagedURL: try stage(afterCancellation, afterItem, task: 42, bytes: bytes))
        precondition(afterCancellation.items.first?.state == .paused)
        precondition(FileManager.default.fileExists(atPath: afterCancellation.root.appendingPathComponent("Pending/\(afterItem.id.uuidString).download").path))

        for value: Int64 in [-1, 0, DownloadStore.maximumFileBytes + 1, Int64.max] {
            let (badStore, badItem) = try fixture("bad-size-\(value)", expectedBytes: value)
            let originalData = try Data(contentsOf: badStore.root.appendingPathComponent("downloads.json"))
            precondition(!badStore.canWrite && badStore.items.isEmpty)
            badStore.remove(badItem.id)
            let preservedData = try Data(contentsOf: badStore.root.appendingPathComponent("downloads.json"))
            precondition(preservedData == originalData)
        }

        let reserve: Int64 = 512 * 1_024 * 1_024
        let (oversized, oversizedItem) = try fixture("oversized-response", expectedBytes: 100)
        oversized.progress(oversizedItem.id, taskIdentifier: 42, received: 101, expected: Int64.max)
        precondition(oversized.items.first?.state == .failed)
        let oversizedReload = DownloadStore(rootURL: oversized.root, sessionConfiguration: heldConfiguration(), reconnectTasks: false)
        precondition(oversizedReload.canWrite && oversizedReload.items.first?.state == .failed)
        let queue = DownloadStore(rootURL: root.appendingPathComponent("serial"), sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { reserve + 1_000 })
        func enqueue(_ name: String, store: DownloadStore = queue) throws -> ContentDownload {
            try store.add(urlText: "https://example.org/\(name).zim", checksum: checksum, expectedBytes: Int64(bytes.count))
            return store.items.first!
        }
        let first = try enqueue("first"), second = try enqueue("second"), third = try enqueue("third")
        precondition(queue.items.first(where: { $0.id == first.id })?.state == .downloading)
        precondition(queue.items.first(where: { $0.id == second.id })?.state == .queued)
        precondition(queue.items.first(where: { $0.id == third.id })?.state == .queued)
        assertSerial(queue)
        queue.pause(second.id)
        precondition(queue.items.first(where: { $0.id == second.id })?.state == .paused)
        queue.start(second.id)
        precondition(queue.items.first(where: { $0.id == second.id })?.state == .queued)
        let firstTask = queue.items.first(where: { $0.id == first.id })!.taskIdentifier!
        queue.received(first.id, taskIdentifier: firstTask, stagedURL: try stage(queue, first, task: firstTask, bytes: bytes))
        precondition(queue.items.first(where: { $0.id == first.id })?.state == .verifying)
        precondition(!queue.items.contains(where: { $0.state == .downloading }))
        try await waitUntil("oldest queued transfer after verification") {
            queue.items.first(where: { $0.id == first.id })?.state == .ready && queue.items.first(where: { $0.id == second.id })?.state == .downloading
        }
        assertSerial(queue)
        let secondTask = queue.items.first(where: { $0.id == second.id })!.taskIdentifier!
        queue.failed(second.id, taskIdentifier: secondTask, message: "Injected network failure")
        try await waitUntil("continue after failure") { queue.items.first(where: { $0.id == third.id })?.state == .downloading }
        queue.progress(second.id, taskIdentifier: secondTask, received: 9_000, expected: 10_000)
        queue.received(second.id, taskIdentifier: secondTask, stagedURL: try stage(queue, second, task: secondTask, bytes: bytes))
        precondition(queue.items.first(where: { $0.id == second.id })?.state == .failed)
        assertSerial(queue)
        queue.pause(third.id)
        try await Task.sleep(for: .milliseconds(50))
        precondition(queue.items.first(where: { $0.id == third.id })?.state == .paused)
        queue.start(second.id)
        try await waitUntil("explicit retry") { queue.items.first(where: { $0.id == second.id })?.state == .downloading }
        let fourth = try enqueue("fourth")
        queue.remove(second.id)
        try await waitUntil("continue after removal") { queue.items.first(where: { $0.id == fourth.id })?.state == .downloading }
        precondition(queue.items.first(where: { $0.id == third.id })?.state == .paused)
        assertSerial(queue)
        queue.pause(fourth.id)
        try await Task.sleep(for: .milliseconds(50))
        let reopened = DownloadStore(rootURL: queue.root, sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { reserve + 1_000 })
        reopened.reconcile(tasks: [])
        precondition(reopened.items.filter { $0.state == .paused }.count == 2)
        precondition(!reopened.items.contains(where: { $0.state == .downloading || $0.state == .queued }))

        var capacity = reserve + 150
        let accounting = DownloadStore(rootURL: root.appendingPathComponent("capacity"), sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { capacity })
        try accounting.add(urlText: "https://example.org/a.zim", checksum: "", expectedBytes: 100)
        do { try accounting.add(urlText: "https://example.org/b.zim", checksum: "", expectedBytes: 100); fatalError("Queue overcommitted storage") } catch {}
        precondition(accounting.items.count == 1)
        for value: Int64 in [0, -1, DownloadStore.maximumFileBytes + 1, Int64.max] {
            do { try accounting.add(urlText: "https://example.org/invalid.zim", checksum: "", expectedBytes: value); fatalError("Accepted invalid file size") } catch {}
        }
        capacity = reserve + 200
        try accounting.add(urlText: "https://example.org/b.zim", checksum: "", expectedBytes: 100)
        let active = accounting.items.first(where: { $0.state == .downloading })!
        capacity = reserve + 150 // 50 received bytes are now on disk; reserve only the remaining 150.
        accounting.progress(active.id, taskIdentifier: active.taskIdentifier!, received: 50, expected: 100)
        precondition(accounting.items.first(where: { $0.id == active.id })?.state == .downloading)
        capacity = reserve + 50
        accounting.progress(active.id, taskIdentifier: active.taskIdentifier!, received: 50, expected: 100)
        try await waitUntil("storage pressure pauses queue") { accounting.items.allSatisfy { $0.state == .paused } }
        capacity = reserve + 1_000
        accounting.reconcile(tasks: [])
        precondition(accounting.items.allSatisfy { $0.state == .paused })

        // Recover multiple completed payloads serially, while preserving a manual pause.
        let recoveryRoot = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recoveryRoot.appendingPathComponent("Pending"), withIntermediateDirectories: true)
        var recoveryItems: [ContentDownload] = []
        for number in 0..<3 {
            let id = UUID()
            let item = ContentDownload(id: id, url: URL(string: "https://example.org/\(number).zim")!, name: "\(number)", filename: "\(id.uuidString).zim", sha256: checksum, expectedBytes: Int64(bytes.count), state: number == 2 ? .paused : .verifying)
            recoveryItems.insert(item, at: 0)
            try bytes.write(to: recoveryRoot.appendingPathComponent("Pending/\(id.uuidString).download"))
        }
        try JSONEncoder().encode(recoveryItems).write(to: recoveryRoot.appendingPathComponent("downloads.json"))
        let recovering = DownloadStore(rootURL: recoveryRoot, sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { reserve + 1_000 })
        recovering.reconcile(tasks: [])
        precondition(recovering.items.last?.state == .verifying)
        precondition(recovering.items[1].state == .queued && recovering.items[0].state == .paused)
        assertSerial(recovering)
        try await waitUntil("serial interrupted verification") { recovering.items.filter { $0.state == .ready }.count == 2 }
        precondition(recovering.items[0].state == .paused)
        recovering.start(recoveryItems[0].id)
        try await waitUntil("explicit pending-file resume") { recovering.items.allSatisfy { $0.state == .ready } }

        // Adopt an older concurrent session into one running task, without restarting its
        // manually paused member. Held URLProtocol requests never reach the network.
        let adoptedRoot = root.appendingPathComponent("adopted-background-tasks")
        try FileManager.default.createDirectory(at: adoptedRoot, withIntermediateDirectories: true)
        let oldSession = URLSession(configuration: heldConfiguration())
        defer { oldSession.invalidateAndCancel() }
        var oldTasks: [URLSessionDownloadTask] = []
        var oldItems: [ContentDownload] = []
        for number in 0..<3 {
            let id = UUID(), url = URL(string: "https://example.org/adopted-\(number).zim")!
            let task = oldSession.downloadTask(with: url)
            task.taskDescription = id.uuidString
            oldTasks.append(task)
            oldItems.insert(ContentDownload(id: id, url: url, name: "adopted-\(number)", filename: "\(id.uuidString).zim", sha256: nil,
                expectedBytes: 100, state: number == 2 ? .paused : .downloading, taskIdentifier: task.taskIdentifier), at: 0)
        }
        try JSONEncoder().encode(oldItems).write(to: adoptedRoot.appendingPathComponent("downloads.json"))
        let adopted = DownloadStore(rootURL: adoptedRoot, sessionConfiguration: heldConfiguration(), reconnectTasks: false, availableBytesProvider: { reserve + 1_000 })
        adopted.reconcile(tasks: oldTasks)
        try await waitUntil("adopt oldest background task") { adopted.items.last?.state == .downloading }
        precondition(adopted.items[1].state == .queued && oldTasks[1].state == .suspended)
        precondition(adopted.items[0].state == .paused)
        assertSerial(adopted)
        adopted.pause(oldItems[2].id)
        try await waitUntil("advance adopted queue after pause") { adopted.items[1].state == .downloading }
        precondition(adopted.items[0].state == .paused && adopted.items[2].state == .paused)
        assertSerial(adopted)
        for item in adopted.items { adopted.remove(item.id) }
        print("PASS: reserved extensions, hashes and exact size, metadata validation, stale callbacks, atomic rollback, serial queue, pause/retry/remove, storage reservation, and relaunch recovery")
    }
}
