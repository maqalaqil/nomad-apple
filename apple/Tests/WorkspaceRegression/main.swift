import Foundation

@main
struct WorkspaceRegression {
    @MainActor static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-workspace-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("workspace")
        let source = temporary.appendingPathComponent("fixture.txt")
        try Data("TEST ONLY offline payload".utf8).write(to: source)
        let workspace = FileWorkspace(root: root)
        try workspace.createFolder("Folder", in: root)
        let folder = root.appendingPathComponent("Folder")
        do { try await workspace.importFiles([root], into: folder); preconditionFailure("Recursive directory import accepted") } catch { }
        precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("workspace").path))
        try await workspace.importFiles([source], into: root)
        var entries = try workspace.list(root)
        precondition(entries.count == 2 && entries.first?.isDirectory == true)
        let imported = try entries.first(where: { !$0.isDirectory }).unwrap()
        let originalBytes = try Data(contentsOf: source)
        let importedBytes = try Data(contentsOf: imported.url)
        precondition(importedBytes == originalBytes)
        do { try await workspace.importFiles([source], into: root); preconditionFailure("Duplicate import overwrote an existing file") } catch { }
        let preservedBytes = try Data(contentsOf: imported.url)
        precondition(preservedBytes == originalBytes)
        do { try workspace.rename(imported, to: "../outside"); preconditionFailure("Traversal name accepted") } catch { }
        do { _ = try workspace.list(temporary); preconditionFailure("Outside directory accepted") } catch { }
        do { try workspace.remove(WorkspaceEntry(url: root, isDirectory: true, bytes: 0)); preconditionFailure("Root deletion accepted") } catch { }
        workspace.clipboard = (imported.url, false)
        try await workspace.paste(in: folder)
        precondition(FileManager.default.fileExists(atPath: imported.url.path))
        let copied = try workspace.list(folder).first.unwrap()
        try workspace.rename(copied, to: "renamed.txt")
        let renamed = try workspace.list(folder).first.unwrap()
        workspace.clipboard = (renamed.url, true)
        try await workspace.paste(in: root)
        precondition(workspace.clipboard == nil && !FileManager.default.fileExists(atPath: renamed.url.path))
        workspace.clipboard = (folder, true)
        do { try await workspace.paste(in: folder); preconditionFailure("Self move accepted") } catch { }
        let link = temporary.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { try await workspace.importFiles([link], into: root); preconditionFailure("Symbolic link imported") } catch { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("link.txt").path))
        try workspace.remove(imported)
        precondition(FileManager.default.fileExists(atPath: source.path))
        entries = try workspace.list(root)
        precondition(entries.contains(where: { $0.name == "renamed.txt" }))
        print("PASS: folder creation, import, duplicate preservation, traversal rejection, copy, rename, move, self-move rejection, symbolic-link rejection, and source-preserving deletion.")
    }
}
private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
