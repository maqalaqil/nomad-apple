import Foundation
import CryptoKit
import Darwin

enum BackupFileIO {
    static let reserve: UInt64 = 512 * 1_024 * 1_024
    static let maximumFiles = 100_000
    static let maximumBytes: UInt64 = 10_000_000_000_000
    static let maximumManifest = 32 * 1_024 * 1_024
    struct Fingerprint: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let directory: Bool
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
            directory = (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        }
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 2_048 && parts.count <= 32 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") &&
            !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
    static func fingerprint(_ url: URL) throws -> Fingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw posix("Inspect \(url.lastPathComponent)") }
        let mode = value.st_mode & mode_t(S_IFMT)
        guard mode == mode_t(S_IFREG) || mode == mode_t(S_IFDIR), value.st_size >= 0 else {
            throw BackupFailure("Symbolic links and special files are not supported: \(url.lastPathComponent)")
        }
        return Fingerprint(value)
    }
    static func exists(_ url: URL) -> Bool {
        var info = stat(); return lstat(url.path, &info) == 0
    }
    /// Parent traversal is checked component by component; no archive-supplied path escapes root.
    static func child(_ path: String, in root: URL, createParents: Bool = false) throws -> URL {
        guard validPath(path), root.isFileURL else { throw BackupFailure("Unsafe backup path.") }
        guard try fingerprint(root).directory else { throw BackupFailure("A backup root must be a real directory.") }
        let parts = path.split(separator: "/").map(String.init)
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            if exists(current) {
                let info = try fingerprint(current)
                if index < parts.count - 1, !info.directory { throw BackupFailure("A parent path is not a folder.") }
            } else if index < parts.count - 1, createParents {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }
    static func prepare(_ folder: URL) throws {
        // Trusted application roots may not exist yet. Canonicalize existing system ancestors
        // (/var on Apple platforms) before establishing the checked app-owned descendants.
        if exists(folder) {
            guard try fingerprint(folder).directory else { throw BackupFailure("Storage is not a real directory.") }
        } else {
            try prepare(folder.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
    }
    static func capacity(_ folder: URL, additional: UInt64, available: (@Sendable () throws -> UInt64)? = nil) throws {
        let free: UInt64
        if let available { free = try available() }
        else {
            let values = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
            guard let value = values[.systemFreeSize] as? NSNumber, value.int64Value >= 0 else { throw BackupFailure("Available storage could not be checked.") }
            free = value.uint64Value
        }
        let (needed, overflow) = additional.addingReportingOverflow(reserve)
        guard !overflow, free >= needed else { throw BackupFailure("Insufficient storage: need \(additional) additional bytes and a 512 MiB reserve. Existing data was preserved.") }
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let handle = try openRegular(url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw BackupFailure("Metadata exceeds its supported size.") }
        return bytes
    }
    static func openRegular(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posix("Open \(url.lastPathComponent)") }
        var value = stat()
        guard fstat(descriptor, &value) == 0, (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor); throw BackupFailure("Only regular files can be copied.")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    static func copyAndHash(_ source: URL, to destination: URL?, expected: UInt64,
                            checkStorage: @Sendable () throws -> Void = {},
                            progress: @Sendable (UInt64) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        let original = try fingerprint(source)
        guard !original.directory, UInt64(original.size) == expected else { throw BackupFailure("A backup file changed size or type.") }
        let reader = try openRegular(source)
        defer { try? reader.close() }
        var opened = stat()
        guard fstat(reader.fileDescriptor, &opened) == 0, Fingerprint(opened) == original else { throw BackupFailure("The source changed while it was opened.") }
        var writer: FileHandle?
        var ownsDestination = false
        var succeeded = false
        if let destination {
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw posix("Create backup file") }
            writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            ownsDestination = true
        }
        defer {
            try? writer?.close()
            if !succeeded, ownsDestination, let destination { try? FileManager.default.removeItem(at: destination) }
        }
        var count: UInt64 = 0
        var nextStorageCheck: UInt64 = 0
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            if destination != nil, count >= nextStorageCheck {
                try checkStorage()
                nextStorageCheck = count + 64 * 1_024 * 1_024
            }
            let data = try autoreleasepool { try reader.read(upToCount: 1_024 * 1_024) ?? Data() }
            if data.isEmpty { break }
            guard UInt64(data.count) <= expected - min(expected, count) else { throw BackupFailure("A source grew during backup.") }
            try writer?.write(contentsOf: data)
            hash.update(data: data)
            count += UInt64(data.count)
            progress(UInt64(data.count))
        }
        var finished = stat()
        guard count == expected, fstat(reader.fileDescriptor, &finished) == 0, Fingerprint(finished) == original,
              try fingerprint(source) == original else { throw BackupFailure("A source changed while being copied. Retry after closing its editor.") }
        try writer?.synchronize()
        succeeded = true
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func write<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumManifest else { throw BackupFailure("The backup manifest is too large.") }
        if exists(destination), try fingerprint(destination).directory { throw BackupFailure("Metadata path is a directory.") }
        try data.write(to: destination, options: .atomic)
    }
    static func tree(_ root: URL) throws -> [String: Fingerprint] {
        guard exists(root) else { return [:] }
        guard try fingerprint(root).directory else { throw BackupFailure("A component root is not a directory.") }
        var result: [String: Fingerprint] = [:]
        func walk(_ path: String) throws {
            try Task.checkCancellation()
            let directory = path.isEmpty ? root : try child(path, in: root)
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                let relative = path.isEmpty ? name : path + "/" + name
                guard validPath(relative), result.count < maximumFiles else { throw BackupFailure("Too many files or an unsafe path in backup data.") }
                let url = try child(relative, in: root)
                let value = try fingerprint(url)
                result[relative] = value
                if value.directory { try walk(relative) }
            }
        }
        try walk("")
        return result
    }
    static func isWorkingPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".import-") || $0.hasPrefix(".delete-") || $0.hasPrefix(".previous-") }
    }
    static func posix(_ operation: String) -> BackupFailure { BackupFailure("\(operation): \(String(cString: strerror(errno)))") }
}
