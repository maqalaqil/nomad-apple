import Foundation
import Combine

@MainActor final class InventoryStore: ObservableObject {
    @Published private(set) var items: [InventoryItem] = []
    @Published private(set) var canWrite = false
    @Published var error: String?
    private(set) var directory: URL
    private var manifest: LocalManifestFile
    private var lastSaved: InventoryArchive?
    private var attachmentsDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    init(directoryURL: URL? = nil, supportDirectoryURL: URL? = nil) {
        let support = supportDirectoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = directoryURL ?? support.appendingPathComponent("NOMAD/Collections/inventory", isDirectory: true)
        manifest = LocalManifestFile(url: directory.appendingPathComponent("inventory.json"))
        do {
            if directoryURL == nil {
                directory = try CollectionStorageDirectory.directory(in: support, components: ["NOMAD", "Collections", "inventory"])
                manifest = LocalManifestFile(url: directory.appendingPathComponent("inventory.json"))
            } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            try regularDirectory(directory)
            let saved = try manifest.load(InventoryArchive.self, validate: InventoryValidation.archive)
            if saved == nil, FileManager.default.fileExists(atPath: attachmentsDirectory.path),
               !(try FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)).isEmpty {
                throw InventoryFailure.message("Inventory metadata is missing but attachments remain. Restore the metadata before changing the inventory.")
            }
            if let saved { try checkReferences(saved.items) }
            lastSaved = saved; items = saved?.items ?? []; canWrite = true
        } catch { self.error = "Saved inventory could not be opened. Existing files were preserved: \(error.localizedDescription)" }
    }

    func attachmentURL(_ attachment: InventoryAttachment) -> URL { attachmentsDirectory.appendingPathComponent(attachment.filename) }

    func attachmentData(_ attachment: InventoryAttachment) throws -> Data {
        var probe = InventoryItem(name: "Attachment validation", location: "", quantity: 0, notes: "")
        probe.attachments = [attachment]
        try InventoryValidation.archive(InventoryArchive(items: [probe]))
        try regularDirectory(directory); try regularDirectory(attachmentsDirectory)
        let data = try InventoryAttachmentFiles.readRegular(attachmentURL(attachment), maximum: InventoryValidation.maximumAttachmentBytes)
        try InventoryAttachmentFiles.validate(data, descriptor: attachment)
        return data
    }

    func save(_ item: InventoryItem, replacing original: InventoryItem?, added: [InventoryPreparedAttachment] = []) throws {
        guard canWrite else { throw InventoryFailure.message("Reload valid saved inventory before making changes.") }
        if let original {
            guard let current = items.first(where: { $0.id == original.id }), current == original, item.id == original.id else {
                throw InventoryFailure.message("This item changed while its editor was open. Reopen it before saving.")
            }
        } else if items.contains(where: { $0.id == item.id }) { throw InventoryFailure.message("This item identifier already exists.") }
        let replacement = original == nil ? items + [item] : items.map { $0.id == item.id ? item : $0 }
        try commit(replacement, added: added)
    }

    func remove(_ item: InventoryItem) throws {
        guard items.first(where: { $0.id == item.id }) == item else { throw InventoryFailure.message("The item changed. Review it before deleting.") }
        try commit(items.filter { $0.id != item.id }, added: [])
    }

    func replace(with portable: InventoryPortableArchive) throws {
        try InventoryValidation.portable(portable)
        let references = Dictionary(uniqueKeysWithValues: portable.items.flatMap(\.attachments).map { ($0.id, $0) })
        let files = try portable.files.map { file -> InventoryPreparedAttachment in
            guard let attachment = references[file.id] else { throw InventoryFailure.message("Unreferenced attachment.") }
            try InventoryAttachmentFiles.validate(file.data, descriptor: attachment)
            return InventoryPreparedAttachment(attachment: attachment, data: file.data)
        }
        try commit(portable.items, added: files)
    }

    func export() throws -> Data {
        guard canWrite else { throw InventoryFailure.message("Saved inventory must be readable before export.") }
        try verifyCurrentManifest()
        let files = try items.flatMap(\.attachments).map { InventoryEmbeddedFile(id: $0.id, data: try attachmentData($0)) }
        let portable = InventoryPortableArchive(items: items, files: files)
        try InventoryValidation.portable(portable)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(portable)
        guard data.count <= InventoryValidation.maximumArchiveBytes else { throw InventoryFailure.message("The portable inventory archive exceeds 200 MB.") }
        return data
    }

    static func decodeImport(_ data: Data) throws -> InventoryPortableArchive {
        guard data.count <= InventoryValidation.maximumArchiveBytes else { throw InventoryFailure.message("Inventory imports are limited to 200 MB.") }
        let portable = try JSONDecoder().decode(InventoryPortableArchive.self, from: data)
        try InventoryValidation.portable(portable)
        return portable
    }

    private func regularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw InventoryFailure.message("Inventory storage must be a regular directory.") }
    }

    private func checkReferences(_ items: [InventoryItem]) throws {
        let references = items.flatMap(\.attachments)
        if !references.isEmpty { try regularDirectory(attachmentsDirectory) }
        for attachment in references {
            let values = try attachmentURL(attachment).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == attachment.byteCount else {
                throw InventoryFailure.message("An inventory attachment is missing, changed or unsafe. Its item record was preserved.")
            }
        }
    }

    private func verifyCurrentManifest() throws {
        do {
            let current = try manifest.load(InventoryArchive.self, validate: InventoryValidation.archive)
            guard current == lastSaved else { throw InventoryFailure.message("Saved inventory changed in another screen. Reopen the module before editing.") }
        } catch { canWrite = false; throw error }
    }

    private func commit(_ replacement: [InventoryItem], added: [InventoryPreparedAttachment]) throws {
        guard canWrite else { throw InventoryFailure.message("Saved inventory is protected until it can be reloaded.") }
        let candidate = InventoryArchive(items: replacement)
        try InventoryValidation.archive(candidate)
        guard try JSONEncoder().encode(candidate).count <= InventoryValidation.maximumManifestBytes else { throw InventoryFailure.message("Inventory metadata exceeds 20 MB.") }
        let references = Dictionary(uniqueKeysWithValues: replacement.flatMap(\.attachments).map { ($0.id, $0) })
        guard Set(added.map { $0.attachment.id }).count == added.count else { throw InventoryFailure.message("Duplicate new attachment identifiers.") }
        for file in added {
            guard references[file.attachment.id] == file.attachment else { throw InventoryFailure.message("A new attachment has no matching item reference.") }
            try InventoryAttachmentFiles.validate(file.data, descriptor: file.attachment)
        }
        var owned: [URL] = [], committed = false
        defer { if !committed { for url in owned { try? FileManager.default.removeItem(at: url) } } }
        do {
            try regularDirectory(directory)
            try verifyCurrentManifest()
            if !added.isEmpty {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try regularDirectory(attachmentsDirectory)
            }
            for file in added {
                let destination = attachmentURL(file.attachment)
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Portable restore may refer to an existing immutable file. Only reuse
                    // the exact validated bytes; never replace an unrelated UUID collision.
                    guard try attachmentData(file.attachment) == file.data else { throw InventoryFailure.message("Attachment identifier collision. Existing files were preserved.") }
                } else {
                    try InventoryAttachmentFiles.writeExclusive(file.data, to: destination)
                    owned.append(destination)
                }
            }
            try checkReferences(replacement)
            do { try manifest.save(candidate) }
            catch { canWrite = false; throw error }
            committed = true
        } catch {
            // Invalid files do not make a healthy manifest unreadable; a failed metadata
            // load/save or conflict does. Reload to recover from the latter safely.
            if !manifest.isReady { canWrite = false }
            throw error
        }
        let removed = items.flatMap(\.attachments).filter { references[$0.id] == nil }
        items = replacement; lastSaved = candidate
        // Metadata commits before unlink. A cleanup failure leaves an unused copy;
        // it never removes attachment bytes still referenced by the saved state.
        for attachment in removed {
            do { try FileManager.default.removeItem(at: attachmentURL(attachment)) }
            catch { self.error = "Inventory was saved, but an unused attachment could not be removed: \(error.localizedDescription)" }
        }
    }
}
