import Foundation
import Darwin

/// Keeps historic store names while accommodating a simulator on a case-insensitive host.
enum CollectionStorageDirectory {
    /// Returns an existing child's actual spelling only if the volume explicitly ignores case.
    /// It never creates, renames or follows a symbolic link.
    static func existingSpelling(of component: String, in parent: URL) throws -> URL {
        guard parent.isFileURL, !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\\"), !component.contains("\0") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try requireDirectory(parent)
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        let chosen: String
        if names.contains(component) { chosen = component }
        else if try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            let matches = names.filter { $0.caseInsensitiveCompare(component) == .orderedSame }
            guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
            chosen = matches.first ?? component
        } else { chosen = component }
        let child = parent.appendingPathComponent(chosen, isDirectory: true)
        if try exists(child) { try requireDirectory(child) }
        return child
    }

    static func directory(in base: URL, components: [String]) throws -> URL {
        try prepare(base)
        var current = base
        for component in components {
            current = try existingSpelling(of: component, in: current)
            try prepare(current)
        }
        return current
    }

    private static func prepare(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        if try exists(url) { try requireDirectory(url); return }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw CocoaError(.fileNoSuchFile) }
        try prepare(parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try requireDirectory(url)
    }

    private static func exists(_ url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
