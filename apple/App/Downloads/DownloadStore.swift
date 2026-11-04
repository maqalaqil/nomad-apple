import Foundation
import Observation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

struct ContentDownload: Codable, Identifiable {
    enum State: String, Codable { case queued, downloading, paused, verifying, ready, failed }
    let id: UUID
    let url: URL
    let name: String
    let filename: String
    let sha256: String?
    var expectedBytes: Int64? = nil // Authoritative catalog/user size, independent of HTTP progress.
    var state: State
    var received: Int64 = 0
    var expected: Int64 = 0
    var message: String?
    var taskIdentifier: Int?
}

private struct DownloadFailure: LocalizedError {
    let message: String
    var discardPayload = false
    var errorDescription: String? { message }
}

@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()
    static let sessionIdentifier = "org.projectnomad.ipad.content-downloads.v1"
    nonisolated static let maximumFileBytes: Int64 = 10_000_000_000_000
    private(set) var items: [ContentDownload] = []
    private(set) var error: String?
    private(set) var canWrite = true
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var delegate: ContentDownloadDelegate!
    @ObservationIgnored private var pausing: Set<UUID> = []
    @ObservationIgnored private var verifying: Set<UUID> = []
    @ObservationIgnored private var tasksByID: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var cancellingTasks: Set<Int> = []
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var restoring = true
    @ObservationIgnored private var draining = false
    @ObservationIgnored private let capacityProvider: (() -> Int64)?
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    private let storageReserve: Int64 = 512 * 1_024 * 1_024
    let root: URL
    var isReconnecting: Bool { restoring }
    private var manifest: URL { root.appendingPathComponent("downloads.json") }
    private var filesRoot: URL { root.appendingPathComponent("Files", isDirectory: true) }
    private var partialRoot: URL { root.appendingPathComponent("Pending", isDirectory: true) }
    private var resumeRoot: URL { root.appendingPathComponent("Resume", isDirectory: true) }
    private var incomingRoot: URL { root.appendingPathComponent("Incoming", isDirectory: true) }

    init(rootURL: URL? = nil, sessionConfiguration: URLSessionConfiguration? = nil, reconnectTasks: Bool = true,
         availableBytesProvider: (() -> Int64)? = nil) {
        root = rootURL ?? URL.applicationSupportDirectory.appendingPathComponent("NomadPad/Downloads", isDirectory: true)
        capacityProvider = availableBytesProvider
        do {
            for directory in [root, filesRoot, partialRoot, resumeRoot, incomingRoot] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: manifest.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
                guard (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max < 16_000_000 else {
                    throw DownloadFailure(message: "Download history is too large.")
                }
                let data = try Data(contentsOf: manifest)
                items = try JSONDecoder().decode([ContentDownload].self, from: data)
                guard Set(items.map(\.id)).count == items.count,
                      items.allSatisfy({ $0.filename.hasPrefix($0.id.uuidString + ".") &&
                          !$0.filename.contains("/") && !$0.filename.contains("\\") && !$0.filename.contains("..") && !$0.filename.contains("\0") &&
                          $0.url.scheme == "https" && $0.url.host != nil && $0.url.user == nil && $0.url.password == nil &&
                          (0...Self.maximumFileBytes).contains($0.received) && (0...Self.maximumFileBytes).contains($0.expected) &&
                          ($0.expectedBytes == nil || (1...Self.maximumFileBytes).contains($0.expectedBytes!)) &&
                          ($0.taskIdentifier == nil || $0.taskIdentifier! > 0) &&
                          ($0.sha256 == nil || ($0.sha256!.count == 64 && $0.sha256!.allSatisfy { $0.isASCII && $0.isHexDigit })) }) else {
                    throw DownloadFailure(message: "Download history contains invalid file references or sizes.")
                }
            }
        } catch {
            self.error = "Download history could not be opened. The saved files have been preserved. \(error.localizedDescription)"
            canWrite = false
            items = []
        }
        delegate = ContentDownloadDelegate(root: incomingRoot)
        delegate.owner = self
        let configuration = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.allowsCellularAccess = false
        #if os(macOS)
        // AppKit does not support background launch for URLSession events.
        // Reconcile any OS-retained transfers on the next normal app launch.
        configuration.sessionSendsLaunchEvents = false
        #else
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.isDiscretionary = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        if reconnectTasks {
            session.getAllTasks { tasks in
                Task { @MainActor [weak self] in self?.reconcile(tasks: tasks) }
            }
        } else { restoring = false }
    }

    func add(urlText: String, checksum: String, expectedBytes: Int64? = nil, suggestedFilename: String? = nil) throws {
        guard canWrite else { throw DownloadFailure(message: error ?? "Download storage is unavailable.") }
        guard !restoring else { throw DownloadFailure(message: "Reconnecting saved download tasks. Try again in a moment.") }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw DownloadFailure(message: "Enter a direct HTTPS file URL without embedded credentials.")
        }
        let hash = checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.isEmpty || (hash.count == 64 && hash.allSatisfy({ $0.isHexDigit && $0.isASCII })) else {
            throw DownloadFailure(message: "A SHA-256 checksum must contain exactly 64 hexadecimal characters.")
        }
        guard expectedBytes == nil || (1...Self.maximumFileBytes).contains(expectedBytes!) else {
            throw DownloadFailure(message: "The expected file size must be between 1 byte and 10 TB.")
        }
        try requireCapacity(additional: expectedBytes ?? 0)
        let id = UUID()
        let supplied = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let supplied {
            guard !supplied.isEmpty, supplied.utf8.count <= 240, supplied != ".", supplied != "..",
                  !supplied.contains("/"), !supplied.contains("\\"),
                  supplied.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw DownloadFailure(message: "The suggested file name must be a plain file name without folders or control characters.")
            }
        }
        let ext = supplied.map { ($0 as NSString).pathExtension.lowercased() } ?? url.pathExtension.lowercased()
        let suffix = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "data"
        let name = supplied ?? String((url.lastPathComponent.isEmpty ? "Downloaded file" : url.lastPathComponent).prefix(160))
        let item = ContentDownload(id: id, url: url, name: name, filename: "\(id.uuidString).\(suffix)", sha256: hash.isEmpty ? nil : hash,
            expectedBytes: expectedBytes, state: .queued, message: expectedBytes == nil ? "Queued. File size is unknown until the server responds." : "Queued.")
        items.insert(item, at: 0)
        guard persist() else { items.removeAll { $0.id == id }; throw DownloadFailure(message: error ?? "Could not save the download.") }
        drainQueue()
    }

    func fileURL(_ item: ContentDownload) -> URL {
        guard items.contains(where: { $0.id == item.id && $0.filename == item.filename }) else {
            return filesRoot.appendingPathComponent("invalid-download")
        }
        return filesRoot.appendingPathComponent(item.filename)
    }

    /// Recheck the durable completed entry at the moment a reader imports it.
    /// Readers receive only immutable, app-owned completed files through this path.
    func completedFile(_ id: UUID) throws -> (url: URL, sourceRoot: URL, expectedBytes: UInt64, name: String) {
        guard let item = items.first(where: { $0.id == id && $0.state == .ready }), item.received > 0 else {
            throw DownloadFailure(message: "This download is not ready to import. Finish verification first.")
        }
        let source = fileURL(item)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == item.received,
              item.expectedBytes == nil || item.expectedBytes == item.received else {
            throw DownloadFailure(message: "The completed file is missing or its size changed. Its download entry was preserved.")
        }
        return (source, filesRoot, UInt64(item.received), item.name)
    }
    private func partialURL(_ id: UUID) -> URL { partialRoot.appendingPathComponent("\(id.uuidString).download") }
    private func resumeURL(_ id: UUID) -> URL { resumeRoot.appendingPathComponent("\(id.uuidString).resume") }
    private func incomingURL(_ id: UUID, taskIdentifier: Int) -> URL {
        incomingRoot.appendingPathComponent("\(id.uuidString).task-\(taskIdentifier).pending")
    }
    private func hasCompletedPayload(_ item: ContentDownload) -> Bool {
        FileManager.default.fileExists(atPath: partialURL(item.id).path) || FileManager.default.fileExists(atPath: fileURL(item).path)
    }

    /// Resume enters the serial queue. Existing entries retain their original oldest-first order.
    func start(_ id: UUID) {
        guard canWrite, !restoring, !pausing.contains(id), let index = items.firstIndex(where: { $0.id == id }),
              [.queued, .paused, .failed].contains(items[index].state) else { return }
        let previous = items[index]
        if tasksByID[id] == nil && !FileManager.default.fileExists(atPath: resumeURL(id).path) && !hasCompletedPayload(items[index]) {
            items[index].received = 0
            items[index].taskIdentifier = nil
        }
        items[index].state = .queued
        items[index].message = "Queued."
        do { try requireCapacity() }
        catch {
            items[index] = previous
            items[index].message = error.localizedDescription
            self.error = error.localizedDescription
            persist()
            return
        }
        guard persist() else { items[index] = previous; return }
        drainQueue()
    }

    /// There is never more than one transfer or file verification started by this store.
    private func drainQueue() {
        guard canWrite, !restoring, !draining, pausing.isEmpty, cancellingTasks.isEmpty, verifying.isEmpty,
              !items.contains(where: { $0.state == .downloading || $0.state == .verifying }) else { return }
        draining = true
        defer { draining = false }
        while let index = items.indices.reversed().first(where: { items[$0].state == .queued }) {
            let item = items[index]
            if hasCompletedPayload(item) { finish(item.id); return }
            do { try requireCapacity() }
            catch {
                items[index].state = .paused
                items[index].message = error.localizedDescription
                self.error = error.localizedDescription
                guard persist() else { return }
                // The paused item no longer reserves queue space; a later smaller item may fit.
                continue
            }
            let task: URLSessionDownloadTask
            if let existing = tasksByID[item.id] { task = existing }
            else if let data = try? Data(contentsOf: resumeURL(item.id)), !data.isEmpty {
                task = session.downloadTask(withResumeData: data)
            } else {
                items[index].received = 0
                task = session.downloadTask(with: item.url)
            }
            task.taskDescription = item.id.uuidString
            items[index].state = .downloading
            items[index].message = item.expectedBytes == nil && item.expected == 0 ? "File size is unknown until the server responds." : nil
            items[index].taskIdentifier = task.taskIdentifier
            guard persist() else { items[index] = item; task.cancel(); return }
            tasksByID[item.id] = task
            try? FileManager.default.removeItem(at: resumeURL(item.id))
            task.resume()
            return
        }
    }

    func pause(_ id: UUID) {
        guard canWrite, !restoring, let index = items.firstIndex(where: { $0.id == id }),
              [.queued, .downloading].contains(items[index].state), !pausing.contains(id) else { return }
        let previous = items[index]
        items[index].state = .paused // Persist the user's intent before the asynchronous cancellation.
        // Retain the attempt identity until retry/removal: a just-completed file may still be
        // waiting for its main-actor receipt callback, even after cancellation returns nil.
        items[index].message = previous.message ?? "Paused. Resume to rejoin the queue."
        guard persist() else { items[index] = previous; return }
        cancelTransfer(id, taskIdentifier: previous.taskIdentifier, saveResumeData: true)
    }

    /// Wait for cancellation to finish before starting another transfer. Task IDs isolate late callbacks.
    private func cancelTransfer(_ id: UUID, taskIdentifier: Int?, saveResumeData: Bool) {
        guard let taskIdentifier else {
            tasksByID.removeValue(forKey: id)
            drainQueue()
            return
        }
        pausing.insert(id)
        let knownTask = tasksByID.removeValue(forKey: id)
        let complete: @MainActor @Sendable (Data?) -> Void = { [self] data in
            guard pausing.contains(id) else { return }
            if saveResumeData, let index = items.firstIndex(where: { $0.id == id && $0.state == .paused }) {
                do {
                    if let data, !data.isEmpty { try data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    else if !hasCompletedPayload(items[index]) {
                        try? FileManager.default.removeItem(at: resumeURL(id))
                        items[index].received = 0
                        items[index].message = "Paused. This server may require restarting the transfer."
                    }
                    persist()
                } catch { self.error = "Could not save transfer recovery data: \(error.localizedDescription)" }
            }
            pausing.remove(id)
            drainQueue()
        }
        if let knownTask, knownTask.taskIdentifier == taskIdentifier {
            knownTask.cancel { data in Task { @MainActor in complete(data) } }
        } else {
            session.getAllTasks { tasks in
                if let task = tasks.first(where: { $0.taskDescription == id.uuidString && $0.taskIdentifier == taskIdentifier }) as? URLSessionDownloadTask {
                    task.cancel { data in Task { @MainActor in complete(data) } }
                } else { Task { @MainActor in complete(nil) } }
            }
        }
    }

    func remove(_ id: UUID) {
        guard canWrite, let item = items.first(where: { $0.id == id }), !verifying.contains(id) else { return }
        let files = [fileURL(item), partialURL(id), resumeURL(id)]
        let old = items
        items.removeAll { $0.id == id }
        guard persist() else { items = old; return }
        do {
            for url in files where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            for url in try FileManager.default.contentsOfDirectory(at: incomingRoot, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(id.uuidString + ".task-") { try FileManager.default.removeItem(at: url) }
        } catch { self.error = "The download was removed from the list, but a file could not be removed: \(error.localizedDescription)" }
        if !pausing.contains(id) { cancelTransfer(id, taskIdentifier: item.taskIdentifier, saveResumeData: false) }
    }

    func progress(_ id: UUID, taskIdentifier: Int, received: Int64, expected: Int64) {
        guard canWrite, let index = items.firstIndex(where: { $0.id == id && $0.taskIdentifier == taskIdentifier }), items[index].state == .downloading else { return }
        items[index].received = max(0, received)
        items[index].expected = min(Self.maximumFileBytes, max(0, expected))
        if received > (items[index].expectedBytes ?? Self.maximumFileBytes) || expected > Self.maximumFileBytes {
            items[index].state = .failed
            items[index].taskIdentifier = nil
            items[index].received = 0
            items[index].message = "The transfer exceeded the expected file size. The partial transfer was discarded; Resume to retry."
            guard persist() else { return }
            try? FileManager.default.removeItem(at: resumeURL(id))
            cancelTransfer(id, taskIdentifier: taskIdentifier, saveResumeData: false)
            return
        }
        do { try requireCapacity() }
        catch {
            items[index].message = error.localizedDescription
            self.error = error.localizedDescription
            pause(id)
            return
        }
        if Date().timeIntervalSince(lastProgressSave) > 2 { persist(); lastProgressSave = Date() }
    }

    func failed(_ id: UUID, taskIdentifier: Int? = nil, message: String, resumeData: Data? = nil) {
        guard canWrite, !pausing.contains(id), let index = items.firstIndex(where: { $0.id == id }), items[index].state != .ready else { return }
        if let taskIdentifier {
            guard items[index].taskIdentifier == taskIdentifier, items[index].state == .downloading else { return }
        }
        let previousTask = items[index].taskIdentifier
        if let resumeData, !resumeData.isEmpty {
            do { try resumeData.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            catch { self.error = "Could not save transfer recovery data: \(error.localizedDescription)" }
        } else if !hasCompletedPayload(items[index]) {
            try? FileManager.default.removeItem(at: resumeURL(id))
            items[index].received = 0
        }
        items[index].state = .failed
        items[index].taskIdentifier = nil
        items[index].message = message
        guard persist() else { return }
        cancelTransfer(id, taskIdentifier: previousTask, saveResumeData: false)
    }

    fileprivate func finish(_ id: UUID) {
        guard canWrite, verifying.isEmpty, let index = items.firstIndex(where: { $0.id == id }),
              [.queued, .downloading].contains(items[index].state),
              !items.contains(where: { $0.id != id && ($0.state == .downloading || $0.state == .verifying) }) else { return }
        let item = items[index]
        let destination = fileURL(item)
        let source = FileManager.default.fileExists(atPath: partialURL(id).path) ? partialURL(id) : destination
        items[index].state = .verifying
        items[index].taskIdentifier = nil
        guard persist() else { items[index] = item; return }
        tasksByID.removeValue(forKey: id)
        verifying.insert(id)
        Task {
            do {
                let bytes = try await Task.detached(priority: .utility) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DownloadFailure(message: "The downloaded payload is not a regular file.", discardPayload: true) }
                    let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard actualSize > 0 else { throw DownloadFailure(message: "The server returned an empty file. Resume to retry.", discardPayload: true) }
                    if let specified = item.expectedBytes, actualSize != specified {
                        throw DownloadFailure(message: "Expected \(specified) bytes but received \(actualSize). The invalid file was removed; Resume to retry.", discardPayload: true)
                    }
                    guard actualSize <= Self.maximumFileBytes else { throw DownloadFailure(message: "The downloaded file exceeds the 10 TB supported limit.", discardPayload: true) }
                    if let expected = item.sha256 {
                        let handle = try FileHandle(forReadingFrom: source)
                        defer { try? handle.close() }
                        var hasher = SHA256(), bytes: Int64 = 0
                        while try autoreleasepool(invoking: {
                            // FileHandle bridges through autoreleased NSData. A detached task can
                            // retain every chunk until it exits unless each iteration drains a pool.
                            // Keep both the read and hash update inside; only a Bool escapes.
                            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                            let (next, overflow) = bytes.addingReportingOverflow(Int64(chunk.count))
                            guard !overflow, next <= Self.maximumFileBytes else { throw DownloadFailure(message: "The downloaded file is too large.", discardPayload: true) }
                            bytes = next
                            hasher.update(data: chunk)
                            return true
                        }) {}
                        guard bytes == actualSize else { throw DownloadFailure(message: "The file size changed during verification. The invalid file was removed; Resume to retry.", discardPayload: true) }
                        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        guard actual == expected.lowercased() else { throw DownloadFailure(message: "SHA-256 did not match. The invalid file was removed; Resume to download it again.", discardPayload: true) }
                    }
                    if source != destination {
                        if FileManager.default.fileExists(atPath: destination.path) { throw DownloadFailure(message: "A completed file already exists; the saved copy was preserved.") }
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                    return actualSize
                }.value
                if let index = items.firstIndex(where: { $0.id == id && $0.state == .verifying }) {
                    items[index].state = .ready
                    items[index].received = bytes; items[index].expected = bytes
                    items[index].message = item.sha256 != nil ? "SHA-256 verified." : (item.expectedBytes != nil ? "Expected file size verified. No checksum was supplied." : "Transfer complete. No expected size or checksum was supplied.")
                    persist()
                    try? FileManager.default.removeItem(at: resumeURL(id))
                }
            } catch {
                if let failure = error as? DownloadFailure, failure.discardPayload {
                    try? FileManager.default.removeItem(at: source)
                    try? FileManager.default.removeItem(at: resumeURL(id))
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].received = 0 }
                }
                failed(id, message: error.localizedDescription)
            }
            verifying.remove(id)
            drainQueue()
        }
    }

    func received(_ id: UUID, taskIdentifier: Int, stagedURL: URL) {
        guard canWrite else { return } // Preserve staged bytes if metadata needs recovery.
        guard let index = items.firstIndex(where: { $0.id == id && $0.taskIdentifier == taskIdentifier }),
              [.downloading, .queued, .paused].contains(items[index].state) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        do {
            let destination = partialURL(id)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: stagedURL) }
            else { try FileManager.default.moveItem(at: stagedURL, to: destination) }
            if items[index].state == .paused {
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                items[index].received = min(Self.maximumFileBytes, max(0, size))
                items[index].message = "The file finished while paused. Resume to verify the saved file."
                tasksByID.removeValue(forKey: id)
                persist()
                return
            }
            // A formerly concurrent background task can finish while launch reconciliation suspends it.
            // Keep its payload in the queue; verification still waits for the one active worker.
            items[index].state = .queued
            items[index].taskIdentifier = nil
            tasksByID.removeValue(forKey: id)
            guard persist() else { return }
            drainQueue()
        } catch { failed(id, taskIdentifier: taskIdentifier, message: error.localizedDescription) }
    }

    /// Called after URLSession reconnects. Internal visibility also permits deterministic relaunch tests.
    func reconcile(tasks: [URLSessionTask]) {
        guard canWrite else { restoring = false; tasks.forEach { $0.cancel() }; return }
        var adopted: Set<Int> = []
        for index in items.indices {
            let id = items[index].id
            if let taskIdentifier = items[index].taskIdentifier {
                let incoming = incomingURL(id, taskIdentifier: taskIdentifier)
                if FileManager.default.fileExists(atPath: incoming.path), !FileManager.default.fileExists(atPath: partialURL(id).path) {
                    do { try FileManager.default.moveItem(at: incoming, to: partialURL(id)) }
                    catch { self.error = "An interrupted file could not be recovered: \(error.localizedDescription)" }
                }
            }
            let completed = hasCompletedPayload(items[index])
            if items[index].state == .ready {
                if !FileManager.default.fileExists(atPath: fileURL(items[index]).path) {
                    items[index].state = .failed; items[index].message = "The downloaded file is missing."
                }
                items[index].taskIdentifier = nil
            } else if [.paused, .failed].contains(items[index].state) {
                // Never auto-resume explicit pauses or retries, including completed pending payloads.
                if items[index].state == .failed { items[index].taskIdentifier = nil }
            } else if completed {
                items[index].state = .queued
                items[index].taskIdentifier = nil
            } else if let task = tasks.first(where: {
                $0.taskDescription == id.uuidString && ($0.state == .running || $0.state == .suspended) &&
                (items[index].taskIdentifier == nil || $0.taskIdentifier == items[index].taskIdentifier)
            }) as? URLSessionDownloadTask {
                if task.state != .suspended { task.suspend() }
                items[index].state = .queued
                items[index].taskIdentifier = task.taskIdentifier
                tasksByID[id] = task
                adopted.insert(task.taskIdentifier)
            } else {
                items[index].state = .queued
                items[index].taskIdentifier = nil
                if !FileManager.default.fileExists(atPath: resumeURL(id).path) { items[index].received = 0 }
                items[index].message = "Queued after interruption."
            }
        }
        for task in tasks where !adopted.contains(task.taskIdentifier) {
            // An old app version may have left multiple background tasks. Do not overlap new
            // work with their cancellation, or accidentally restart a manually paused entry.
            guard let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
            cancellingTasks.insert(task.taskIdentifier)
            download.cancel { data in
                Task { @MainActor in
                    if let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
                       let index = self.items.firstIndex(where: { $0.id == id && $0.state == .paused }),
                       let data, !data.isEmpty {
                        do { try data.write(to: self.resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                        catch { self.items[index].message = "Paused; recovery data could not be saved. Resume may restart the transfer."; self.persist() }
                    }
                    self.cancellingTasks.remove(task.taskIdentifier)
                    self.drainQueue()
                }
            }
        }
        let saved = persist()
        restoring = false
        guard saved else { tasks.forEach { $0.cancel() }; return }
        if let incoming = try? FileManager.default.contentsOfDirectory(at: incomingRoot, includingPropertiesForKeys: nil) {
            let owned = Set(items.compactMap { item in item.taskIdentifier.map { incomingURL(item.id, taskIdentifier: $0).lastPathComponent } })
            for file in incoming where !owned.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        drainQueue()
    }

    /// Only queued/active transfers reserve future space; completed bytes already reduce filesystem capacity.
    private func requireCapacity(additional: Int64 = 0) throws {
        var required = storageReserve
        func add(_ amount: Int64) throws {
            let (next, overflow) = required.addingReportingOverflow(amount)
            guard !overflow else { throw DownloadFailure(message: "The queued download sizes exceed supported storage accounting.") }
            required = next
        }
        try add(additional)
        for item in items where item.state == .queued || item.state == .downloading {
            if hasCompletedPayload(item) { continue }
            let total = item.expectedBytes ?? item.expected
            try add(max(0, total - min(total, item.received)))
        }
        guard availableBytes >= required else {
            throw DownloadFailure(message: "Not enough available storage for the known remaining queued files and a 512 MB reserve. Pause or remove queued items, or free space, then Resume. Importing files needs additional space.")
        }
    }

    @discardableResult private func persist() -> Bool {
        guard canWrite else { return false }
        do {
            let data = try JSONEncoder().encode(items)
            guard data.count < 16_000_000 else { throw DownloadFailure(message: "Download history is full. Remove older entries before adding more.") }
            try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            self.error = "Download state could not be saved. Reopen the app after resolving the storage issue: \(error.localizedDescription)"
            // Stop starting work after a failed state write; preserve the last durable manifest.
            canWrite = false
            tasksByID.values.forEach { $0.suspend() }
            return false
        }
    }

    private var availableBytes: Int64 {
        max(0, capacityProvider?() ?? (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0)
    }
}

private final class ContentDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: DownloadStore?
    let root: URL
    init(root: URL) { self.root = root }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let taskIdentifier = downloadTask.taskIdentifier
        Task { @MainActor in owner?.progress(id, taskIdentifier: taskIdentifier, received: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let taskIdentifier = downloadTask.taskIdentifier
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode), response.url?.scheme == "https" else {
                throw DownloadFailure(message: "The download server returned an unsuccessful or insecure response.")
            }
            let destination = root.appendingPathComponent("\(id.uuidString).task-\(taskIdentifier).pending")
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadFailure(message: "An earlier transfer is awaiting verification.") }
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in owner?.received(id, taskIdentifier: taskIdentifier, stagedURL: destination) }
        } catch { Task { @MainActor in owner?.failed(id, taskIdentifier: taskIdentifier, message: error.localizedDescription) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let taskIdentifier = task.taskIdentifier
        Task { @MainActor in owner?.failed(id, taskIdentifier: taskIdentifier, message: error.localizedDescription, resumeData: data) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            owner?.backgroundCompletion?()
            owner?.backgroundCompletion = nil
        }
    }
}

#if canImport(UIKit)
final class NomadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadStore.sessionIdentifier else { completionHandler(); return }
        DownloadStore.shared.backgroundCompletion = completionHandler
    }
}
#endif
