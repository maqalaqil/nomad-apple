import Foundation
import Darwin

/// Shares an immutable, verified download with another app-owned store. This does not verify
/// downloaded content: the caller must obtain the source/root/length from its ready-download
/// manifest. Never use this path for mutable Files-provider imports or editable documents.
public enum InternalDownloadLink {
    /// Returns false only when linking is unsupported or crosses volumes. The caller may then
    /// perform its normal, capacity-checked copy. Existing destinations are never replaced.
    public static func stage(source: URL, sourceRoot: URL, destination: URL, expectedBytes: UInt64) throws -> Bool {
        guard source.isFileURL, sourceRoot.isFileURL, destination.isFileURL,
              source.query == nil, source.fragment == nil, destination.query == nil, destination.fragment == nil,
              expectedBytes <= UInt64(Int64.max),
              safeName(source.lastPathComponent), safeName(destination.lastPathComponent),
              source.deletingLastPathComponent().standardizedFileURL == sourceRoot.standardizedFileURL else {
            throw failure("The download is not a direct file inside its verified download folder.")
        }
        let root = try openDirectory(sourceRoot)
        defer { close(root) }
        let target = try openDirectory(destination.deletingLastPathComponent())
        defer { close(target) }
        let descriptor = openat(root, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw systemFailure("Open verified download") }
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw systemFailure("Inspect verified download") }
        guard regular(original), original.st_size >= 0, UInt64(original.st_size) == expectedBytes else {
            throw failure("The verified download is not a regular file of the expected size.")
        }
        guard linkat(root, source.lastPathComponent, target, destination.lastPathComponent, 0) == 0 else {
            let code = errno
            if code == EXDEV || code == ENOTSUP || code == ENOSYS || code == EPERM { return false }
            throw systemFailure("Link verified download", code: code)
        }

        // linkat creates exclusively. Record exactly what it created before verification so a
        // failure cannot remove a pre-existing file or a concurrently replaced destination.
        var linked = stat()
        guard fstatat(target, destination.lastPathComponent, &linked, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw systemFailure("Inspect linked download")
        }
        var succeeded = false
        defer {
            if !succeeded {
                var current = stat()
                if fstatat(target, destination.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == linked.st_dev, current.st_ino == linked.st_ino {
                    _ = unlinkat(target, destination.lastPathComponent, 0)
                }
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw systemFailure("Recheck verified download") }
        guard regular(linked), linked.st_dev == original.st_dev, linked.st_ino == original.st_ino,
              linked.st_size == original.st_size, after.st_size == original.st_size,
              after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else {
            throw failure("The download changed while it was being linked. Nothing was imported.")
        }
        succeeded = true
        return true
    }

    /// A real, tiny same-directory filesystem probe. Removes only its own UUID workspace.
    /// This reports filesystem capability, not whether every source/destination pair can link.
    public static func probe(in folder: URL) throws -> Bool {
        let parent = try openDirectory(folder)
        defer { close(parent) }
        let name = ".nomad-link-probe-\(UUID().uuidString)"
        guard mkdirat(parent, name, 0o700) == 0 else { throw systemFailure("Create link probe") }
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let target = directory.appendingPathComponent("linked")
        let bytes = Data("NOMAD filesystem probe".utf8)
        try bytes.write(to: source, options: .withoutOverwriting)
        let result = try stage(source: source, sourceRoot: directory, destination: target, expectedBytes: UInt64(bytes.count))
        if result {
            try FileManager.default.removeItem(at: source)
            guard try Data(contentsOf: target) == bytes else { throw failure("The linked file did not survive source removal.") }
        }
        return result
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.query == nil, url.fragment == nil else { throw failure("A local app folder is required.") }
        // Resolve system ancestor aliases (/var and /tmp on macOS), but reject the folder
        // itself being a symlink. Descendants are opened relative to the held directory fd.
        var info = stat()
        guard lstat(url.standardizedFileURL.path, &info) == 0 else { throw systemFailure("Inspect app folder") }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw failure("The app folder is not a real directory.") }
        let descriptor = open(url.resolvingSymlinksInPath().standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw systemFailure("Open app folder") }
        var held = stat()
        guard fstat(descriptor, &held) == 0, held.st_dev == info.st_dev, held.st_ino == info.st_ino else {
            close(descriptor)
            throw failure("The app folder changed while it was opened.")
        }
        return descriptor
    }

    private static func regular(_ value: stat) -> Bool { (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) }
    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
    private struct LinkError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func failure(_ message: String) -> LinkError { LinkError(message: message) }
    private static func systemFailure(_ operation: String, code: Int32 = errno) -> LinkError {
        failure("\(operation): \(String(cString: strerror(code)))")
    }
}
