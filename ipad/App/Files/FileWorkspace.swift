import Foundation
import Observation
import Darwin

struct WorkspaceEntry: Identifiable {
    let url: URL
    let isDirectory: Bool
    let bytes: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

private enum WorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

@MainActor @Observable
final class FileWorkspace {
    let root: URL
    private(set) var revision = 0
    private(set) var busy = false
    private(set) var error: String?
    var clipboard: (url: URL, move: Bool)?

    init(root: URL? = nil) {
        let proposed = (root ?? URL.documentsDirectory.appendingPathComponent("Workspace", isDirectory: true)).standardizedFileURL
        var failure: String?
        do { try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true) }
        catch { failure = error.localizedDescription }
        self.root = (try? URL(fileURLWithPath: Self.realPath(proposed), isDirectory: true)) ?? proposed
        self.error = failure
    }

    func list(_ directory: URL) throws -> [WorkspaceEntry] {
        try validate(directory)
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        return try children.map { url in
            try validate(url)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return WorkspaceEntry(url: url, isDirectory: values.isDirectory == true, bytes: Int64(values.fileSize ?? 0))
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createFolder(_ name: String, in directory: URL) throws {
        try validate(directory)
        let url = try destination(name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        revision += 1
    }

    func rename(_ entry: WorkspaceEntry, to name: String) throws {
        guard !busy else { return }
        try validate(entry.url)
        let target = try destination(name, in: entry.url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: entry.url, to: target)
        if clipboard?.url == entry.url { clipboard?.url = target }
        revision += 1
    }

    func remove(_ entry: WorkspaceEntry) throws {
        guard !busy else { return }
        try validate(entry.url)
        let removedPath = try Self.realPath(entry.url)
        guard removedPath != root.path else { throw WorkspaceError.message("The workspace root cannot be removed.") }
        let clipboardPath = clipboard.flatMap { try? Self.realPath($0.url) }
        try FileManager.default.removeItem(at: entry.url)
        if let clipboardPath, clipboardPath == removedPath || clipboardPath.hasPrefix(removedPath + "/") { self.clipboard = nil }
        revision += 1
    }

    func paste(in directory: URL) async throws {
        guard !busy, let clipboard else { return }
        try validate(directory); try validate(clipboard.url)
        let directoryPath = try Self.realPath(directory), sourcePath = try Self.realPath(clipboard.url)
        guard directoryPath != sourcePath, !directoryPath.hasPrefix(sourcePath + "/") else {
            throw WorkspaceError.message("A folder cannot be placed inside itself.")
        }
        let target = try destination(clipboard.url.lastPathComponent, in: directory)
        busy = true
        defer { busy = false }
        if clipboard.move {
            try FileManager.default.moveItem(at: clipboard.url, to: target)
            self.clipboard = nil
        } else {
            try await Task.detached(priority: .userInitiated) { try Self.safeCopy(clipboard.url, to: target) }.value
        }
        revision += 1
    }

    func importFiles(_ urls: [URL], into directory: URL) async throws {
        guard !busy else { return }
        try validate(directory)
        busy = true
        defer { busy = false; revision += 1 }
        var failures: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let target = try destination(url.lastPathComponent, in: directory)
                try await Task.detached(priority: .userInitiated) {
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                        do { try Self.safeCopy(coordinated, to: target) } catch { copyError = error }
                    }
                    if let coordinationError { throw coordinationError }
                    if let copyError { throw copyError }
                }.value
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw WorkspaceError.message(failures.joined(separator: "\n")) }
    }

    private func destination(_ name: String, in directory: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), name.utf8.count <= 220,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceError.message("Use a name under 220 bytes without slashes, colons, leading dots, or surrounding spaces.")
        }
        let url = directory.appendingPathComponent(name)
        try validate(url, mustExist: false)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.message("An item with that name already exists. It has not been replaced.") }
        return url
    }

    private func validate(_ url: URL, mustExist: Bool = true) throws {
        let canonical = try mustExist ? Self.realPath(url) : Self.realPath(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
        guard canonical == root.path || canonical.hasPrefix(root.path + "/") else {
            throw WorkspaceError.message("The selected path is outside this app’s file workspace.")
        }
        if mustExist {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw WorkspaceError.message("Only regular files and folders are supported.")
            }
        }
    }

    private nonisolated static func realPath(_ url: URL) throws -> String {
        guard let pointer = url.withUnsafeFileSystemRepresentation({ path in path.flatMap { Darwin.realpath($0, nil) } }) else {
            throw WorkspaceError.message("The selected folder or file is no longer available.")
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private nonisolated static func safeCopy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        var count = 0, bytes: Int64 = 0
        func inspect(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw WorkspaceError.message("The import contains a symbolic link or unsupported file type.")
            }
            count += 1
            guard count <= 20_000 else { throw WorkspaceError.message("Import at most 20,000 files and folders at a time.") }
            let size = Int64(max(0, values.fileSize ?? 0))
            guard bytes <= Int64.max - size else { throw WorkspaceError.message("The import is too large.") }
            bytes += size
        }
        try inspect(source)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let sourcePath = try realPath(source)
            let targetParent = try realPath(destination.deletingLastPathComponent())
            guard targetParent != sourcePath, !targetParent.hasPrefix(sourcePath + "/") else {
                throw WorkspaceError.message("A folder cannot be imported or copied into itself or a descendant.")
            }
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in enumerationError = error; return false }) else {
                throw WorkspaceError.message("The selected folder cannot be read.")
            }
            for case let child as URL in enumerator { try inspect(child) }
            if let enumerationError { throw enumerationError }
        }
        let free = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard bytes < free - 256 * 1_024 * 1_024 else { throw WorkspaceError.message("There is not enough space for this copy and a 256 MB reserve.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        // Revalidate the copy to catch a source changed to a symlink during copying.
        count = 0; bytes = 0
        try inspect(staging)
        if values.isDirectory == true {
            guard let enumerator = manager.enumerator(at: staging, includingPropertiesForKeys: Array(keys)) else { throw WorkspaceError.message("The staged folder cannot be read.") }
            for case let child as URL in enumerator { try inspect(child) }
        }
        try manager.moveItem(at: staging, to: destination)
    }
}
