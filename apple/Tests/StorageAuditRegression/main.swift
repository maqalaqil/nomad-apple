import Foundation

@main struct StorageAuditRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NomadStorageAudit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support"), documents = root.appendingPathComponent("Documents")
        let fm = FileManager.default
        for path in ["Support/Nomad/Library/Files", "Support/NomadPad/Downloads/Files", "Documents/Workspace"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let archive = support.appendingPathComponent("NomadPad/Downloads/Files/file.zim")
        try Data(repeating: 42, count: 8192).write(to: archive)
        try fm.linkItem(at: archive, to: support.appendingPathComponent("Nomad/Library/Files/shared.zim"))
        try Data("hello".utf8).write(to: documents.appendingPathComponent("Workspace/note.txt"))
        let outside = root.appendingPathComponent("Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 20000).write(to: outside.appendingPathComponent("unrelated.bin"))
        try fm.createSymbolicLink(at: documents.appendingPathComponent("Workspace/external"), withDestinationURL: outside)
        let report = try StorageAudit.scan(support: support, documents: documents)
        precondition(report.uniqueFileBytes == 8197)
        precondition(report.categories.reduce(0) { $0 + $1.logicalBytes } == 16389)
        precondition(report.categories.first(where: { $0.id == "library" })?.extensions["zim"] == 1)
        precondition(report.categories.first(where: { $0.id == "downloads" })?.logicalBytes == 8192)
        precondition(report.categories.first(where: { $0.id == "files" })?.fileCount == 1)
        precondition(report.warnings.contains("Symbolic links were excluded."))
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(StorageAuditReport.self, from: encoded)
        precondition(decoded.uniqueFileBytes == 8197)
        do { _ = try StorageAudit.scan(support: support, documents: documents, maximumEntries: 2); fatalError("Unbounded traversal accepted") } catch {}
        try fm.removeItem(at: archive)
        let withoutOriginal = try StorageAudit.scan(support: support, documents: documents)
        precondition(withoutOriginal.uniqueFileBytes == 8197)
        precondition(withoutOriginal.categories.first(where: { $0.id == "downloads" }) == nil)
        print("PASS: 10 storage audit hardlink, path, classification, bounds and report checks")
    }
}
