import Foundation

/// A failed read closes this file to writes until a later successful reload.
/// This prevents an empty screen from silently replacing unreadable saved data.
struct LocalManifestFile {
    let url: URL
    private(set) var isReady = false
    private let maximumBytes = 64 * 1_024 * 1_024

    mutating func load<T: Decodable>(_ type: T.Type, validate: (T) throws -> Void = { _ in }) throws -> T? {
        isReady = false
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            isReady = true
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(type, from: data)
        try validate(value)
        isReady = true
        return value
    }

    func save<T: Encodable>(_ value: T) throws {
        guard isReady else {
            throw NSError(domain: "NOMAD.Manifest", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Saved data could not be read. Reload it successfully before making changes; the original file has been preserved."])
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
