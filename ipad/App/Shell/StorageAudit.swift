import Foundation
import Darwin

struct StorageCategory: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    var fileCount = 0
    var logicalBytes: Int64 = 0
    var extensions: [String: Int] = [:]
}
struct StorageAuditReport: Codable, Sendable {
    let measuredAt: Date
    let categories: [StorageCategory]
    let uniqueFileBytes: Int64
    let allocatedBytesEstimate: Int64
    let freeBytesEstimate: Int64?
    let warnings: [String]
}

/// Metadata-only scan: no archive/model payloads are read, and links are never followed.
enum StorageAudit {
    static func scan(support: URL = .applicationSupportDirectory, documents: URL = .documentsDirectory,
                     maximumEntries: Int = 200_000) throws -> StorageAuditReport {
        let mappings: [(String, String, String)] = [
            ("Nomad/Notes", "notes", "Notes"), ("Nomad/Library", "library", "Knowledge library and books"),
            ("NOMAD/Collections/inventory", "inventory", "Inventory"), ("NOMAD/Collections/sketches", "sketch", "Sketchbook"),
            ("NOMAD/Collections/media", "media", "Media"), ("NOMAD/Reference", "reference", "Drug reference"),
            ("NomadPad/GGUF", "models", "GGUF models and conversations"), ("NomadPad/Knowledge", "knowledge", "Knowledge collections and index"),
            ("NomadPad/Courses", "education", "Courses and learners"), ("NomadPad/Lessons", "education", "Courses and learners"),
            ("NomadPad/PMTiles", "maps", "Offline maps"), ("NomadPad/Maps", "maps", "Offline maps"),
            ("NomadPad/Downloads", "downloads", "Downloads and recovery data"), ("NomadPad/Benchmarks", "benchmarks", "Benchmark history"),
            ("NomadPad/BackupControl", "backups", "Backup and restore staging"), ("NomadPad/Catalogs", "catalogs", "Custom catalogs"),
            ("NomadPad/assistant", "assistant", "Apple assistant conversations")
        ]
        var categories: [String: StorageCategory] = [:], seen: Set<String> = [], warnings: Set<String> = []
        var unique: Int64 = 0, allocated: Int64 = 0, entries = 0
        for (root, isDocuments) in [(support, false), (documents, true)] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var stack: [(URL, String)] = [(root, "")]
            while let (url, relative) = stack.popLast() {
                try Task.checkCancellation()
                entries += 1
                guard entries <= maximumEntries else { throw CocoaError(.fileReadTooLarge) }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { warnings.insert("Some file metadata changed or could not be read during the scan."); continue }
                let type = info.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFLNK) { warnings.insert("Symbolic links were excluded."); continue }
                if type == mode_t(S_IFDIR) {
                    do {
                        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                            stack.append((child, relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent))
                        }
                    } catch { warnings.insert("Some folders could not be scanned completely.") }
                    continue
                }
                guard type == mode_t(S_IFREG), info.st_size >= 0 else { continue }
                let category: (String, String)
                if isDocuments {
                    category = relative.hasPrefix("Workspace/") ? ("files", "Files workspace") :
                        relative.hasPrefix("Backups/") ? ("backups", "Backup and restore staging") : ("documents", "Other app documents and exports")
                } else if let mapping = mappings.first(where: {
                    relative.lowercased() == $0.0.lowercased() || relative.lowercased().hasPrefix($0.0.lowercased() + "/") ||
                        ($0.1 == "assistant" && relative.lowercased().hasPrefix($0.0.lowercased()))
                }) { category = (mapping.1, mapping.2) }
                else { category = ("other", "Other native app state") }
                var item = categories[category.0] ?? StorageCategory(id: category.0, title: category.1)
                let size = Int64(info.st_size)
                guard size <= Int64.max - item.logicalBytes else { throw CocoaError(.fileReadTooLarge) }
                item.fileCount += 1; item.logicalBytes += size
                let ext = url.pathExtension.lowercased()
                if !ext.isEmpty { item.extensions[ext, default: 0] += 1 }
                categories[category.0] = item
                if seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                    guard size <= Int64.max - unique, info.st_blocks >= 0, Int64(info.st_blocks) <= (Int64.max - allocated) / 512
                    else { throw CocoaError(.fileReadTooLarge) }
                    unique += size; allocated += Int64(info.st_blocks) * 512
                }
            }
        }
        let capacity = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return StorageAuditReport(measuredAt: Date(), categories: categories.values.sorted { $0.logicalBytes > $1.logicalBytes },
            uniqueFileBytes: unique, allocatedBytesEstimate: allocated, freeBytesEstimate: capacity, warnings: warnings.sorted())
    }
}
