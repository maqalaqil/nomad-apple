import Foundation

enum LocalStorage {
    static func defaultRoot(component: String, supportDirectoryURL: URL? = nil) -> URL {
        let base = supportDirectoryURL ?? supportDirectory
        let requested = base.appendingPathComponent("Nomad", isDirectory: true).appendingPathComponent(component, isDirectory: true)
        // Keep the nonthrowing store initializer API. Preparation repeats the checked walk
        // and reports errors before any write; a failed lookup never authorizes a fallback.
        return (try? directory(in: base, components: ["Nomad", component], create: false)) ?? requested
    }

    static func prepare(_ root: URL, supportDirectoryURL: URL? = nil) throws {
        let base = (supportDirectoryURL ?? supportDirectory).standardizedFileURL
        let path = root.standardizedFileURL.path
        if path == base.path || path.hasPrefix(base.path + "/") {
            let suffix = String(path.dropFirst(base.path.count)).split(separator: "/").map(String.init)
            let resolved = try directory(in: base, components: suffix, create: false)
            guard resolved.standardizedFileURL.path == root.standardizedFileURL.path else {
                throw LocalStorageError.unavailable("The storage directory spelling changed. Reopen this module before saving; existing files were preserved.")
            }
            _ = try directory(in: base, components: suffix, create: true)
        } else {
            // Explicit roots are used by isolated engine callers; never follow a final
            // directory link or replace a conflicting regular file while creating them.
            try prepareDirectory(root)
        }
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Core-only equivalent of the app's checked directory resolver. Lookup is read-only
    /// unless requested, and case-sensitive volumes retain distinct historical roots.
    static func directory(in base: URL, components: [String], create: Bool) throws -> URL {
        guard base.isFileURL, components.allSatisfy(isSafeBasename) else { throw LocalStorageError.unavailable("Invalid local storage directory.") }
        if create { try prepareDirectory(base) }
        var current = base
        for component in components {
            if try directoryExists(current) {
                let names = try FileManager.default.contentsOfDirectory(atPath: current.path)
                var name = component
                if names.contains(component) { name = component }
                else if try current.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
                    let matches = names.filter { $0.caseInsensitiveCompare(component) == .orderedSame }
                    guard matches.count <= 1 else { throw LocalStorageError.unavailable("Conflicting local storage directory names.") }
                    name = matches.first ?? component
                }
                current.appendPathComponent(name, isDirectory: true)
                _ = try directoryExists(current)
            } else { current.appendPathComponent(component, isDirectory: true) }
            if create { try prepareDirectory(current) }
        }
        return current
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LocalStorageError.unavailable("Local storage must be a real directory. Symbolic links and conflicting files are not followed.")
        }
        return true
    }

    private static func prepareDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw LocalStorageError.unavailable("Local storage requires a file URL.") }
        if try directoryExists(url) { return }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw LocalStorageError.unavailable("Local storage cannot be created.") }
        try prepareDirectory(parent)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        _ = try directoryExists(url)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 64 * 1_024 * 1_024 else {
            throw LocalStorageError.unavailable("The local metadata limit of 64 MB has been reached. Remove some indexed documents before adding more.")
        }
        // Foundation writes a sibling temporary file and replaces the destination only on success.
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let count = attributes[.size] as? NSNumber, count.int64Value > 64 * 1_024 * 1_024 {
            throw LocalStorageError.invalidManifest("The metadata file exceeds the supported size.")
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func isSafeBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
        (name as NSString).lastPathComponent == name
    }

    static func internalFilename(id: UUID, source: URL) -> String {
        let suffix = source.pathExtension.lowercased()
        let allowed = CharacterSet.alphanumerics
        let safeSuffix = suffix.count <= 16 && !suffix.isEmpty && suffix.unicodeScalars.allSatisfy { allowed.contains($0) }
        return id.uuidString + (safeSuffix ? ".\(suffix)" : "")
    }
}
