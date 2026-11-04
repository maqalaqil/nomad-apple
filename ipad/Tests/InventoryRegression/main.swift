import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var checks = 0
func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw InventoryFailure.message("FAILED: \(message)") }
    checks += 1
}
func rejects(_ body: () throws -> Void, _ message: String) throws {
    do { try body() } catch { checks += 1; return }
    throw InventoryFailure.message("FAILED: \(message)")
}

func photo() -> Data {
    let context = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 12000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3]] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

@main struct InventoryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nomad-inventory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let existingCore = support.appendingPathComponent("Nomad", isDirectory: true)
        try FileManager.default.createDirectory(at: existingCore, withIntermediateDirectories: true)
        let sentinel = existingCore.appendingPathComponent("existing-core-state")
        try Data("preserve".utf8).write(to: sentinel)
        let defaultStore = InventoryStore(supportDirectoryURL: support)
        try expect(defaultStore.canWrite, "default inventory opens alongside existing mixed-case core storage")
        let defaultItem = InventoryItem(name: "Coexisting inventory", location: "", quantity: 1, notes: "")
        try defaultStore.save(defaultItem, replacing: nil)
        try expect(InventoryStore(supportDirectoryURL: support).items == [defaultItem], "default storage persists across reopen")
        try expect(try Data(contentsOf: sentinel) == Data("preserve".utf8), "default storage preserves existing core bytes")
        let unsafeSupport = root.appendingPathComponent("unsafe-support", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeSupport, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeSupport.appendingPathComponent("NOMAD"), withDestinationURL: existingCore)
        try expect(!InventoryStore(supportDirectoryURL: unsafeSupport).canWrite, "default storage refuses a symlink root")
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let id = UUID()
        let oldData = try JSONSerialization.data(withJSONObject: ["version": 1, "items": [["id": id.uuidString, "name": "Radio", "location": "Cabinet", "quantity": 2, "notes": "Original note", "updatedAt": 1234.0]]])
        try oldData.write(to: legacyRoot.appendingPathComponent("inventory.json"))
        let store = InventoryStore(directoryURL: legacyRoot)
        try expect(store.canWrite && store.items.count == 1, "legacy inventory loads")
        try expect(store.items[0].tags.isEmpty && store.items[0].attachments.isEmpty && store.items[0].purchasePrice == nil && store.items[0].currencyCode == "USD", "old fields receive backward-compatible defaults")
        var edited = store.items[0]
        edited.tags = ["Emergency", "Comms"]; edited.manufacturer = "Example Co"; edited.model = "R-20"; edited.serialNumber = "SERIAL-123"
        edited.purchaseDate = Date(timeIntervalSince1970: 1000); edited.warrantyExpires = Date(timeIntervalSince1970: 2000)
        edited.purchasePrice = "123.4500"; edited.currencyCode = "SAR"; edited.minimumStock = 3
        try store.save(edited, replacing: store.items[0])
        let upgraded = try JSONDecoder().decode(InventoryArchive.self, from: Data(contentsOf: legacyRoot.appendingPathComponent("inventory.json")))
        try expect(upgraded.version == 2 && upgraded.items[0] == edited, "new metadata saves and upgrades v1 to v2")
        try expect(edited.isLowStock && edited.searchableText.contains("SERIAL-123") && edited.searchableText.contains("Emergency"), "stock and search include new metadata")
        let reopened = InventoryStore(directoryURL: legacyRoot)
        try expect(reopened.canWrite && reopened.items == store.items, "new metadata persists across reopen")

        let imageURL = root.appendingPathComponent("photo.png"), sourceBytes = photo()
        try sourceBytes.write(to: imageURL)
        let prepared = try InventoryAttachmentFiles.prepare(imageURL)
        try expect(prepared.attachment.fileExtension == "jpg" && prepared.attachment.sha256 == InventoryValidation.hash(prepared.data), "photo is normalized and hashed")
        let imageSource = CGImageSourceCreateWithData(prepared.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
        try expect(properties[kCGImagePropertyPixelWidth] as? Int == 2048, "photo dimensions bounded")
        try expect(properties[kCGImagePropertyGPSDictionary] == nil, "photo GPS metadata removed")
        var withPhoto = store.items[0]; withPhoto.attachments = [prepared.attachment]
        try store.save(withPhoto, replacing: store.items[0], added: [prepared])
        try expect(try store.attachmentData(prepared.attachment) == prepared.data, "attachment committed with item")
        try expect(try Data(contentsOf: imageURL) == sourceBytes, "source photo never overwritten")
        let portableData = try store.export()
        let portable = try InventoryStore.decodeImport(portableData)
        try expect(portable.files.count == 1 && portable.files[0].data == prepared.data && portable.items == store.items, "portable archive contains exact attachment and metadata")
        let restoredRoot = root.appendingPathComponent("restored"), restored = InventoryStore(directoryURL: root.appendingPathComponent("restored"))
        try restored.replace(with: portable)
        try expect(restored.items == store.items && (try restored.attachmentData(prepared.attachment)) == prepared.data, "portable archive restores on empty storage")
        try restored.replace(with: portable)
        try expect(restored.items == store.items, "reimport safely reuses exact immutable attachment")

        var corrupt = portable
        corrupt.files = [InventoryEmbeddedFile(id: prepared.attachment.id, data: Data("tampered".utf8))]
        let saved = try Data(contentsOf: restoredRoot.appendingPathComponent("inventory.json"))
        try rejects({ try restored.replace(with: corrupt) }, "tampered attachment rejected")
        try expect(try Data(contentsOf: restoredRoot.appendingPathComponent("inventory.json")) == saved, "failed import preserves saved manifest")
        try expect(try restored.attachmentData(prepared.attachment) == prepared.data, "failed import preserves existing attachment")
        corrupt = portable; corrupt.files = []
        try rejects({ try restored.replace(with: corrupt) }, "missing portable attachment rejected")
        corrupt = portable; corrupt.files += portable.files
        try rejects({ try restored.replace(with: corrupt) }, "duplicate portable attachment rejected")
        corrupt = portable; corrupt.items += portable.items
        try rejects({ try restored.replace(with: corrupt) }, "duplicate item rejected")

        let oldItem = store.items[0]
        var invalid = oldItem; invalid.quantity = -1
        try rejects({ try store.save(invalid, replacing: oldItem) }, "negative quantity rejected")
        invalid = oldItem; invalid.tags = ["Tag", "tag"]
        try rejects({ try store.save(invalid, replacing: oldItem) }, "duplicate tags rejected")
        invalid = oldItem; invalid.purchasePrice = "-20"
        try rejects({ try store.save(invalid, replacing: oldItem) }, "negative price rejected")
        invalid = oldItem; invalid.currencyCode = "US"
        try rejects({ try store.save(invalid, replacing: oldItem) }, "invalid currency rejected")
        invalid = oldItem; invalid.notes = String(repeating: "x", count: 65 * 1024)
        try rejects({ try store.save(invalid, replacing: oldItem) }, "oversized notes rejected")
        try expect(store.canWrite && store.items[0] == oldItem, "invalid edits leave healthy state unchanged")
        var unknown = oldItem; unknown.attachments[0] = InventoryAttachment(id: UUID(), name: "Missing", fileExtension: "jpg", byteCount: prepared.data.count, sha256: InventoryValidation.hash(prepared.data), addedAt: Date())
        try rejects({ try store.save(unknown, replacing: oldItem) }, "dangling attachment reference rejected")
        try expect(store.items[0] == oldItem, "failed dangling save preserves original item")

        let symlink = root.appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: imageURL)
        try rejects({ _ = try InventoryAttachmentFiles.prepare(symlink) }, "symlink Files attachment rejected")
        try rejects({ _ = try InventoryAttachmentFiles.selected(imageURL, maximum: 2) }, "oversized selected attachment rejected before copy")
        let collision = root.appendingPathComponent("collision")
        try Data("unrelated".utf8).write(to: collision)
        try rejects({ try InventoryAttachmentFiles.writeExclusive(prepared.data, to: collision) }, "exclusive write refuses collision")
        try expect(try Data(contentsOf: collision) == Data("unrelated".utf8), "exclusive collision preserves existing bytes")

        // Fail the metadata write only after the new attachment has been written.
        let failureRoot = root.appendingPathComponent("write-failure"), failureStore = InventoryStore(directoryURL: root.appendingPathComponent("write-failure"))
        let initial = InventoryItem(name: "Original", location: "", quantity: 1, notes: "")
        try failureStore.save(initial, replacing: nil)
        try FileManager.default.createDirectory(at: failureRoot.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        var changed = initial; changed.attachments = [prepared.attachment]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: failureRoot.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failureRoot.path) }
            try rejects({ try failureStore.save(changed, replacing: initial, added: [prepared]) }, "metadata write failure is surfaced")
        }
        try expect(failureStore.items == [initial], "failed save keeps published original item")
        try expect(!FileManager.default.fileExists(atPath: failureStore.attachmentURL(prepared.attachment).path), "failed metadata commit cleans only newly owned attachment")
        try expect(InventoryStore(directoryURL: failureRoot).items == [initial], "original metadata survives failed write")

        let stale = InventoryStore(directoryURL: restoredRoot)
        var newer = restored.items[0]; newer.notes = "Newer state"
        try restored.save(newer, replacing: restored.items[0])
        try rejects({ try stale.save(oldItem, replacing: stale.items[0]) }, "stale store cannot overwrite newer metadata")
        try expect(!stale.canWrite && InventoryStore(directoryURL: restoredRoot).items[0].notes == "Newer state", "conflict closes stale writer and preserves current state")
        try restored.remove(restored.items[0])
        try expect(restored.items.isEmpty && !FileManager.default.fileExists(atPath: restored.attachmentURL(prepared.attachment).path), "confirmed item removal commits before attachment cleanup")

        let corruptRoot = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let bad = Data("corrupt saved inventory".utf8); try bad.write(to: corruptRoot.appendingPathComponent("inventory.json"))
        let unreadable = InventoryStore(directoryURL: corruptRoot)
        try expect(!unreadable.canWrite && unreadable.error != nil, "corrupt metadata fails closed")
        try rejects({ try unreadable.save(initial, replacing: nil) }, "corrupt metadata blocks new saves")
        try expect(try Data(contentsOf: corruptRoot.appendingPathComponent("inventory.json")) == bad, "corrupt bytes remain unchanged")
        let lostRoot = root.appendingPathComponent("lost-manifest")
        try FileManager.default.createDirectory(at: lostRoot.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try prepared.data.write(to: lostRoot.appendingPathComponent("attachments").appendingPathComponent(prepared.attachment.filename))
        try expect(!InventoryStore(directoryURL: lostRoot).canWrite, "missing manifest with retained attachment fails closed")
        print("PASS: \(checks) inventory checks; v1 migration, v2 metadata, normalized photos, embedded exports, rollback, corrupt/conflicting storage, limits and attachment ownership")
    }
}
