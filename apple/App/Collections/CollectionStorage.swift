import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Storage for the native collection modules. Files remain in the app sandbox.
enum CollectionStorage {
    enum StorageError: LocalizedError {
        case invalidFileName
        case invalidDocument(String)

        var errorDescription: String? {
            switch self {
            case .invalidFileName: return "The saved file name is invalid."
            case .invalidDocument(let message): return message
            }
        }
    }

    static func directory(_ collection: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return try CollectionStorageDirectory.directory(in: base, components: ["NOMAD", "Collections", collection])
    }

    static func file(_ name: String, in collection: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else {
            throw StorageError.invalidFileName
        }
        return try directory(collection).appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String, collection: String) throws -> T? {
        let url = try file(name, in: collection)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func save<T: Encodable>(_ value: T, name: String, collection: String) throws {
        try encoded(value).write(to: file(name, in: collection), options: .atomic)
    }

    /// Coordinates a user-selected document read, including cloud-backed providers.
    static func readSelectedFile(_ source: URL, maximumBytes: Int) throws -> Data {
        guard source.isFileURL, maximumBytes > 0 else { throw StorageError.invalidDocument("Select a local document from Files.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var outcome: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            outcome = Result {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw StorageError.invalidDocument("Choose a regular file, not a folder or symbolic link.")
                }
                let size = values.fileSize ?? 0
                guard size <= maximumBytes else {
                    throw StorageError.invalidDocument("This document is larger than the supported import size.")
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard chunk.count <= maximumBytes - data.count else {
                        throw StorageError.invalidDocument("This document is larger than the supported import size.")
                    }
                    data.append(chunk)
                }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw StorageError.invalidDocument("The selected file could not be read.") }
        return try outcome.get()
    }

    /// Copies rather than links a selected file, so it remains usable offline.
    static func copySelectedFile(_ source: URL, name: String, collection: String) throws -> URL {
        let destination = try file(name, in: collection)
        try copySelectedFile(source, to: destination)
        return destination
    }

    static func copySelectedFile(_ source: URL, to destination: URL) throws {
        guard source.isFileURL else { throw StorageError.invalidDocument("Select a local file from Files.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            outcome = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw StorageError.invalidDocument("Choose a regular file, not a folder or symbolic link.")
                }
                try FileManager.default.copyItem(at: url, to: staging)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw StorageError.invalidDocument("The selected file could not be copied.") }
        try outcome.get()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    static func remove(_ name: String, collection: String) throws {
        let url = try file(name, in: collection)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

struct CollectionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CollectionStorage.StorageError.invalidDocument("The document is not a regular file.")
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
